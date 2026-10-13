#ifndef MQTT_SDK_API_V2_H
#define MQTT_SDK_API_V2_H
#include "mqtt_api.h"
/* SDK-owned property values, never Paho objects. Strings are length-delimited
 * UTF-8. IDs are MQTT 5 property identifiers; permitted IDs depend on packet.
 */
typedef struct mqtt_property {
    uint32_t id, number, length, value_length;
    const uint8_t *data, *value;
} mqtt_property;
typedef struct mqtt_properties {
    uint32_t count;
    const mqtt_property *items;
} mqtt_properties;
typedef struct mqtt_config_v2 {
    mqtt_config base;
    uint32_t struct_size, protocol, clean_start_policy, session_expiry;
    uint32_t max_pending, max_buffered, max_inflight, max_messages, max_bytes;
    uint32_t password_present, password_length;
    const uint8_t *password_bytes;
    const char *will_topic;
    const uint8_t *will_payload;
    uint32_t will_length, will_qos, will_retained;
    mqtt_properties connect_properties, will_properties;
    uint32_t restore_messages, persist_qos0;
} mqtt_config_v2;
typedef struct mqtt_subscription_v2 {
    const char *filter;
    uint32_t qos, no_local, retain_as_published, retain_handling;
} mqtt_subscription_v2;
typedef struct mqtt_ack_v2 {
    int32_t packet_type, reason_code;
    mqtt_properties properties;
} mqtt_ack_v2;
typedef struct mqtt_event_details_v2 {
    int32_t packet_type, reason_code, source, will_retry;
    mqtt_properties properties;
    uint32_t ack_count;
    const mqtt_ack_v2 *acks;
} mqtt_event_details_v2;
/* The only client API, shared by the MQTT 3.1.1 and MQTT 5 Flutter facades.
 * create reserves a handle and queues creation (RESULT request=0).
 * Check both this table and core->abi_version before calling any functions. */
typedef struct mqtt_api_v2 {
    uint32_t abi_version, struct_size;
    uint64_t capabilities;
    const mqtt_core_api *core;
    int32_t (*create)(const mqtt_config_v2 *, uint64_t *);
    int32_t (*publish)(uint64_t, uint64_t, const char *, const uint8_t *, uint32_t, uint32_t,
                       uint32_t, const mqtt_properties *);
    int32_t (*subscribe)(uint64_t, uint64_t, uint32_t, const mqtt_subscription_v2 *,
                         const mqtt_properties *);
    int32_t (*unsubscribe)(uint64_t, uint64_t, uint32_t, const char *const *,
                           const mqtt_properties *);
    int32_t (*disconnect)(uint64_t, uint64_t, uint32_t, const mqtt_properties *);
    int32_t (*disconnect_with_will)(uint64_t, uint64_t, uint32_t, const mqtt_properties *);
    int32_t (*disconnect_unspecified)(uint64_t, uint64_t, uint32_t, const mqtt_properties *);
    int32_t (*disconnect_implementation)(uint64_t, uint64_t, const char *, uint32_t,
                                         const mqtt_properties *);
    const mqtt_event_details_v2 *(*event_details)(const mqtt_event *);
} mqtt_api_v2;
#endif
