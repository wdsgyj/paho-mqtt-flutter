#include "mqtt_api.h"
#include "MQTTAsync.h"
#include "mqtt_diagnostics.h"
#ifndef MQTTASYNC_HAS_CONNECTED_WITH_SESSION
#error "Apply patches/paho-connected-session.patch to PAHO_SOURCE_DIR before building"
#endif
#include "mqtt_dart_bridge.h"
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_CLIENTS 64
#define MAX_PENDING 128
#define MAX_MESSAGES 256
#define MAX_STATES 256
#define MAX_BYTES (8u * 1024u * 1024u)
#define MAX_STRING 65535u

#include "mqtt_v2_properties.inc"

typedef struct event_node {
    mqtt_event event;
    mqtt_error error;
    mqtt_event_details_v2 details;
    struct event_node *next;
    size_t bytes;
} event_node;
typedef struct client client;
typedef struct command {
    struct command *next, *pending_next;
    client *owner;
    event_node *result;
    uint64_t request, attempt_id;
    int op, qos, retained, refs, finished;
    char *topic;
    uint8_t *payload;
    uint32_t length, topic_count;
    char **topics;
    int *qoss;
    size_t bytes;
    MQTTProperties properties;
    MQTTSubscribe_options *subopts;
    int reason, drain_ms, token, metadata_error;
} command;
struct client {
    struct client *next;
    uint64_t id, last_request;
    MQTTAsync handle;
    mqtt_config config;
    int closing, closed, create_error, pending_count, result_count;
    int message_count, state_count;
    size_t message_bytes, command_bytes;
    event_node *head, *tail;
    command *pending;
    mqtt_notify_fn notify;
    mqtt_notify_destroy_fn notify_destroy;
    void *notify_context;
    int notified, notifying, notifier_registered;
    uint64_t connection_count, retry_attempt, total_retry_attempts;
    uint64_t disconnected_at_ms, recovery_start_mono, attempt_started_at_ms;
    uint64_t connection_sequence, dropped_states;
    int attempt_automatic, session_present, connect_inflight, connect_active;
    uint64_t attempt_id, attempt_start_mono;
    mqtt_error connect_error;
    int protocol, clean_policy, disconnecting, server_disconnected, online;
    mqtt_config_v2 extra;
    MQTTProperties connect_props, will_props, connack_props, disconnect_props;
    unsigned session_expiry, server_receive, server_packet, server_qos, server_retain;
    unsigned server_wildcard, server_shared, server_subid;
    int connack_reason, server_reason, terminal, persistence_lock_fd;
};
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static pthread_cond_t notification_condition = PTHREAD_COND_INITIALIZER;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static client *clients;
static command *commands, *commands_tail;
static uint64_t next_id = 1;
static int client_count, worker_error;
static void *worker(void *unused);
static void *notification_worker(void *unused);
static void connection_event(client *c, int type, int code, int intentional);
static uint64_t clock_ms(clockid_t clock_id) {
    struct timespec time;
    clock_gettime(clock_id, &time);
    return (uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000;
}

static client *find_client(uint64_t id) {
    for (client *c = clients; c; c = c->next)
        if (c->id == id)
            return c;
    return NULL;
}
static void release_event(mqtt_event *event) {
    if (!event)
        return;
    event_node *node = (event_node *)event;
    properties_free(&node->details.properties);
    for (uint32_t i = 0; i < node->details.ack_count; i++)
        properties_free((mqtt_properties *)&node->details.acks[i].properties);
    free((void *)node->details.acks);
    free((void *)event->topic);
    free((void *)event->payload);
    free(event);
}
static void queue_event(client *c, event_node *e) {
    e->next = NULL;
    if (c->tail)
        c->tail->next = e;
    else
        c->head = e;
    c->tail = e;
    pthread_cond_signal(&notification_condition);
}
static void free_config(mqtt_config *c) {
    free((void *)c->server_uri);
    free((void *)c->client_id);
    free((void *)c->username);
    free((void *)c->password);
    free((void *)c->trust_store);
    free((void *)c->certificate);
    free((void *)c->private_key);
    free((void *)c->private_key_password);
    free((void *)c->persistence_path);
}
static int copy_string(const char *src, const char **dst) {
    *dst = NULL;
    if (!src)
        return 0;
    size_t n = strnlen(src, MAX_STRING + 1);
    if (n > MAX_STRING)
        return MQTT_E_INVALID;
    char *p = malloc(n + 1);
    if (!p)
        return MQTT_E_MEMORY;
    memcpy(p, src, n + 1);
    *dst = p;
    return 0;
}
static void unref_command(command *cmd) {
    if (--cmd->refs)
        return;
    cmd->owner->command_bytes -= cmd->bytes;
    free(cmd->topic);
    free(cmd->payload);
    for (uint32_t i = 0; i < cmd->topic_count; i++)
        free(cmd->topics[i]);
    free(cmd->topics);
    free(cmd->qoss);
    free(cmd->subopts);
    MQTTProperties_free(&cmd->properties);
    free(cmd);
}
/* mutex held; preallocated result ensures accepted operations cannot lose their
 * terminal event due to callback-time allocation failure. */
static void finish(command *cmd, int code, int value) {
    if (cmd->finished)
        return;
    cmd->finished = 1;
    if (cmd->op == MQTT_OP_DISCONNECT)
        cmd->owner->disconnecting = 0;
    client *c = cmd->owner;
    command **p = &c->pending;
    while (*p && *p != cmd)
        p = &(*p)->pending_next;
    if (*p)
        *p = cmd->pending_next;
    c->pending_count--;
    if ((code && cmd->op == MQTT_OP_SUBSCRIBE_MANY) ||
        (c->protocol != 5 && cmd->op == MQTT_OP_UNSUBSCRIBE_MANY)) {
        free((void *)cmd->result->event.payload);
        cmd->result->event.payload = NULL;
        cmd->result->event.payload_length = 0;
    }
    if (code) {
        mqtt_error *error = &cmd->result->error;
        if (!error->timestamp_ms || error->code != code)
            mqtt_error_complete(error, code, cmd->op, NULL);
        cmd->result->event.error = error;
    }
    cmd->result->event.code = code;
    cmd->result->event.value = value;
    queue_event(c, cmd->result);
    cmd->result = NULL;
    unref_command(cmd); /* callback ownership */
}
static void success(void *context, MQTTAsync_successData *data) {
    command *cmd = context;
    pthread_mutex_lock(&mutex);
    int value = 0, code = 0;
    if (cmd->op == MQTT_OP_CONNECT && data) {
        value = data->alt.connect.sessionPresent;
    }
    if (cmd->op == MQTT_OP_DISCONNECT) {
        client *c = cmd->owner;
        c->connect_active = c->online = 0;
        c->disconnected_at_ms = clock_ms(CLOCK_REALTIME);
        c->recovery_start_mono = clock_ms(CLOCK_MONOTONIC);
        c->retry_attempt = 0;
        connection_event(c, MQTT_EVENT_LOST, 0, 1);
    }
    if (cmd->op == MQTT_OP_SUBSCRIBE_MANY) {
        if (!data || (cmd->topic_count > 1 && !data->alt.qosList))
            code = MQTT_E_MEMORY;
        else {
            uint8_t *codes = (uint8_t *)cmd->result->event.payload;
            for (uint32_t i = 0; i < cmd->topic_count; i++)
                codes[i] = (uint8_t)(cmd->topic_count == 1 ? data->alt.qos : data->alt.qosList[i]);
            value = (int)cmd->topic_count;
        }
    }
    finish(cmd, code, value);
    pthread_mutex_unlock(&mutex);
}
static void failure(void *context, MQTTAsync_failureData *data) {
    pthread_mutex_lock(&mutex);
    command *cmd = context;
    /* Paho reports a one-filter SUBACK rejection via onFailure, while multi-
     * filter rejection uses onSuccess. Normalize both to per-filter results. */
    if (cmd->op == MQTT_OP_SUBSCRIBE_MANY && cmd->topic_count == 1 && data && data->code == 0x80) {
        ((uint8_t *)cmd->result->event.payload)[0] = 0x80;
        finish(cmd, 0, 1);
    } else {
        if (cmd->op != MQTT_OP_CONNECT && data)
            mqtt_error_complete(&cmd->result->error, data->code, cmd->op, data->message);
        finish(cmd, data && data->code ? data->code : MQTTASYNC_FAILURE, 0);
    }
    pthread_mutex_unlock(&mutex);
}
/* Core mutex held. Preserve connection transitions independently of message
 * queue pressure. Bounded overflow is explicit via sequence + dropped_events.
 */
static void connection_event(client *c, int type, int code, int intentional) {
    if (c->closing)
        return;
    uint64_t sequence = ++c->connection_sequence;
    event_node *e = calloc(1, sizeof(*e));
    if (!e) {
        c->dropped_states++;
        return;
    }
    if (c->state_count >= MAX_STATES) {
        event_node **p = &c->head, *previous = NULL;
        while (*p &&
               ((*p)->event.type == MQTT_EVENT_RESULT || (*p)->event.type == MQTT_EVENT_MESSAGE)) {
            previous = *p;
            p = &(*p)->next;
        }
        if (*p) {
            event_node *old = *p;
            *p = old->next;
            if (c->tail == old)
                c->tail = previous;
            release_event(&old->event);
            c->state_count--;
            c->dropped_states++;
        }
    }
    e->event.type = type;
    e->event.code = code;
    e->event.value =
        (type == MQTT_EVENT_CONNECTED || type == MQTT_EVENT_RECONNECTED) ? c->session_present : -1;
    e->event.flags = (type == MQTT_EVENT_LOST ? 0
                      : c->attempt_automatic  ? 4u
                                              : 0u) |
                     (intentional ? 8u : 0u);
    e->event.timestamp_ms = clock_ms(CLOCK_REALTIME);
    e->event.sequence = sequence;
    e->event.connection_count = c->connection_count;
    e->event.reconnect_count = c->connection_count ? c->connection_count - 1 : 0;
    e->event.retry_attempt = c->retry_attempt;
    e->event.total_retry_attempts = c->total_retry_attempts;
    e->event.disconnected_at_ms = c->disconnected_at_ms;
    e->event.downtime_ms =
        c->recovery_start_mono ? clock_ms(CLOCK_MONOTONIC) - c->recovery_start_mono : 0;
    e->event.attempt_started_at_ms = type == MQTT_EVENT_LOST ? 0 : c->attempt_started_at_ms;
    e->event.dropped_events = c->dropped_states;
    if (type == MQTT_EVENT_CONNECT_FAILED || type == MQTT_EVENT_RECONNECT_FAILED) {
        e->error = c->connect_error;
        e->event.error = &e->error;
        e->event.operation = MQTT_OP_CONNECT;
    }
    {
        const MQTTProperties *props = NULL;
        e->details.will_retry = c->connect_active;
        if (c->terminal && c->connect_error.code) {
            e->event.code = c->connect_error.code;
            e->error = c->connect_error;
            e->event.error = &e->error;
        }
        if (type == MQTT_EVENT_CONNECTED || type == MQTT_EVENT_RECONNECTED ||
            ((type == MQTT_EVENT_CONNECT_FAILED || type == MQTT_EVENT_RECONNECT_FAILED) &&
             c->connack_reason >= 0)) {
            e->details.packet_type = 2;
            e->details.reason_code = c->connack_reason;
            props = &c->connack_props;
        }
        if (type == MQTT_EVENT_LOST) {
            e->details.source = intentional ? 1 : (c->server_disconnected ? 2 : 3);
            e->details.will_retry = !intentional && c->connect_active;
            if (c->server_disconnected) {
                e->details.packet_type = 14;
                e->details.reason_code = c->server_reason;
                props = &c->disconnect_props;
            }
        }
        if (props && properties_out(&e->details.properties, props)) {
            e->event.code = MQTT_E_MEMORY;
            c->terminal = 1;
        }
    }
    c->state_count++;
    queue_event(c, e);
}
void mqtt_sdk_connect_failed(void *context, int code, const char *message, const mqtt_error *record,
                             int will_retry) {
    if (!context)
        return;
    client *c = context;
    pthread_mutex_lock(&mutex);
    c->connect_inflight = 0;
    c->connect_active = will_retry;
    c->connect_error = *record;
    mqtt_error_complete(&c->connect_error, code ? code : MQTTASYNC_FAILURE, MQTT_OP_CONNECT,
                        message);
    c->connect_error.attempt_id = c->attempt_id;
    c->connect_error.elapsed_ms = clock_ms(CLOCK_MONOTONIC) - c->attempt_start_mono;
    if (will_retry)
        c->connect_error.flags |= MQTT_ERROR_WILL_RETRY;
    connection_event(c,
                     c->connection_count ? MQTT_EVENT_RECONNECT_FAILED : MQTT_EVENT_CONNECT_FAILED,
                     c->connect_error.code, 0);
    pthread_mutex_unlock(&mutex);
}
static int tls_error_text(const char *text, size_t length, void *context) {
    (void)context;
    mqtt_diag_text(text, length);
    return 1;
}
static void lost(void *context, char *cause) {
    (void)cause;
    client *c = context;
    pthread_mutex_lock(&mutex);
    if (!c->online && c->server_disconnected) {
        pthread_mutex_unlock(&mutex);
        return;
    }
    c->online = 0;
    c->connect_active = c->config.automatic_reconnect && !c->terminal;
    c->disconnected_at_ms = clock_ms(CLOCK_REALTIME);
    c->recovery_start_mono = clock_ms(CLOCK_MONOTONIC);
    c->retry_attempt = 0;
    connection_event(c, MQTT_EVENT_LOST, 0, 0);
    pthread_mutex_unlock(&mutex);
}
static void connected(void *context, char *cause, int session_present) {
    (void)cause;
    client *c = context;
    pthread_mutex_lock(&mutex);
    /* The extended callback carries this CONNACK, including auto reconnect. */
    c->session_present = session_present;
    c->server_disconnected = 0;
    c->connect_inflight = 0;
    c->connect_active = c->online = 1;
    c->connection_count++;
    connection_event(c, c->connection_count == 1 ? MQTT_EVENT_CONNECTED : MQTT_EVENT_RECONNECTED, 0,
                     0);
    pthread_mutex_unlock(&mutex);
}
static int reconnect_attempt(void *context, MQTTAsync_connectData *data) {
    (void)data; /* Observe the public scheduling hook without changing
                   credentials. */
    client *c = context;
    pthread_mutex_lock(&mutex);
    c->retry_attempt++;
    c->total_retry_attempts++;
    c->attempt_automatic = 1;
    c->connect_inflight = 1;
    c->attempt_id++;
    c->attempt_start_mono = clock_ms(CLOCK_MONOTONIC);
    memset(&c->connect_error, 0, sizeof(c->connect_error));
    c->session_present = -1;
    c->connack_reason = -1;
    MQTTProperties_free(&c->connack_props);
    c->attempt_started_at_ms = clock_ms(CLOCK_REALTIME);
    connection_event(c, MQTT_EVENT_RECONNECTING, 0, 0);
    pthread_mutex_unlock(&mutex);
    return 0;
}
static int message(void *context, char *topic, int topic_length, MQTTAsync_message *msg) {
    client *c = context;
    size_t n = topic_length > 0 ? (size_t)topic_length : strlen(topic);
    size_t bytes = n + (size_t)msg->payloadlen + (size_t)msg->properties.length;
    pthread_mutex_lock(&mutex);
    if (c->closing) {
        pthread_mutex_unlock(&mutex);
        MQTTAsync_freeMessage(&msg);
        MQTTAsync_free(topic);
        return 1;
    }
    if (c->message_count >= (int)c->extra.max_messages ||
        bytes > c->extra.max_bytes - c->message_bytes) {
        pthread_mutex_unlock(&mutex);
        return 0;
    }
    event_node *e = calloc(1, sizeof(*e));
    if (e) {
        e->event.topic = malloc(n + 1);
        if (msg->payloadlen)
            e->event.payload = malloc((size_t)msg->payloadlen);
    }
    if (!e || !e->event.topic || (msg->payloadlen && !e->event.payload)) {
        if (e)
            release_event(&e->event);
        pthread_mutex_unlock(&mutex);
        return 0;
    }
    memcpy((void *)e->event.topic, topic, n);
    ((char *)e->event.topic)[n] = 0;
    if (msg->payloadlen)
        memcpy((void *)e->event.payload, msg->payload, (size_t)msg->payloadlen);
    e->event.type = MQTT_EVENT_MESSAGE;
    e->event.value = msg->qos;
    e->event.flags = (uint32_t)(msg->retained | (msg->dup << 1));
    e->event.topic_length = (uint32_t)n;
    e->event.payload_length = (uint32_t)msg->payloadlen;
    if (properties_out(&e->details.properties, &msg->properties)) {
        release_event(&e->event);
        pthread_mutex_unlock(&mutex);
        return 0;
    }
    e->bytes = bytes;
    c->message_bytes += bytes;
    c->message_count++;
    queue_event(c, e);
    pthread_mutex_unlock(&mutex);
    MQTTAsync_freeMessage(&msg);
    MQTTAsync_free(topic);
    return 1;
}
static void enqueue(command *cmd) {
    client *c = cmd->owner;
    cmd->pending_next = c->pending;
    c->pending = cmd;
    c->pending_count++;
    c->result_count++;
    cmd->refs = 2;
    cmd->result->event.type = MQTT_EVENT_RESULT;
    cmd->result->event.request_id = cmd->request;
    cmd->result->event.operation = cmd->op;
    if (commands_tail)
        commands_tail->next = cmd;
    else
        commands = cmd;
    commands_tail = cmd;
    pthread_cond_signal(&condition);
}
static void initialize(void) {
    pthread_t thread;
    worker_error = pthread_create(&thread, NULL, worker, NULL);
    if (!worker_error) {
        pthread_detach(thread);
        worker_error = pthread_create(&thread, NULL, notification_worker, NULL);
        if (!worker_error)
            pthread_detach(thread);
    }
}
static int copy_extra(client *, const mqtt_config_v2 *);
static void free_extra(client *);
static int32_t create_internal(const mqtt_config *cfg, const mqtt_config_v2 *extra, uint64_t *out) {
    if (!cfg || !out || cfg->struct_size != sizeof(*cfg) || !cfg->server_uri || !*cfg->server_uri ||
        !cfg->client_id || !*cfg->client_id || cfg->keep_alive_seconds < 0 ||
        cfg->keep_alive_seconds > 65535 || cfg->connect_timeout_seconds < 1 ||
        cfg->connect_timeout_seconds > 3600 || cfg->clean_session < 0 || cfg->clean_session > 1 ||
        cfg->automatic_reconnect < 0 || cfg->automatic_reconnect > 1 ||
        cfg->min_retry_seconds < 1 || cfg->max_retry_seconds < cfg->min_retry_seconds ||
        cfg->insecure_skip_verify < 0 || cfg->insecure_skip_verify > 1)
        return MQTT_E_INVALID;
    *out = 0;
    pthread_once(&once, initialize);
    if (worker_error)
        return MQTT_E_STATE;
    client *c = calloc(1, sizeof(*c));
    command *cmd = calloc(1, sizeof(*cmd));
    event_node *e = calloc(1, sizeof(*e));
    if (!c || !cmd || !e) {
        free(c);
        free(cmd);
        free(e);
        return MQTT_E_MEMORY;
    }
    c->persistence_lock_fd = -1;
    c->protocol = 4;
    c->connack_reason = -1;
    c->extra.max_pending = MAX_PENDING;
    c->extra.max_buffered = 128;
    c->extra.max_inflight = 128;
    c->extra.max_messages = MAX_MESSAGES;
    c->extra.max_bytes = MAX_BYTES;
    c->config = *cfg;
    c->config.server_uri = c->config.client_id = c->config.username = c->config.password = NULL;
    c->config.trust_store = c->config.certificate = c->config.private_key = NULL;
    c->config.private_key_password = c->config.persistence_path = NULL;
    int rc = 0;
#define COPY(field)                                                                                \
    if (!rc)                                                                                       \
    rc = copy_string(cfg->field, &c->config.field)
    COPY(server_uri);
    COPY(client_id);
    COPY(username);
    COPY(password);
    COPY(trust_store);
    COPY(certificate);
    COPY(private_key);
    COPY(private_key_password);
    COPY(persistence_path);
#undef COPY
    if (!rc)
        rc = copy_extra(c, extra);
    pthread_mutex_lock(&mutex);
    if (!rc && c->config.persistence_path) {
        for (client *other = clients; other; other = other->next)
            if (!other->closed && other->config.persistence_path &&
                !strcmp(c->config.persistence_path, other->config.persistence_path) &&
                !strcmp(c->config.server_uri, other->config.server_uri) &&
                !strcmp(c->config.client_id, other->config.client_id)) {
                rc = MQTT_E_STATE;
                break;
            }
    }
    if (!rc && (client_count >= MAX_CLIENTS || next_id == UINT64_MAX))
        rc = MQTT_E_LIMIT;
    if (!rc) {
        c->id = next_id++;
        c->next = clients;
        clients = c;
        client_count++;
        cmd->owner = c;
        cmd->op = MQTT_OP_CREATE;
        cmd->result = e;
        enqueue(cmd);
        *out = c->id;
    }
    pthread_mutex_unlock(&mutex);
    if (rc) {
        free_extra(c);
        free_config(&c->config);
        free(c);
        free(cmd);
        free(e);
    }
    return rc;
}
static int validate_operation(client *, int, const char *, int, int, const MQTTProperties *,
                              unsigned, int);
static int32_t submit_internal(uint64_t id, uint64_t request, int32_t op, const char *topic,
                               const uint8_t *payload, uint32_t length, int32_t qos,
                               int32_t retained, MQTTProperties *props, int reason, int drain) {
    if (!request || (op != MQTT_OP_CONNECT && op != MQTT_OP_CLOSE &&
                     op != MQTT_OP_PUBLISH && op != MQTT_OP_DISCONNECT) || qos < 0 || qos > 2 ||
        retained < 0 || retained > 1 || length > MAX_BYTES || (length && !payload))
        return MQTT_E_INVALID;
    if (op == MQTT_OP_PUBLISH &&
        (!topic || !*topic))
        return MQTT_E_INVALID;
    command *cmd = calloc(1, sizeof(*cmd));
    event_node *e = calloc(1, sizeof(*e));
    if (!cmd || !e) {
        free(cmd);
        free(e);
        return MQTT_E_MEMORY;
    }
    const char *copy = NULL;
    int rc = copy_string(topic, &copy);
    cmd->topic = (char *)copy;
    cmd->drain_ms = drain;
    cmd->reason = reason;
    if (props) {
        cmd->properties = *props;
        *props = (MQTTProperties)MQTTProperties_initializer;
    }
    if (!rc && length) {
        cmd->payload = malloc(length);
        if (!cmd->payload)
            rc = MQTT_E_MEMORY;
        else
            memcpy(cmd->payload, payload, length);
    }
    pthread_mutex_lock(&mutex);
    client *c = find_client(id);
    if (!rc && (!c || c->closing))
        rc = MQTT_E_CLOSED;
    if (!rc)
        rc = validate_operation(c, op, topic, qos, retained, &cmd->properties, length, 0);
    if (!rc && request <= c->last_request)
        rc = MQTT_E_INVALID;
    /* One reserved result slot for CLOSE, even when backpressured. */
    if (!rc && op != MQTT_OP_CLOSE && c->result_count >= (int)c->extra.max_pending)
        rc = MQTT_E_LIMIT;
    if (!rc && length + (size_t)cmd->properties.length > c->extra.max_bytes - c->command_bytes)
        rc = MQTT_E_LIMIT;
    if (!rc && (op == MQTT_OP_CONNECT || op == MQTT_OP_DISCONNECT)) {
        for (command *p = c->pending; p; p = p->pending_next)
            if (p->op == MQTT_OP_CONNECT || p->op == MQTT_OP_DISCONNECT) {
                rc = MQTT_E_STATE;
                break;
            }
    }
    if (!rc) {
        c->last_request = request;
        c->command_bytes += length + (size_t)cmd->properties.length;
        if (op == MQTT_OP_DISCONNECT)
            c->disconnecting = 1;
        if (op == MQTT_OP_CLOSE)
            c->closing = 1;
        cmd->owner = c;
        cmd->request = request;
        cmd->op = op;
        cmd->qos = qos;
        cmd->retained = retained;
        cmd->length = length;
        cmd->bytes = length + (size_t)cmd->properties.length;
        cmd->result = e;
        enqueue(cmd);
    }
    pthread_mutex_unlock(&mutex);
    if (rc) {
        free(cmd->topic);
        free(cmd->payload);
        MQTTProperties_free(&cmd->properties);
        free(cmd);
        free(e);
    }
    return rc;
}
static int32_t submit(uint64_t id, uint64_t request, int32_t op, const char *topic,
                      const uint8_t *payload, uint32_t length, int32_t qos, int32_t retained) {
    if (op != MQTT_OP_CONNECT && op != MQTT_OP_CLOSE)
        return MQTT_E_INVALID;
    return submit_internal(id, request, op, topic, payload, length, qos, retained, NULL, 0, 1000);
}
static int valid_filter(const char *topic) {
    if (!topic || !*topic)
        return 0;
    if (!strncmp(topic, "$share/", 7)) {
        const char *group = topic + 7, *separator = strchr(group, '/');
        if (!separator || separator == group || !separator[1])
            return 0;
        for (const char *p = group; p < separator; p++)
            if (*p == '+' || *p == '#')
                return 0;
    }
    for (const char *p = topic; *p; p++) {
        if (*p == '#' && ((p != topic && p[-1] != '/') || p[1]))
            return 0;
        if (*p == '+' && ((p != topic && p[-1] != '/') || (p[1] && p[1] != '/')))
            return 0;
    }
    return 1;
}
static int32_t filters_internal(uint64_t id, uint64_t request, uint32_t count,
                                const char *const *topics, const int32_t *qos, int op,
                                MQTTProperties *props, const mqtt_subscription_v2 *subs) {
    int subscribing = op == MQTT_OP_SUBSCRIBE_MANY;
    if (!request || !count || count > MQTT_MAX_SUBSCRIPTIONS || !topics || (subscribing && !qos))
        return MQTT_E_INVALID;
    size_t wire_bytes = 0;
    size_t bytes = count * (sizeof(char *) + (subscribing ? sizeof(int) + 1u : 0u));
    for (uint32_t i = 0; i < count; i++) {
        if (!topics[i] || (subscribing && (qos[i] < 0 || qos[i] > 2)))
            return MQTT_E_INVALID;
        size_t n = strnlen(topics[i], MAX_STRING + 1);
        if (n > MAX_STRING || !valid_filter(topics[i]))
            return MQTT_E_INVALID;
        bytes += n + 1;
        wire_bytes += n + 2 + (subscribing ? 1 : 0);
        if (bytes > MAX_BYTES)
            return MQTT_E_LIMIT;
    }
    command *cmd = calloc(1, sizeof(*cmd));
    event_node *e = calloc(1, sizeof(*e));
    if (!cmd || !e) {
        free(cmd);
        free(e);
        return MQTT_E_MEMORY;
    }
    cmd->topics = calloc(count, sizeof(char *));
    if (props) {
        cmd->properties = *props;
        *props = (MQTTProperties)MQTTProperties_initializer;
        bytes += cmd->properties.length;
    }
    if (subs) {
        cmd->subopts = calloc(count, sizeof(*cmd->subopts));
        if (cmd->subopts)
            for (uint32_t i = 0; i < count; i++) {
                cmd->subopts[i] = (MQTTSubscribe_options)MQTTSubscribe_options_initializer;
                cmd->subopts[i].noLocal = (unsigned char)subs[i].no_local;
                cmd->subopts[i].retainAsPublished = (unsigned char)subs[i].retain_as_published;
                cmd->subopts[i].retainHandling = (unsigned char)subs[i].retain_handling;
            }
    }
    e->event.payload = malloc(count);
    e->event.payload_length = count;
    if (subscribing) {
        cmd->qoss = calloc(count, sizeof(int));
        /* Result storage was reserved above for both SUBACK and UNSUBACK. */
        e->event.payload_length = count;
    }
    int rc = (!cmd->topics || !e->event.payload || (subs && !cmd->subopts) ||
              (subscribing && !cmd->qoss))
                 ? MQTT_E_MEMORY
                 : 0;
    for (uint32_t i = 0; !rc && i < count; i++) {
        const char *copy = NULL;
        rc = copy_string(topics[i], &copy);
        cmd->topics[i] = (char *)copy;
        if (subscribing)
            cmd->qoss[i] = qos[i];
    }
    pthread_mutex_lock(&mutex);
    client *c = find_client(id);
    if (!rc && (!c || c->closing))
        rc = MQTT_E_CLOSED;
    if (!rc) {
        for (uint32_t i = 0; !rc && i < count; i++)
            rc = validate_operation(c, op, topics[i], subscribing ? qos[i] : 0, 0, &cmd->properties,
                                    (unsigned)wire_bytes, 0);
    }
    if (!rc && request <= c->last_request)
        rc = MQTT_E_INVALID;
    if (!rc && (c->result_count >= (int)c->extra.max_pending ||
                bytes > c->extra.max_bytes - c->command_bytes))
        rc = MQTT_E_LIMIT;
    if (!rc) {
        c->last_request = request;
        c->command_bytes += bytes;
        cmd->owner = c;
        cmd->request = request;
        cmd->op = op;
        cmd->topic_count = count;
        cmd->bytes = bytes;
        cmd->result = e;
        enqueue(cmd);
    }
    pthread_mutex_unlock(&mutex);
    if (rc) {
        if (cmd->topics)
            for (uint32_t i = 0; i < count; i++)
                free(cmd->topics[i]);
        free(cmd->topics);
        free(cmd->qoss);
        free(cmd->subopts);
        MQTTProperties_free(&cmd->properties);
        free(cmd);
        release_event(&e->event);
    }
    return rc;
}
static int32_t take_event(uint64_t id, mqtt_event **out) {
    if (!out)
        return MQTT_E_INVALID;
    *out = NULL;
    pthread_mutex_lock(&mutex);
    client *c = find_client(id);
    if (!c) {
        pthread_mutex_unlock(&mutex);
        return MQTT_E_CLOSED;
    }
    event_node *e = c->head;
    if (!e)
        c->notified = 0; /* Atomic empty observation/rearm, no lost wakeup. */
    if (e) {
        c->head = e->next;
        if (!c->head)
            c->tail = NULL;
        if (e->event.type == MQTT_EVENT_RESULT)
            c->result_count--;
        else if (e->event.type == MQTT_EVENT_MESSAGE) {
            c->message_count--;
            c->message_bytes -= e->bytes;
        } else
            c->state_count--;
        *out = &e->event;
    }
    pthread_mutex_unlock(&mutex);
    return e ? 1 : 0;
}
static int32_t release_client(uint64_t id) {
    pthread_mutex_lock(&mutex);
    client **p = &clients;
    while (*p && (*p)->id != id)
        p = &(*p)->next;
    client *c = *p;
    if (!c || !c->closed) {
        pthread_mutex_unlock(&mutex);
        return c ? MQTT_E_STATE : MQTT_E_CLOSED;
    }
    *p = c->next;
    client_count--;
    c->notify = NULL; /* Removed from registry: dispatcher cannot select it again. */
    while (c->notifying)
        pthread_cond_wait(&notification_condition, &mutex);
    pthread_mutex_unlock(&mutex);
    if (c->notify_destroy)
        c->notify_destroy(c->notify_context);
    while (c->head) {
        event_node *e = c->head;
        c->head = e->next;
        release_event(&e->event);
    }
    free_extra(c);
    free_config(&c->config);
    free(c);
    return 0;
}
#include "mqtt_v2_core.inc"

static void execute(command *cmd) {
    client *c = cmd->owner;
    int rc = 0;
    if (cmd->op == MQTT_OP_CREATE) {
        MQTTAsync_createOptions opts = MQTTAsync_createOptions_initializer;
        opts.MQTTVersion = c->protocol;
        {
            opts.struct_version = 3;
            opts.restoreMessages = c->extra.restore_messages;
            opts.persistQoS0 = c->extra.persist_qos0;
        }
        opts.maxBufferedMessages = (int)c->extra.max_buffered;
        rc = MQTTAsync_createWithOptions(&c->handle, c->config.server_uri, c->config.client_id,
                                         c->config.persistence_path ? MQTTCLIENT_PERSISTENCE_DEFAULT
                                                                    : MQTTCLIENT_PERSISTENCE_NONE,
                                         (void *)c->config.persistence_path, &opts);
        if (!rc)
            rc = MQTTAsync_setCallbacks(c->handle, c, lost, message, NULL);
        if (!rc)
            rc = MQTTAsync_setDisconnected(c->handle, c, server_disconnect);
        if (!rc)
            rc = MQTTAsync_setConnectedWithSession(c->handle, c, connected);
        if (!rc)
            rc = MQTTAsync_setUpdateConnectOptions(c->handle, c, reconnect_attempt);
        c->create_error = rc;
    } else if (cmd->op == MQTT_OP_CLOSE) {
        if (c->handle)
            MQTTAsync_destroy(&c->handle);
        pthread_mutex_lock(&mutex);
        /* destroy serializes against Paho callbacks. Queued commands preceding
         * CLOSE have already been dispatched by this single worker. */
        command *p = c->pending;
        while (p) {
            command *next = p->pending_next;
            if (p != cmd)
                finish(p, MQTT_E_CANCELLED, 0);
            p = next;
        }
        finish(cmd, 0, 0);
        unref_command(cmd); /* finish worker ownership before publishing CLOSED */
        c->closed = 1;
        pthread_mutex_unlock(&mutex);
        return;
    } else if (!c->handle || c->create_error)
        rc = c->create_error ? c->create_error : MQTT_E_STATE;
    else if (cmd->op == MQTT_OP_CONNECT && MQTTAsync_isConnected(c->handle))
        rc = MQTT_E_STATE;
    else if (cmd->op == MQTT_OP_CONNECT) {
        pthread_mutex_lock(&mutex);
        if (c->connect_active) {
            finish(cmd, MQTT_E_STATE, 0);
            unref_command(cmd);
            pthread_mutex_unlock(&mutex);
            return;
        }
        c->connect_inflight = 1;
        c->connect_active = 1;
        c->attempt_id++;
        cmd->attempt_id = c->attempt_id;
        c->attempt_start_mono = clock_ms(CLOCK_MONOTONIC);
        memset(&c->connect_error, 0, sizeof(c->connect_error));
        c->attempt_automatic = 0;
        c->session_present = -1;
        c->connack_reason = -1;
        MQTTProperties_free(&c->connack_props);
        int retry = c->attempt_started_at_ms != 0;
        c->attempt_started_at_ms = clock_ms(CLOCK_REALTIME);
        if (!c->recovery_start_mono)
            c->recovery_start_mono = clock_ms(CLOCK_MONOTONIC);
        if (retry) {
            c->retry_attempt++;
            c->total_retry_attempts++;
            connection_event(c, MQTT_EVENT_RECONNECTING, 0, 0);
        }
        pthread_mutex_unlock(&mutex);
        MQTTAsync_connectOptions opts = MQTTAsync_connectOptions_initializer;
        MQTTAsync_SSLOptions ssl = MQTTAsync_SSLOptions_initializer;
        opts.MQTTVersion = c->protocol;
        opts.keepAliveInterval = c->config.keep_alive_seconds;
        opts.connectTimeout = c->config.connect_timeout_seconds;
        opts.cleansession = c->protocol == 5 ? 0 : c->config.clean_session;
        opts.cleanstart = c->protocol == 5 ? clean_start_value(c) : 0;
        opts.maxInflight = (int)c->extra.max_inflight;
        opts.retryInterval = 0;
        if (c->protocol == 5)
            opts.connectProperties = &c->connect_props;
        if (c->extra.password_present) {
            opts.binarypwd.len = (int)c->extra.password_length;
            opts.binarypwd.data = c->extra.password_bytes;
        }
        MQTTAsync_willOptions will = MQTTAsync_willOptions_initializer;
        if (c->extra.will_topic) {
            will.topicName = c->extra.will_topic;
            will.payload.data = c->extra.will_payload;
            will.payload.len = (int)c->extra.will_length;
            will.qos = (int)c->extra.will_qos;
            will.retained = (int)c->extra.will_retained;
            opts.will = &will;
            if (c->protocol == 5)
                opts.willProperties = &c->will_props;
        }
        opts.username = c->config.username;
        opts.password = c->config.password;
        opts.automaticReconnect = c->config.automatic_reconnect;
        opts.minRetryInterval = c->config.min_retry_seconds;
        opts.maxRetryInterval = c->config.max_retry_seconds;
        ssl.ssl_error_cb = tls_error_text;
        ssl.ssl_error_context = c;
        ssl.trustStore = c->config.trust_store;
        ssl.keyStore = c->config.certificate;
        ssl.privateKey = c->config.private_key;
        ssl.privateKeyPassword = c->config.private_key_password;
        ssl.enableServerCertAuth = !c->config.insecure_skip_verify;
        ssl.verify = !c->config.insecure_skip_verify;
        if (!strncmp(c->config.server_uri, "ssl://", 6) ||
            !strncmp(c->config.server_uri, "mqtts://", 8) ||
            !strncmp(c->config.server_uri, "wss://", 6))
            opts.ssl = &ssl;
        /* Connection outcomes use the client-scoped hooks only. Never retain
         * the short-lived start command as a Paho callback context. */
        rc = MQTTAsync_connect(c->handle, &opts);
        if (rc) {
            pthread_mutex_lock(&mutex);
            c->connect_inflight = c->connect_active = 0;
            mqtt_error_complete(&cmd->result->error, rc, MQTT_OP_CONNECT, NULL);
            cmd->result->error.stage = MQTT_STAGE_ADMISSION;
            pthread_mutex_unlock(&mutex);
        }
    } else if (!MQTTAsync_isConnected(c->handle))
        rc = MQTT_E_STATE;
    else if ((rc = validate_command(cmd)) != 0) {
        /* The connection may have changed since admission. */
    } else if (cmd->op == MQTT_OP_DISCONNECT) {
        MQTTAsync_disconnectOptions opts = MQTTAsync_disconnectOptions_initializer;
        opts.timeout = cmd->drain_ms;
        if (c->protocol == 5) {
            opts.struct_version = 1;
            opts.reasonCode = cmd->reason;
            opts.properties = cmd->properties;
        }
        if (c->protocol == 5) {
            opts.onSuccess5 = success5;
            opts.onFailure5 = failure5;
        } else {
            opts.onSuccess = success;
            opts.onFailure = failure;
        }
        opts.context = cmd;
        rc = MQTTAsync_disconnect(c->handle, &opts);
    } else {
        MQTTAsync_responseOptions opts = MQTTAsync_responseOptions_initializer;
        if (c->protocol == 5) {
            opts.onSuccess5 = success5;
            opts.onFailure5 = failure5;
        } else {
            opts.onSuccess = success;
            opts.onFailure = failure;
        }
        opts.context = cmd;
        if (c->protocol == 5)
            opts.properties = cmd->properties;
        if (cmd->subopts) {
            opts.subscribeOptions = cmd->subopts[0];
            opts.subscribeOptionsCount = (int)cmd->topic_count;
            opts.subscribeOptionsList = cmd->subopts;
        }
        if (cmd->op == MQTT_OP_SUBSCRIBE_MANY)
            rc = MQTTAsync_subscribeMany(c->handle, (int)cmd->topic_count, cmd->topics, cmd->qoss,
                                         &opts);
        else if (cmd->op == MQTT_OP_UNSUBSCRIBE_MANY)
            rc = MQTTAsync_unsubscribeMany(c->handle, (int)cmd->topic_count, cmd->topics, &opts);
        else {
            MQTTAsync_message msg = MQTTAsync_message_initializer;
            msg.payload = cmd->payload;
            msg.payloadlen = (int)cmd->length;
            msg.qos = cmd->qos;
            msg.retained = cmd->retained;
            if (c->protocol == 5)
                msg.properties = cmd->properties;
            rc = MQTTAsync_sendMessage(c->handle, cmd->topic, &msg, &opts);
        }
    }
    pthread_mutex_lock(&mutex);
    if (rc || cmd->op == MQTT_OP_CREATE || cmd->op == MQTT_OP_CONNECT)
        finish(cmd, rc, 0);
    unref_command(cmd);
    pthread_mutex_unlock(&mutex);
}
static void *worker(void *unused) {
    (void)unused;
    for (;;) {
        pthread_mutex_lock(&mutex);
        while (!commands)
            pthread_cond_wait(&condition, &mutex);
        command *cmd = commands;
        commands = cmd->next;
        if (!commands)
            commands_tail = NULL;
        pthread_mutex_unlock(&mutex);
        execute(cmd);
    }
    return NULL;
}
static int32_t set_notifier(uint64_t id, mqtt_notify_fn notify, void *context,
                            mqtt_notify_destroy_fn destroy) {
    if (!notify)
        return MQTT_E_INVALID;
    pthread_mutex_lock(&mutex);
    client *c = find_client(id);
    int rc = !c ? MQTT_E_CLOSED : c->notifier_registered ? MQTT_E_STATE : 0;
    if (!rc) {
        c->notify = notify;
        c->notify_context = context;
        c->notify_destroy = destroy;
        c->notifier_registered = 1;
        c->notified = 0;
        pthread_cond_signal(&notification_condition);
    }
    pthread_mutex_unlock(&mutex);
    return rc;
}
static void *notification_worker(void *unused) {
    (void)unused;
    pthread_mutex_lock(&mutex);
    for (;;) {
        client *c = NULL;
        for (client *p = clients; p; p = p->next)
            if (p->head && p->notify && !p->notified) {
                c = p;
                break;
            }
        if (!c) {
            pthread_cond_wait(&notification_condition, &mutex);
            continue;
        }
        c->notified = 1;
        c->notifying = 1;
        mqtt_notify_fn notify = c->notify;
        void *context = c->notify_context;
        uint64_t id = c->id;
        pthread_mutex_unlock(&mutex);
        int accepted = notify(context, id);
        pthread_mutex_lock(&mutex);
        if (!accepted)
            c->notify = NULL;
        c->notifying = 0;
        pthread_cond_broadcast(&notification_condition);
    }
    return NULL;
}
static const char *paho_version(void) {
    const MQTTAsync_nameValue *entry = MQTTAsync_getVersionInfo();
    for (; entry && entry->name; ++entry)
        if (!strcmp(entry->name, "Version"))
            return entry->value;
    return "unknown";
}
static const mqtt_core_api api = {MQTT_CORE_API_VERSION,
                                sizeof(mqtt_core_api),
                                MQTT_CAP_CLIENT | MQTT_CAP_NOTIFY | MQTT_CAP_CONNECTION_DETAILS |
                                    MQTT_CAP_SESSION_PRESENT | MQTT_CAP_SUBSCRIBE_MANY |
                                    MQTT_CAP_UNSUBSCRIBE_MANY | MQTT_CAP_ERRORS |
                                    MQTT_CAP_START_CONNECTING
#ifdef MQTT_SDK_TLS
                                    | MQTT_CAP_TLS | MQTT_CAP_PLATFORM_TRUST | MQTT_CAP_INSECURE_TLS
#endif
                                ,
                                paho_version,
                                submit,
                                take_event,
                                release_event,
                                release_client,
                                set_notifier,
                                mqtt_dart_initialize,
                                mqtt_dart_set_port,
                                mqtt_error_describe};
#include "mqtt_v2_table.inc"
const mqtt_api_v2 *mqtt_get_api(uint32_t version) {
    return version == 2 ? &api2 : NULL;
}
