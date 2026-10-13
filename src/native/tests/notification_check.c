#include "test_config.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#define CHECK(x)                                                                                   \
    do {                                                                                           \
        if (!(x)) {                                                                                \
            fprintf(stderr, "line %d: %s\n", __LINE__, #x);                                        \
            abort();                                                                               \
        }                                                                                          \
    } while (0)
static const mqtt_core_api *api;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int wakes, entered, block_callback, unblock, disposed, active, release_started, released;
static uint64_t client;
static struct timespec deadline(int milliseconds) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    t.tv_nsec += (long)milliseconds * 1000000;
    t.tv_sec += t.tv_nsec / 1000000000;
    t.tv_nsec %= 1000000000;
    return t;
}
static void await_counter(int *counter, int value) {
    struct timespec t = deadline(5000);
    pthread_mutex_lock(&lock);
    while (*counter < value)
        CHECK(pthread_cond_timedwait(&changed, &lock, &t) != ETIMEDOUT);
    pthread_mutex_unlock(&lock);
}
static int32_t notify(void *ctx, uint64_t id) {
    CHECK(ctx == &client && id == client);
    pthread_mutex_lock(&lock);
    active++;
    wakes++;
    entered = 1;
    pthread_cond_broadcast(&changed);
    while (block_callback && !unblock)
        pthread_cond_wait(&changed, &lock);
    active--;
    pthread_mutex_unlock(&lock);
    return 1;
}
static void dispose(void *ctx) {
    CHECK(ctx == &client);
    pthread_mutex_lock(&lock);
    CHECK(active == 0);
    disposed++;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
}
static void *release_thread(void *unused) {
    (void)unused;
    pthread_mutex_lock(&lock);
    release_started = 1;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    CHECK(api->release_client(client) == 0);
    pthread_mutex_lock(&lock);
    released = 1;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    return NULL;
}
static int drain(void) {
    int count = 0;
    mqtt_event *e;
    while (api->event_take(client, &e) == 1) {
        count++;
        api->event_release(e);
    }
    return count;
}
int main(void) {
    api = mqtt_get_api(2)->core;
    CHECK(api->capabilities & MQTT_CAP_NOTIFY);
    mqtt_config cfg = {.struct_size = sizeof(cfg),
                       .keep_alive_seconds = 10,
                       .connect_timeout_seconds = 1,
                       .clean_session = 1,
                       .min_retry_seconds = 1,
                       .max_retry_seconds = 1,
                       .server_uri = "tcp://127.0.0.1:1",
                       .client_id = "notification-check"};
    mqtt_config_v2 options = test_config(cfg);
    CHECK(mqtt_get_api(2)->create(&options, &client) == 0);
    /* Late registration must notify an already queued create completion too. */
    CHECK(api->set_notifier(client, notify, &client, dispose) == 0);
    CHECK(api->set_notifier(client, notify, &client, dispose) == MQTT_E_STATE);
    await_counter(&wakes, 1);
    CHECK(drain() == 1);
    /* An idle client generates no notifications. Timed wait is a test assertion,
     * not the production delivery mechanism. */
    pthread_mutex_lock(&lock);
    int before = wakes;
    struct timespec t = deadline(100);
    while (wakes == before && pthread_cond_timedwait(&changed, &lock, &t) != ETIMEDOUT) {
    }
    CHECK(wakes == before);
    pthread_mutex_unlock(&lock);
    /* CLOSE is published before release can run. Hold its notification in flight
     * and verify release waits before disposing receiver context. */
    pthread_mutex_lock(&lock);
    block_callback = 1;
    entered = 0;
    pthread_mutex_unlock(&lock);
    CHECK(api->submit(client, 1, MQTT_OP_CLOSE, NULL, NULL, 0, 0, 0) == 0);
    await_counter(&entered, 1);
    CHECK(drain() == 1);
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, release_thread, NULL) == 0);
    await_counter(&release_started, 1);
    pthread_mutex_lock(&lock);
    t = deadline(100);
    while (!released && pthread_cond_timedwait(&changed, &lock, &t) != ETIMEDOUT) {
    }
    CHECK(!released && !disposed);
    unblock = 1;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    pthread_join(thread, NULL);
    CHECK(disposed == 1 && released == 1);
    CHECK(api->set_notifier(client, notify, &client, dispose) == MQTT_E_CLOSED);
    puts("Notifications: late registration, idle and in-flight release barrier passed");
    return 0;
}
