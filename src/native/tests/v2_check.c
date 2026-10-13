#include "mqtt_api_v2.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define CHECK(x)                                                                                   \
    do {                                                                                           \
        if (!(x)) {                                                                                \
            fprintf(stderr, "v2 line %d: %s\n", __LINE__, #x);                                     \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)
static const mqtt_api_v2 *v;
static const mqtt_core_api *a;
static int connected, received;
static mqtt_event *saved[3];
static const mqtt_property *property(const mqtt_properties *p, unsigned id) {
    for (unsigned i = 0; i < p->count; i++)
        if (p->items[i].id == id)
            return &p->items[i];
    return NULL;
}
static mqtt_event *next(uint64_t client) {
    for (int n = 0; n < 2000; n++) {
        mqtt_event *e = NULL;
        CHECK(a->event_take(client, &e) >= 0);
        if (e)
            return e;
        usleep(5000);
    }
    CHECK(0);
    return NULL;
}
static void observe(mqtt_event *e) {
    if (e->type == MQTT_EVENT_CONNECTED) {
        CHECK(v->event_details(e)->packet_type == 2);
        connected = 1;
    }
    if (e->type == MQTT_EVENT_MESSAGE) {
        CHECK(received < 3);
        saved[received++] = e;
        return;
    }
    a->event_release(e);
}
static mqtt_event *result(uint64_t client, uint64_t request) {
    for (;;) {
        mqtt_event *e = next(client);
        if (e->type == MQTT_EVENT_RESULT) {
            CHECK(e->request_id == request);
            CHECK(!e->code);
            return e;
        }
        observe(e);
    }
}
int main(int argc, char **argv) {
    CHECK(argc >= 2);
    v = (const mqtt_api_v2 *)mqtt_get_api(2);
    a = v->core;
    mqtt_config_v2 cfg = {.base = {.struct_size = sizeof(mqtt_config),
                                   .server_uri = argv[1],
                                   .client_id = "native-v2-check",
                                   .keep_alive_seconds = 0,
                                   .connect_timeout_seconds = 3,
                                   .clean_session = 1,
                                   .min_retry_seconds = 1,
                                   .max_retry_seconds = 2,
                                   .trust_store = argc > 2 ? argv[2] : NULL},
                          .struct_size = sizeof(cfg),
                          .protocol = 5,
                          .max_pending = 128,
                          .max_buffered = 128,
                          .max_inflight = 8,
                          .max_messages = 16,
                          .max_bytes = 65536};
    uint64_t client;
    CHECK(!v->create(&cfg, &client));
    a->event_release(result(client, 0));
    CHECK(a->submit(client, 1, MQTT_OP_DISCONNECT, NULL, NULL, 0, 0, 0) == MQTT_E_INVALID);
    CHECK(v->disconnect(client, 1, 1000, NULL) == MQTT_E_STATE);
    CHECK(!a->submit(client, 1, MQTT_OP_CONNECT, NULL, NULL, 0, 0, 0));
    a->event_release(result(client, 1));
    while (!connected)
        observe(next(client));
    mqtt_subscription_v2 sub = {.filter = "sdk/v2/native", .qos = 2};
    CHECK(!v->subscribe(client, 2, 1, &sub, NULL));
    mqtt_event *e = result(client, 2);
    CHECK(e->payload_length == 1 && e->payload[0] == 2);
    a->event_release(e);
    for (unsigned qos = 0; qos < 3; qos++) {
        unsigned char payload[] = {0, 255, (unsigned char)qos}, correlation[] = {0, 255};
        mqtt_property items[] = {{.id = 9, .length = 2, .data = correlation},
                                 {.id = 38,
                                  .length = 1,
                                  .data = (uint8_t *)"a",
                                  .value_length = 1,
                                  .value = (uint8_t *)"1"},
                                 {.id = 38,
                                  .length = 1,
                                  .data = (uint8_t *)"a",
                                  .value_length = 1,
                                  .value = (uint8_t *)"2"}};
        mqtt_properties p = {3, items};
        CHECK(!v->publish(client, 3 + qos, "sdk/v2/native", payload, 3, qos, 0, &p));
        memset(payload, 99, sizeof(payload));
        memset(correlation, 99, sizeof(correlation));
        memset(items, 0, sizeof(items));
        e = result(client, 3 + qos);
        const mqtt_event_details_v2 *d = v->event_details(e);
        CHECK(d->ack_count == qos);
        if (qos)
            CHECK(d->acks[qos - 1].packet_type == (qos == 1 ? 4 : 7));
        a->event_release(e);
    }
    while (received < 3)
        observe(next(client));
    CHECK(!v->disconnect_implementation(client, 6, NULL, 1000, NULL));
    a->event_release(result(client, 6));
    CHECK(!a->submit(client, 7, MQTT_OP_CLOSE, NULL, NULL, 0, 0, 0));
    a->event_release(result(client, 7));
    CHECK(!a->release_client(client));
    /* Event ownership survives even destruction of its originating client. */
    for (unsigned i = 0; i < 3; i++) {
        e = saved[i];
        CHECK(e->payload_length == 3 && e->payload[0] == 0 && e->payload[1] == 255);
        const mqtt_properties *p = &v->event_details(e)->properties;
        CHECK(p->count == 3);
        const mqtt_property *corr = property(p, 9);
        CHECK(corr && corr->length == 2 && corr->data[0] == 0 && corr->data[1] == 255);
        CHECK(p->items[1].value[0] == '1' && p->items[2].value[0] == '2');
        a->event_release(e);
    }
    CHECK(v->disconnect(client, 8, 0, NULL) == MQTT_E_CLOSED);
    puts("C ABI v2: owned binary/property snapshots, QoS 0/1/2 ACKs, restricted disconnect, close "
         "and stale handles passed");
    return 0;
}
