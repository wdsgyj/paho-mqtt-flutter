#include "test_config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static const mqtt_core_api *a;
static int messages;
#define CHECK(x)                                                                                   \
    do {                                                                                           \
        if (!(x)) {                                                                                \
            fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x);                                   \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)
static int wait_result(uint64_t id, uint64_t request, int expected) {
    struct timespec pause = {0, 10000000};
    int accepted_connect = 0, connection_outcome = 0, session_present = 0;
    for (int i = 0; i < 2000; i++) {
        mqtt_event *e = NULL;
        CHECK(a->event_take(id, &e) >= 0);
        if (e) {
            if (e->type == MQTT_EVENT_MESSAGE) {
                CHECK(e->payload_length == 4 && !memcmp(e->payload, "a\0bc", 4));
                messages++;
            }
            if (e->type == MQTT_EVENT_CONNECTED || e->type == MQTT_EVENT_CONNECT_FAILED) {
                connection_outcome = e->type; session_present = e->value;
            }
            if (e->type == MQTT_EVENT_RESULT) {
                if (e->operation == MQTT_OP_CONNECT && e->code == 0 && expected != 998) {
                    CHECK(e->request_id == request);
                    accepted_connect = 1;
                    a->event_release(e);
                    if (!connection_outcome) continue;
                    CHECK(connection_outcome == (expected == 999 ? MQTT_EVENT_CONNECT_FAILED : MQTT_EVENT_CONNECTED));
                    return session_present;
                }
                CHECK(e->request_id == request);
                if (expected == 999)
                    CHECK(e->code != 0);
                else if (expected != 998)
                    CHECK(e->code == expected);
                if (e->operation == MQTT_OP_SUBSCRIBE_MANY && e->code == 0) {
                    CHECK(e->payload_length == 3 && e->value == 3);
                    CHECK(e->payload[0] == 0 && e->payload[1] == 1 && e->payload[2] == 2);
                }
                if (e->operation == MQTT_OP_UNSUBSCRIBE_MANY) {
                    CHECK(e->value == 0 && e->payload_length == 0 && e->payload == NULL);
                }
                int v = e->value;
                a->event_release(e);
                return v;
            }
            a->event_release(e);
        }
        if (accepted_connect && connection_outcome) {
            CHECK(connection_outcome == (expected == 999 ? MQTT_EVENT_CONNECT_FAILED : MQTT_EVENT_CONNECTED));
            return session_present;
        }
        nanosleep(&pause, NULL);
    }
    fprintf(stderr, "Timeout request %llu\n", (unsigned long long)request);
    exit(1);
}
int main(int argc, char **argv) {
    CHECK(argc >= 2 && argc <= 4);
    a = mqtt_get_api(2)->core;
    CHECK(a && (a->capabilities & MQTT_CAP_CLIENT));
    char name[80], topic[100];
    snprintf(name, sizeof(name), "native-%d", getpid());
    snprintf(topic, sizeof(topic), "sdk/%s", name);
    mqtt_config cfg = {.struct_size = sizeof(cfg),
                       .keep_alive_seconds = 15,
                       .connect_timeout_seconds = 3,
                       .clean_session = 1,
                       .min_retry_seconds = 1,
                       .max_retry_seconds = 5,
                       .server_uri = argv[1],
                       .client_id = name,
                       .trust_store = argc >= 3 && strcmp(argv[2], "-") ? argv[2] : NULL};
    mqtt_config_v2 options = test_config(cfg);
    const mqtt_api_v2 *v = mqtt_get_api(2);
    uint64_t id = 0;
    CHECK(mqtt_get_api(2)->create(&options, &id) == 0);
    wait_result(id, 0, 0);
    CHECK(v->publish(id, 1, topic, (const uint8_t *)"a\0bc", 4, 1, 0, NULL) == MQTT_E_STATE);
    CHECK(a->submit(id, 2, MQTT_OP_CONNECT, NULL, NULL, 0, 0, 0) == 0);
    if (argc == 4) {
        wait_result(id, 2, 999);
        CHECK(a->submit(id, 3, MQTT_OP_CLOSE, NULL, NULL, 0, 0, 0) == 0);
        wait_result(id, 3, 0);
        CHECK(a->release_client(id) == 0);
        puts("TLS rejection verified");
        return 0;
    }
    CHECK(wait_result(id, 2, 0) == 0);
    const char *filters[] = {"sdk/native/batch0", "sdk/native/batch1", topic};
    mqtt_subscription_v2 subs[] = {{.filter=filters[0], .qos=0}, {.filter=filters[1], .qos=1}, {.filter=filters[2], .qos=2}};
    CHECK(a->capabilities & MQTT_CAP_SUBSCRIBE_MANY);
    CHECK(v->subscribe(id, 3, 0, subs, NULL) == MQTT_E_INVALID);
    CHECK(v->subscribe(id, 3, 257, subs, NULL) == MQTT_E_INVALID);
    CHECK(v->subscribe(id, 3, 3, NULL, NULL) == MQTT_E_INVALID);
    subs[1].qos = 3;
    CHECK(v->subscribe(id, 3, 3, subs, NULL) == MQTT_E_INVALID);
    subs[1].qos = 1;
    CHECK(v->subscribe(id, 3, 3, subs, NULL) == 0);
    /* Accepted native submissions own snapshots of caller inputs. */
    subs[2].qos = 0;
    CHECK(wait_result(id, 3, 0) == 3);
    for (uint64_t q = 0; q < 3; q++) {
        CHECK(v->publish(id, 4 + q, topic, (const uint8_t *)"a\0bc", 4, (int)q,
                        0, NULL) == 0);
        wait_result(id, 4 + q, 0);
    }
    for (int i = 0; i < 500 && messages < 3; i++) {
        mqtt_event *e = NULL;
        CHECK(a->event_take(id, &e) >= 0);
        if (e) {
            if (e->type == MQTT_EVENT_MESSAGE) {
                CHECK(e->payload_length == 4 && !memcmp(e->payload, "a\0bc", 4));
                messages++;
            }
            a->event_release(e);
        }
        usleep(10000);
    }
    CHECK(messages == 3);
    CHECK(a->capabilities & MQTT_CAP_UNSUBSCRIBE_MANY);
    CHECK(v->unsubscribe(id, 7, 0, filters, NULL) == MQTT_E_INVALID);
    CHECK(v->unsubscribe(id, 7, 257, filters, NULL) == MQTT_E_INVALID);
    CHECK(v->unsubscribe(id, 7, 3, NULL, NULL) == MQTT_E_INVALID);
    CHECK(v->unsubscribe(id, 7, 3, filters, NULL) == 0);
    wait_result(id, 7, 0);
    CHECK(v->disconnect(id, 8, 1000, NULL) == 0);
    wait_result(id, 8, 0);
    CHECK(a->submit(id, 9, MQTT_OP_CLOSE, NULL, NULL, 0, 0, 0) == 0);
    wait_result(id, 9, 0);
    CHECK(a->release_client(id) == 0);
    CHECK(a->release_client(id) == MQTT_E_CLOSED);
    CHECK(a->submit(id, 10, MQTT_OP_CONNECT, NULL, NULL, 0, 0, 0) == MQTT_E_CLOSED);
    /* Exercise create -> connect -> close while connect is in flight. */
    for (int i = 0; i < 30; i++) {
        CHECK(mqtt_get_api(2)->create(&options, &id) == 0);
        wait_result(id, 0, 0);
        CHECK(a->submit(id, 1, MQTT_OP_CONNECT, NULL, NULL, 0, 0, 0) == 0);
        CHECK(a->submit(id, 2, MQTT_OP_CLOSE, NULL, NULL, 0, 0, 0) == 0);
        wait_result(id, 1, 998);
        wait_result(id, 2, 0);
        CHECK(a->release_client(id) == 0);
    }
    CHECK(mqtt_get_api(2)->create(&options, &id) == 0);
    wait_result(id, 0, 0);
    CHECK(a->release_client(id) == MQTT_E_STATE);
    CHECK(v->publish(id, 1, topic, NULL, 0, 3, 0, NULL) == MQTT_E_INVALID);
    CHECK(a->submit(id, 1, MQTT_OP_CONNECT, NULL, NULL, 0, 0, 0) == 0);
    wait_result(id, 1, 0);
    /* Undrained completion events count against capacity. CLOSE has a reserve. */
    for (uint64_t i = 2; i <= 129; i++)
        CHECK(v->publish(id, i, topic, NULL, 0, 0, 0, NULL) == 0);
    CHECK(v->unsubscribe(id, 130, 3, filters, NULL) == MQTT_E_LIMIT);
    CHECK(v->subscribe(id, 130, 3, subs, NULL) == MQTT_E_LIMIT);
    CHECK(v->publish(id, 130, topic, NULL, 0, 0, 0, NULL) == MQTT_E_LIMIT);
    CHECK(a->submit(id, 130, MQTT_OP_CLOSE, NULL, NULL, 0, 0, 0) == 0);
    for (uint64_t i = 2; i <= 129; i++)
        wait_result(id, i, 998); /* CLOSE may cancel an in-flight publish. */
    wait_result(id, 130, 0);
    CHECK(a->release_client(id) == 0);
    puts("MQTT runtime: QoS 0/1/2, binary payload, failure, teardown and stale handles passed");
}
