#ifndef MQTT_SDK_API_H
#define MQTT_SDK_API_H
#include <stdint.h>
#include "mqtt_error.h"
#ifdef __cplusplus
extern "C" {
#endif
#define MQTT_CORE_API_VERSION 2u
#define MQTT_API_EXPORT __attribute__((visibility("default")))
#define MQTT_CAP_ERRORS 512u
/* CONNECT result acknowledges start only; connection outcomes are events. */
#define MQTT_CAP_START_CONNECTING 1024u
#define MQTT_CAP_CLIENT 1u
#define MQTT_CAP_TLS 2u
/* TLS: explicit CA is exclusive; unset selects Android system roots / Apple SecTrust. */
#define MQTT_CAP_PLATFORM_TRUST 128u
#define MQTT_CAP_INSECURE_TLS 256u
#define MQTT_CAP_NOTIFY 4u
#define MQTT_CAP_CONNECTION_DETAILS 8u
/* All CONNECTED/RECONNECTED events carry CONNACK sessionPresent (0 or 1). */
#define MQTT_CAP_SESSION_PRESENT 16u
#define MQTT_CAP_SUBSCRIBE_MANY 32u
#define MQTT_CAP_UNSUBSCRIBE_MANY 64u
#define MQTT_MAX_SUBSCRIPTIONS 256u
/* SDK errors are <= -1000. Other nonzero codes originate from Paho/broker. */
enum {
    MQTT_E_INVALID = -1000,
    MQTT_E_CLOSED = -1001,
    MQTT_E_LIMIT = -1002,
    MQTT_E_MEMORY = -1003,
    MQTT_E_CANCELLED = -1004,
    MQTT_E_STATE = -1005
};
enum {
    MQTT_OP_CREATE = 0,
    MQTT_OP_CONNECT = 1,
    MQTT_OP_SUBSCRIBE = 2,
    MQTT_OP_UNSUBSCRIBE = 3,
    MQTT_OP_PUBLISH = 4,
    MQTT_OP_DISCONNECT = 5,
    MQTT_OP_CLOSE = 6,
    MQTT_OP_SUBSCRIBE_MANY = 7,
    MQTT_OP_UNSUBSCRIBE_MANY = 8
};
enum {
    MQTT_EVENT_RESULT = 1,
    MQTT_EVENT_MESSAGE = 2,
    MQTT_EVENT_LOST = 3,
    MQTT_EVENT_CONNECTED = 4,
    MQTT_EVENT_RECONNECTING = 5,
    MQTT_EVENT_RECONNECTED = 6,
    MQTT_EVENT_CONNECT_FAILED = 7,
    MQTT_EVENT_RECONNECT_FAILED = 8
};
/* Strings are UTF-8, NUL terminated, copied before create returns. Null optional
 * strings mean unset. Protocol selection and binary password live in mqtt_config_v2. TLS verification
 * is enabled unless insecure_skip_verify=1 (debug ONLY: no peer/host checks).
 * In debug mode trust_store is ignored. Otherwise trust_store NULL selects platform trust; a non-NULL PEM
 * CA file is exclusive (invalid/empty files never fall back to system roots).
 * certificate is the client identity chain, independent of CA trust. Persistence path NULL selects in-memory persistence. */
typedef struct mqtt_config {
    uint32_t struct_size;
    int32_t keep_alive_seconds, connect_timeout_seconds, clean_session;
    int32_t automatic_reconnect, min_retry_seconds, max_retry_seconds, insecure_skip_verify; /* former reserved slot; requires INSECURE_TLS */
    const char *server_uri, *client_id, *username, *password, *trust_store;
    const char *certificate, *private_key, *private_key_password, *persistence_path;
} mqtt_config;
/* Data remains owned by this event until event_release. CONNECT RESULT is start
 * admission only (value=0); connection outcomes use CONNECTED/CONNECT_FAILED, etc.
 * SUBSCRIBE value is granted QoS; successful connection events carry sessionPresent.
 * SUBSCRIBE_MANY success: value/payload_length=count, payload contains one SUBACK
 * return code (0/1/2/0x80) per input topic, in order. Rejection is per-topic,
 * not an operation error. Other failures use code != 0, with no result payload.
 * flags: bit 0 retained, bit 1 duplicate. Incoming message QoS is value. */
typedef struct mqtt_event {
    uint64_t request_id;
    int32_t type, operation, code, value;
    uint32_t flags, topic_length, payload_length, reserved;
    const char *topic;
    const uint8_t *payload;
    /* Connection events only; appended ABI fields require CONNECTION_DETAILS.
     * timestamp/disconnected_at/attempt_started_at: Unix epoch milliseconds.
     * downtime: monotonic duration since disconnect (or first connect attempt if
     * no successful connection yet). Zero timestamps mean unavailable.
     * retry_attempt: attempts in current recovery cycle, 1-based at retry start;
     * total_retry_attempts: lifetime recovery attempts, includes initial-connect
     * recovery. reconnect_count: successful connections after the first success.
     * Auto retries count Paho scheduling callbacks, not individual TCP packets.
     * flags: bit 2 automatic attempt/success, bit 3 intentional disconnection.
     * value: sessionPresent (0/1) on all successful connections, -1 on other states. Sequence spans
     * all connection events; dropped_events counts connection events lost to queue overflow or
     * allocation failure.
     */
    uint64_t timestamp_ms, sequence, connection_count, reconnect_count;
    uint64_t retry_attempt, total_retry_attempts, disconnected_at_ms, downtime_ms;
    uint64_t attempt_started_at_ms, dropped_events;
    /* Requires ERRORS capability; immutable until event_release. */
    const mqtt_error *error;
} mqtt_event;
/* Notification runs on a dedicated dispatcher, never on Paho threads or under
 * the core mutex. Must only schedule work, never reenter this API or block.
 * Return 0 if receiver is gone; notification is then disabled (no busy retry).
 * Context ownership transfers only on successful registration. destroy is called
 * exactly once after release_client has quiesced all in-flight notifications. */
typedef int32_t (*mqtt_notify_fn)(void *context, uint64_t client);
typedef void (*mqtt_notify_destroy_fn)(void *context);
/* Shared runtime operations; obtain via mqtt_api_v2.core.
 * submit accepts CONNECT/CLOSE only; other operations use mqtt_api_v2.
 * Submission returns admission status, not MQTT completion.
 * CONNECT RESULT acknowledges MQTTAsync_connect admission, never its outcome.
 * Request IDs must increase strictly per client, starting at 1.
 * event_take: 1=event, 0=empty, negative=error; single consumer per handle.
 * close is asynchronous and rejects subsequent submissions. release_client is
 * permitted only after CLOSE completion, and discards remaining queued events.
 * All client operations are safe against stale numeric handles. */
typedef struct mqtt_core_api {
    uint32_t abi_version, struct_size;
    uint64_t capabilities;
    const char *(*paho_version)(void);
    int32_t (*submit)(uint64_t client, uint64_t request, int32_t operation, const char *topic,
                      const uint8_t *payload, uint32_t length, int32_t qos, int32_t retained);
    int32_t (*event_take)(uint64_t client, mqtt_event **out_event);
    void (*event_release)(mqtt_event *event);
    int32_t (*release_client)(uint64_t client);
    /* One registration per client. Existing queued events trigger notification.
     * Read until event_take returns 0 to rearm; after a bounded batch continue
     * locally until empty. release_client is a synchronous notification barrier. */
    int32_t (*set_notifier)(uint64_t client, mqtt_notify_fn notify, void *context,
                            mqtt_notify_destroy_fn destroy);
    int32_t (*dart_initialize)(void *initialize_api_dl_data);
    int32_t (*dart_set_port)(uint64_t client, int64_t native_port);
    void (*describe_error)(int32_t code, int32_t operation, mqtt_error *out);
} mqtt_core_api;
struct mqtt_api_v2;
/* ABI 1 has been removed. Only requested_abi=2 is supported. */
MQTT_API_EXPORT const struct mqtt_api_v2 *mqtt_get_api(uint32_t requested_abi);
#ifdef __cplusplus
}
#endif
#endif
