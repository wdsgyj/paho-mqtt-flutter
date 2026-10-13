#ifndef MQTT_DART_BRIDGE_H
#define MQTT_DART_BRIDGE_H
#include <stdint.h>
int32_t mqtt_dart_initialize(void *data);
int32_t mqtt_dart_set_port(uint64_t client, int64_t port);
#endif
