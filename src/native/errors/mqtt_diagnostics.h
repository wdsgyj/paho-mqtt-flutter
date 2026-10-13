#ifndef MQTT_SDK_DIAGNOSTICS_H
#define MQTT_SDK_DIAGNOSTICS_H
#include "mqtt_error.h"
/* Paho's mutex serializes a client's scratch record. The thread-local pointer
 * exists only during a scoped Paho call; no global trace parsing or socket map. */
void mqtt_diag_enter(mqtt_error *record);
void mqtt_diag_leave(void);
void mqtt_diag_stage(int stage);
void mqtt_diag_system(int code);
void mqtt_diag_dns(int code, int system_code);
void mqtt_diag_tls(int ssl_code, long verify_code, int system_code, const char *message);
void mqtt_diag_platform(int code, const char *domain, const char *message, int reason);
void mqtt_diag_text(const char *text, unsigned long length);
void mqtt_error_describe(int32_t code, int32_t operation, mqtt_error *out);
void mqtt_error_complete(mqtt_error *out, int code, int operation, const char *message);
/* Called exactly once per failed Paho connection attempt, before onFailure.
 * Context is the SDK's registered connection callback context. */
void mqtt_sdk_connect_failed(void *context, int code, const char *message,
                             const mqtt_error *record, int will_retry);
#endif
