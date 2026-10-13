#ifndef MQTT_SDK_ERROR_H
#define MQTT_SDK_ERROR_H
#include <stdint.h>
/* Stable numeric values shared by all bindings. Unknown is always zero. */
enum mqtt_error_category { MQTT_ERR_UNKNOWN, MQTT_ERR_ARGUMENT, MQTT_ERR_STATE,
    MQTT_ERR_DNS, MQTT_ERR_NETWORK, MQTT_ERR_TLS, MQTT_ERR_BROKER,
    MQTT_ERR_RESOURCE, MQTT_ERR_CANCELLED, MQTT_ERR_INTERNAL };
enum mqtt_error_reason { MQTT_REASON_UNKNOWN, MQTT_REASON_INVALID_ARGUMENT,
    MQTT_REASON_CLOSED, MQTT_REASON_INVALID_STATE, MQTT_REASON_LIMIT,
    MQTT_REASON_NO_MEMORY, MQTT_REASON_CANCELLED, MQTT_REASON_DNS_FAILURE,
    MQTT_REASON_CONNECTION_REFUSED, MQTT_REASON_TIMEOUT, MQTT_REASON_UNREACHABLE,
    MQTT_REASON_CONNECTION_RESET, MQTT_REASON_PEER_CLOSED, MQTT_REASON_TLS_CONFIG,
    MQTT_REASON_TLS_HANDSHAKE, MQTT_REASON_CERTIFICATE_UNTRUSTED,
    MQTT_REASON_CERTIFICATE_EXPIRED, MQTT_REASON_HOSTNAME_MISMATCH,
    MQTT_REASON_CERTIFICATE_REJECTED, MQTT_REASON_BROKER_REJECTED,
    MQTT_REASON_NOT_CONNECTED, MQTT_REASON_OPERATION_INCOMPLETE,
    MQTT_REASON_CERTIFICATE_NOT_YET_VALID };
enum mqtt_error_stage { MQTT_STAGE_UNKNOWN, MQTT_STAGE_ADMISSION, MQTT_STAGE_DNS,
    MQTT_STAGE_TCP, MQTT_STAGE_TLS_CONFIG, MQTT_STAGE_TLS_HANDSHAKE,
    MQTT_STAGE_CONNACK, MQTT_STAGE_OPERATION };
enum { MQTT_ERROR_SYSTEM=1, MQTT_ERROR_DNS=2, MQTT_ERROR_TLS=4,
    MQTT_ERROR_VERIFY=8, MQTT_ERROR_PLATFORM=16, MQTT_ERROR_WILL_RETRY=32,
    MQTT_ERROR_TRUNCATED=64 };
/* Immutable snapshot in an event. Presence flags distinguish unavailable native
 * fields from valid zero codes. All strings are bounded UTF-8, NUL terminated.
 * details is diagnostic only, never a machine-readable contract. */
typedef struct mqtt_error {
    int32_t category, reason, stage, code, operation;
    int32_t system_code, dns_code, tls_code, verify_code, platform_code;
    uint32_t flags, reserved;
    uint64_t attempt_id, timestamp_ms, elapsed_ms;
    char message[256], details[2048], platform_domain[64];
} mqtt_error;
#endif
