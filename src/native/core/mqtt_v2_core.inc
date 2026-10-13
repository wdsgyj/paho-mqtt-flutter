#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
static int copy_blob(const uint8_t *src, uint32_t len, const uint8_t **dst) {
    *dst = NULL;
    if (len > MAX_BYTES || (len && !src))
        return MQTT_E_INVALID;
    uint8_t *p = malloc((size_t)len + 1);
    if (!p)
        return MQTT_E_MEMORY;
    if (len)
        memcpy(p, src, len);
    p[len] = 0;
    *dst = p;
    return 0;
}
/* Hex chunks preserve the exact identity without hash collisions or unsafe path components. */
static int persistence_identity(client *c) {
    const char *root = c->config.persistence_path;
    const char *identity[] = {c->config.server_uri, c->config.client_id};
    if (strpbrk(identity[1], "/\\") || strchr(identity[0] + 6, '/'))
        return MQTT_E_INVALID;
    size_t l0 = strlen(identity[0]), l1 = strlen(identity[1]);
    size_t capacity = strlen(root) + 2 * (l0 + l1) + 3 * ((l0 + 47) / 48 + (l1 + 47) / 48) + 64;
    char *path = malloc(capacity);
    if (!path)
        return MQTT_E_MEMORY;
    strcpy(path, root);
    if (mkdir(path, 0700) && errno != EEXIST) {
        free(path);
        return MQTT_E_INVALID;
    }
    snprintf(path + strlen(path), capacity - strlen(path), "/mqtt-%u", c->protocol);
    if (mkdir(path, 0700) && errno != EEXIST) {
        free(path);
        return MQTT_E_INVALID;
    }
    const char *hex = "0123456789abcdef";
    for (int part = 0; part < 2; part++) {
        size_t length = strlen(identity[part]);
        for (size_t offset = 0; offset < length; offset += 48) {
            size_t n = strlen(path);
            path[n++] = '/';
            path[n++] = part ? 'c' : 'b';
            path[n++] = '-';
            for (size_t j = offset; j < length && j < offset + 48; j++) {
                unsigned char value = (unsigned char)identity[part][j];
                path[n++] = hex[value >> 4];
                path[n++] = hex[value & 15];
            }
            path[n] = 0;
            if (mkdir(path, 0700) && errno != EEXIST) {
                free(path);
                return MQTT_E_INVALID;
            }
        }
    }
    size_t n = strlen(path);
    strcpy(path + n, "/.sdk-lock");
    int fd = open(path, O_CREAT | O_RDWR, 0600);
    path[n] = 0;
    if (fd < 0) {
        free(path);
        return MQTT_E_INVALID;
    }
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        close(fd);
        free(path);
        return MQTT_E_STATE;
    }
    c->persistence_lock_fd = fd;
    free((void *)c->config.persistence_path);
    c->config.persistence_path = path;
    return 0;
}
static int copy_extra(client *c, const mqtt_config_v2 *x) {
    if (x->struct_size != sizeof(*x) || (x->protocol != 4 && x->protocol != 5) ||
        x->clean_start_policy > 2 || !x->max_pending || x->max_pending > 65535 ||
        !x->max_buffered || x->max_buffered > 65535 || !x->max_inflight ||
        x->max_inflight > 65535 || !x->max_messages || x->max_messages > 65535 || !x->max_bytes ||
        x->max_bytes > MAX_BYTES || x->restore_messages > 1 || x->persist_qos0 > 1 ||
        x->password_present > 1 || x->will_qos > 2 || x->will_retained > 1)
        return MQTT_E_INVALID;
    if (!UTF8_validateString(c->config.client_id) ||
        (c->config.username && !UTF8_validateString(c->config.username)))
        return MQTT_E_INVALID;
    c->protocol = (int)x->protocol;
    c->clean_policy = (int)x->clean_start_policy;
    c->extra = *x;
    c->extra.password_bytes = NULL;
    c->extra.will_topic = NULL;
    c->extra.will_payload = NULL;
    c->extra.connect_properties = (mqtt_properties){0};
    c->extra.will_properties = (mqtt_properties){0};
    c->session_expiry = x->session_expiry;
    c->server_receive = 65535;
    c->server_packet = 268435460;
    c->server_qos = 2;
    c->server_retain = c->server_wildcard = c->server_shared = c->server_subid = 1;
    if (strncmp(c->config.server_uri, "tcp://", 6) && strncmp(c->config.server_uri, "ssl://", 6))
        return MQTT_E_INVALID;
    if (c->protocol == 4 &&
        (x->connect_properties.count || x->will_properties.count || x->session_expiry))
        return MQTT_E_INVALID;
    int rc = properties_in(&x->connect_properties, &c->connect_props, 1);
    if (!rc && MQTTProperties_hasProperty(&c->connect_props, 17))
        rc = MQTT_E_INVALID; /* session is a single source */
    if (!rc && c->protocol == 5)
        rc = add_number(&c->connect_props, 17, x->session_expiry);
    /* Custom inbound Receive Maximum is withheld until the receiver enforces it.
     */
    if (!rc && MQTTProperties_hasProperty(&c->connect_props, 33))
        rc = MQTT_E_INVALID;
    if (!rc)
        rc = properties_in(&x->will_properties, &c->will_props, 99);
    if (!rc && x->password_present) {
        if (x->password_length > 65535 || c->config.password)
            rc = MQTT_E_INVALID;
        else
            rc = copy_blob(x->password_bytes, x->password_length, &c->extra.password_bytes);
    }
    if (!rc && x->will_topic) {
        if (!*x->will_topic || !UTF8_validateString(x->will_topic) || strpbrk(x->will_topic, "+#"))
            rc = MQTT_E_INVALID;
        else
            rc = copy_string(x->will_topic, &c->extra.will_topic);
        if (!rc)
            rc = copy_blob(x->will_payload, x->will_length, &c->extra.will_payload);
        if (!rc && numeric(&c->will_props, 1, 0) == 1 && x->will_length &&
            !UTF8_validate((int)x->will_length, (const char *)x->will_payload))
            rc = MQTT_E_INVALID;
    } else if (!rc && (x->will_length || x->will_properties.count))
        rc = MQTT_E_INVALID;
    if (!rc && c->config.persistence_path)
        rc = persistence_identity(c);

    return rc;
}
static void free_extra(client *c) {
    if (c->persistence_lock_fd >= 0) {
        flock(c->persistence_lock_fd, LOCK_UN);
        close(c->persistence_lock_fd);
        c->persistence_lock_fd = -1;
    }
    free((void *)c->extra.password_bytes);
    free((void *)c->extra.will_topic);
    free((void *)c->extra.will_payload);
    MQTTProperties_free(&c->connect_props);
    MQTTProperties_free(&c->will_props);
    MQTTProperties_free(&c->connack_props);
    MQTTProperties_free(&c->disconnect_props);
}
static int clean_start_value(client *c) {
    return c->clean_policy == 0 || (c->clean_policy == 1 && c->connection_count == 0);
}
int mqtt_sdk_clean_start(void *context) {
    if (!context)
        return 0;
    client *c = context;
    pthread_mutex_lock(&mutex);
    int r = clean_start_value(c);
    pthread_mutex_unlock(&mutex);
    return r;
}
unsigned mqtt_sdk_session_expiry(void *context) {
    return context ? ((client *)context)->session_expiry : 0;
}
int mqtt_sdk_inflight(void *context) {
    client *c = context;
    if (!c)
        return 65535;
    return (int)(c->extra.max_inflight < c->server_receive ? c->extra.max_inflight
                                                           : c->server_receive);
}
void mqtt_sdk_connack(void *context, int reason, const MQTTProperties *props) {
    if (!context)
        return;
    client *c = context;
    pthread_mutex_lock(&mutex);
    MQTTProperties_free(&c->connack_props);
    c->connack_props = MQTTProperties_copy(props);
    if (props && c->connack_props.count != props->count) {
        c->terminal = 1;
        mqtt_error_complete(&c->connect_error, MQTT_E_MEMORY, MQTT_OP_CONNECT,
                            "CONNACK property copy failed");
    }
    c->connack_reason = reason;
    c->server_receive = numeric(props, 33, 65535);
    c->server_packet = numeric(props, 39, 268435460);
    c->server_qos = numeric(props, 36, 2);
    c->server_retain = numeric(props, 37, 1);
    c->server_wildcard = numeric(props, 40, 1);
    c->server_subid = numeric(props, 41, 1);
    c->server_shared = numeric(props, 42, 1);
    c->session_expiry = numeric(props, 17, c->extra.session_expiry);
    pthread_mutex_unlock(&mutex);
}
void mqtt_sdk_token(void *context, void *operation, int token) {
    if (!context || !operation)
        return;
    client *c = context;
    pthread_mutex_lock(&mutex);
    for (command *p = c->pending; p; p = p->pending_next)
        if (p == operation) {
            p->token = token;
            break;
        }
    pthread_mutex_unlock(&mutex);
}
void mqtt_sdk_ack(void *context, int token, int packet, int reason, const MQTTProperties *props) {
    if (!context)
        return;
    client *c = context;
    pthread_mutex_lock(&mutex);
    /* request token is assigned by Paho before queue admission. It is independent of SDK
     * request IDs. */
    for (command *p = c->pending; p; p = p->pending_next)
        if (p->op == MQTT_OP_PUBLISH && p->token == token && p->result) {
            mqtt_event_details_v2 *d = &p->result->details;
            d->packet_type = packet;
            d->reason_code = reason;
            /* One entry per ACK type, retransmitted ACKs replace the previous
             * snapshot. */
            uint32_t i = 0;
            for (; i < d->ack_count; i++)
                if (d->acks[i].packet_type == packet)
                    break;
            if (i == d->ack_count) {
                mqtt_ack_v2 *a = realloc((void *)d->acks, (i + 1) * sizeof(*a));
                if (!a) {
                    p->metadata_error = MQTT_E_MEMORY;
                    break;
                }
                d->acks = a;
                memset(&a[i], 0, sizeof(a[i]));
                d->ack_count++;
            }
            mqtt_ack_v2 *a = (mqtt_ack_v2 *)&d->acks[i];
            properties_free(&a->properties);
            a->packet_type = packet;
            a->reason_code = reason;
            int rc = properties_out(&a->properties, props);
            if (rc)
                p->metadata_error = rc;
            break;
        }
    pthread_mutex_unlock(&mutex);
}
static void server_disconnect(void *context, MQTTProperties *props, enum MQTTReasonCodes reason) {
    client *c = context;
    pthread_mutex_lock(&mutex);
    c->server_disconnected = 1;
    c->server_reason = reason;
    MQTTProperties_free(&c->disconnect_props);
    c->disconnect_props = MQTTProperties_copy(props);
    if (props && c->disconnect_props.count != props->count) {
        c->terminal = 1;
        mqtt_error_complete(&c->connect_error, MQTT_E_MEMORY, MQTT_OP_DISCONNECT,
                            "DISCONNECT property copy failed");
    }
    c->online = 0;
    c->connect_active = c->config.automatic_reconnect && !c->terminal;
    c->disconnected_at_ms = clock_ms(CLOCK_REALTIME);
    c->recovery_start_mono = clock_ms(CLOCK_MONOTONIC);
    c->retry_attempt = 0;
    connection_event(c, MQTT_EVENT_LOST, 0, 0);
    pthread_mutex_unlock(&mutex);
}
static _Thread_local client *reading_client;
void mqtt_sdk_read_enter(void *context) { reading_client = context; }
int mqtt_sdk_packet_allowed(size_t bytes) {
    client *c = reading_client;
    if (!c)
        return 1;
    unsigned maximum = numeric(&c->connect_props, 39, c->extra.max_bytes);
    if (bytes <= maximum && bytes <= c->extra.max_bytes)
        return 1;
    pthread_mutex_lock(&mutex);
    c->terminal = 1;
    mqtt_error_complete(&c->connect_error, MQTT_E_LIMIT, MQTT_OP_PUBLISH,
                        "Incoming packet exceeds configured size limit");
    pthread_mutex_unlock(&mutex);
    mqtt_diag_stage(MQTT_STAGE_OPERATION);
    mqtt_diag_text("Incoming packet exceeds configured size limit", 45);
    return 0;
}
int mqtt_sdk_outgoing_allowed(void *context, size_t bytes) {
    if (!context)
        return 1;
    client *c = context;
    pthread_mutex_lock(&mutex);
    int allowed = c->protocol != 5 || bytes <= c->server_packet;
    pthread_mutex_unlock(&mutex);
    if (!allowed) {
        mqtt_diag_stage(MQTT_STAGE_OPERATION);
        mqtt_diag_text("Outgoing packet exceeds server Maximum Packet Size", 49);
    }
    return allowed;
}
int mqtt_sdk_queue_allowed(void *context, size_t count, size_t bytes, size_t added) {
    if (!context)
        return 1;
    client *c = context;
    if (count < c->extra.max_messages && added <= c->extra.max_bytes &&
        bytes <= c->extra.max_bytes - added)
        return 1;
    pthread_mutex_lock(&mutex);
    c->terminal = 1;
    mqtt_error_complete(&c->connect_error, MQTT_E_LIMIT, MQTT_OP_PUBLISH,
                        "Paho receive queue exhausted");
    pthread_mutex_unlock(&mutex);
    return 0;
}
static size_t packet_size(size_t remaining) {
    size_t n = remaining + 1;
    do {
        n++;
        remaining /= 128;
    } while (remaining);
    return n;
}
static int validate_operation(client *c, int op, const char *topic, int qos, int retained,
                              const MQTTProperties *props, unsigned length, int executing) {
    if (c->terminal && op != MQTT_OP_CLOSE)
        return MQTT_E_STATE;
    if (!executing && c->disconnecting && op != MQTT_OP_CLOSE)
        return MQTT_E_STATE;
    if (op != MQTT_OP_CONNECT && op != MQTT_OP_CLOSE && !c->online)
        return MQTT_E_STATE;
    if (topic && !UTF8_validateString(topic))
        return MQTT_E_INVALID;
    if (c->protocol != 5 && props->count)
        return MQTT_E_INVALID;
    size_t size = 0;
    if (op == MQTT_OP_PUBLISH) {
        if (strpbrk(topic, "+#"))
            return MQTT_E_INVALID;
        if ((unsigned)qos > c->server_qos || (retained && !c->server_retain))
            return MQTT_E_STATE;
        size = 2 + strlen(topic) + (qos ? 2 : 0) + length +
               (c->protocol == 5 ? MQTTProperties_len(props) : 0);
    } else if (op == MQTT_OP_SUBSCRIBE_MANY) {
        if (!c->server_wildcard && strpbrk(topic, "+#"))
            return MQTT_E_STATE;
        if (!c->server_shared && !strncmp(topic, "$share/", 7))
            return MQTT_E_STATE;
        if (!c->server_subid && MQTTProperties_hasProperty(props, 11))
            return MQTT_E_STATE;
        size = length + 2 + (c->protocol == 5 ? MQTTProperties_len(props) : 0);
    } else if (op == MQTT_OP_UNSUBSCRIBE_MANY)
        size = length + 2 + (c->protocol == 5 ? MQTTProperties_len(props) : 0);
    else if (op == MQTT_OP_DISCONNECT) {
        if (!c->session_expiry && numeric(props, 17, 0))
            return MQTT_E_INVALID;
        size = 1 + MQTTProperties_len(props);
    }
    return size && packet_size(size) > c->server_packet ? MQTT_E_LIMIT : 0;
}
static int validate_command(command *cmd) {
    client *c = cmd->owner;
    int rc = 0;
    unsigned wire_bytes = 0;
    pthread_mutex_lock(&mutex);
    if (cmd->topic_count) {
        for (unsigned i = 0; i < cmd->topic_count; i++)
            wire_bytes +=
                (unsigned)strlen(cmd->topics[i]) + 2 + (cmd->op == MQTT_OP_SUBSCRIBE_MANY);
        for (unsigned i = 0; !rc && i < cmd->topic_count; i++)
            rc = validate_operation(c, cmd->op, cmd->topics[i], 0, 0, &cmd->properties, wire_bytes,
                                    1);
    } else
        rc = validate_operation(c, cmd->op, cmd->topic, cmd->qos, cmd->retained, &cmd->properties,
                                cmd->length, 1);
    pthread_mutex_unlock(&mutex);
    return rc;
}
int mqtt_sdk_retry_allowed(void *context) {
    if (!context)
        return 1;
    client *c = context;
    pthread_mutex_lock(&mutex);
    int allowed = !c->terminal;
    pthread_mutex_unlock(&mutex);
    return allowed;
}
static void result_props(command *cmd, int packet, int reason, const MQTTProperties *p) {
    mqtt_event_details_v2 *d = &cmd->result->details;
    d->packet_type = packet;
    d->reason_code = reason;
    properties_free(&d->properties);
    int rc = properties_out(&d->properties, p);
    if (rc)
        cmd->metadata_error = rc;
}
static void success5(void *context, MQTTAsync_successData5 *data) {
    command *cmd = context;
    client *c = cmd->owner;
    pthread_mutex_lock(&mutex);
    int value = 0;
    if (cmd->op == MQTT_OP_SUBSCRIBE_MANY || cmd->op == MQTT_OP_UNSUBSCRIBE_MANY) {
        int sub = cmd->op == MQTT_OP_SUBSCRIBE_MANY;
        int count = sub ? data->alt.sub.reasonCodeCount : data->alt.unsub.reasonCodeCount;
        enum MQTTReasonCodes *codes =
            count > 1 ? (sub ? data->alt.sub.reasonCodes : data->alt.unsub.reasonCodes) : NULL;
        if (count != (int)cmd->topic_count || (count > 1 && !codes))
            cmd->metadata_error = MQTT_E_INVALID;
        else {
            for (int i = 0; i < count; i++)
                ((uint8_t *)cmd->result->event.payload)[i] =
                    (uint8_t)(count == 1 ? data->reasonCode : codes[i]);
            value = count;
        }
        result_props(cmd, sub ? 9 : 11, data->reasonCode, &data->properties);
    } else if (cmd->op == MQTT_OP_PUBLISH) {
        result_props(cmd, cmd->qos == 0 ? 0 : (cmd->qos == 1 ? 4 : 7), data->reasonCode,
                     &data->properties);
    } else if (cmd->op == MQTT_OP_DISCONNECT) {
        c->connect_active = c->online = 0;
        c->disconnected_at_ms = clock_ms(CLOCK_REALTIME);
        c->recovery_start_mono = clock_ms(CLOCK_MONOTONIC);
        c->retry_attempt = 0;
        c->server_disconnected = 0;
        connection_event(c, MQTT_EVENT_LOST, 0, 1);
    }
    finish(cmd, cmd->metadata_error, value);
    pthread_mutex_unlock(&mutex);
}
static void failure5(void *context, MQTTAsync_failureData5 *data) {
    command *cmd = context;
    pthread_mutex_lock(&mutex);
    int reason = data ? data->reasonCode : 0;
    result_props(cmd, cmd->op == MQTT_OP_SUBSCRIBE_MANY ? 9 : (data ? data->packet_type : 0),
                 reason, data ? &data->properties : NULL);
    if (cmd->op == MQTT_OP_SUBSCRIBE_MANY && cmd->topic_count == 1 && reason >= 128) {
        ((uint8_t *)cmd->result->event.payload)[0] = (uint8_t)reason;
        finish(cmd, cmd->metadata_error, 1);
    } else
        finish(
            cmd,
            cmd->metadata_error
                ? cmd->metadata_error
                : (reason >= 128 ? reason : (data && data->code ? data->code : MQTTASYNC_FAILURE)),
            0);
    pthread_mutex_unlock(&mutex);
}
static int32_t create2(const mqtt_config_v2 *config, uint64_t *out) {
    if (!config)
        return MQTT_E_INVALID;
    return create_internal(&config->base, config, out);
}
static int32_t publish2(uint64_t id, uint64_t request, const char *topic, const uint8_t *payload,
                        uint32_t length, uint32_t qos, uint32_t retained,
                        const mqtt_properties *properties) {
    MQTTProperties p = MQTTProperties_initializer;
    int rc = properties_in(properties, &p, 3);
    if (!rc && numeric(&p, 1, 0) == 1 &&
        (length > INT_MAX ||
         (length && (!payload || !UTF8_validate((int)length, (const char *)payload)))))
        rc = MQTT_E_INVALID;
    if (!rc)
        rc = submit_internal(id, request, MQTT_OP_PUBLISH, topic, payload, length, (int)qos,
                             (int)retained, &p, 0, 0);
    MQTTProperties_free(&p);
    return rc;
}
static int32_t subscribe2(uint64_t id, uint64_t request, uint32_t count,
                          const mqtt_subscription_v2 *subs, const mqtt_properties *properties) {
    if (!count || count > MQTT_MAX_SUBSCRIPTIONS || !subs)
        return MQTT_E_INVALID;
    const char *topics[MQTT_MAX_SUBSCRIPTIONS];
    int32_t qos[MQTT_MAX_SUBSCRIPTIONS];
    for (uint32_t i = 0; i < count; i++) {
        if (!subs[i].filter || subs[i].qos > 2 || subs[i].no_local > 1 ||
            subs[i].retain_as_published > 1 || subs[i].retain_handling > 2 ||
            (subs[i].no_local && !strncmp(subs[i].filter, "$share/", 7)))
            return MQTT_E_INVALID;
        topics[i] = subs[i].filter;
        qos[i] = (int32_t)subs[i].qos;
    }
    MQTTProperties p = MQTTProperties_initializer;
    int rc = properties_in(properties, &p, 8);
    if (!rc)
        rc = filters_internal(id, request, count, topics, qos, MQTT_OP_SUBSCRIBE_MANY, &p, subs);
    MQTTProperties_free(&p);
    return rc;
}
static int32_t unsubscribe2(uint64_t id, uint64_t request, uint32_t count,
                            const char *const *topics, const mqtt_properties *properties) {
    MQTTProperties p = MQTTProperties_initializer;
    int rc = properties_in(properties, &p, 10);
    if (!rc)
        rc = filters_internal(id, request, count, topics, NULL, MQTT_OP_UNSUBSCRIBE_MANY, &p, NULL);
    MQTTProperties_free(&p);
    return rc;
}
static int32_t disconnect2(uint64_t id, uint64_t request, uint32_t drain,
                           const mqtt_properties *properties, int reason, const char *text) {
    if (drain > INT_MAX)
        return MQTT_E_INVALID;
    if (!text || !*text)
        text = "Implementation specific error";
    if (strnlen(text, 65536) > 65535 || !UTF8_validateString(text))
        return MQTT_E_INVALID;
    MQTTProperties p = MQTTProperties_initializer;
    int rc = properties_in(properties, &p, 14);
    pthread_mutex_lock(&mutex);
    client *c = find_client(id);
    int version = c ? c->protocol : 0;
    pthread_mutex_unlock(&mutex);
    if (version == 4 && (reason || p.count))
        rc = MQTT_E_INVALID;
    if (!rc && version == 5)
        rc = add_reason(&p, text);
    if (!rc)
        rc = submit_internal(id, request, MQTT_OP_DISCONNECT, NULL, NULL, 0, 0, 0, &p, reason,
                             (int)drain);
    MQTTProperties_free(&p);
    return rc;
}
static int32_t disconnect_normal(uint64_t c, uint64_t r, uint32_t t, const mqtt_properties *p) {
    return disconnect2(c, r, t, p, 0, "Normal disconnection");
}
static int32_t disconnect_will(uint64_t c, uint64_t r, uint32_t t, const mqtt_properties *p) {
    return disconnect2(c, r, t, p, 4, "Disconnect with Will Message");
}
static int32_t disconnect_unspecified(uint64_t c, uint64_t r, uint32_t t,
                                      const mqtt_properties *p) {
    return disconnect2(c, r, t, p, 128, "Unspecified error");
}
static int32_t disconnect_implementation(uint64_t c, uint64_t r, const char *s, uint32_t t,
                                         const mqtt_properties *p) {
    return disconnect2(c, r, t, p, 131, s);
}
static const mqtt_event_details_v2 *event_details(const mqtt_event *event) {
    return &((const event_node *)event)->details;
}
