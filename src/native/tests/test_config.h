#ifndef MQTT_TEST_CONFIG_H
#define MQTT_TEST_CONFIG_H
#include "mqtt_api_v2.h"
static mqtt_config_v2 test_config(mqtt_config base) {
    return (mqtt_config_v2){.base = base, .struct_size = sizeof(mqtt_config_v2),
        .protocol = 4, .max_pending = 128, .max_buffered = 128, .max_inflight = 128,
        .max_messages = 256, .max_bytes = 8u * 1024u * 1024u};
}
#endif
