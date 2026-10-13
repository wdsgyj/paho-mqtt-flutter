#ifndef MQTT_SDK_V5_HOOKS_H
#define MQTT_SDK_V5_HOOKS_H
#include "MQTTProperties.h"
#include <stddef.h>
void mqtt_sdk_connack(void *, int, const MQTTProperties *);
void mqtt_sdk_token(void *, void *, int);
void mqtt_sdk_ack(void *, int, int, int, const MQTTProperties *);
unsigned int mqtt_sdk_session_expiry(void *);
int mqtt_sdk_inflight(void *);
int mqtt_sdk_retry_allowed(void *);
int mqtt_sdk_clean_start(void *);
int mqtt_sdk_queue_allowed(void *, size_t, size_t, size_t);
void mqtt_sdk_read_enter(void *);
int mqtt_sdk_packet_allowed(size_t);
int mqtt_sdk_outgoing_allowed(void *, size_t);
int mqtt_sdk_socket_allowed(int, size_t);
#endif
