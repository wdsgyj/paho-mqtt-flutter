/* Private implementation included by mqtt_api.c, sharing its lock and objects.
 */
#include "MQTTProperties.h"
#include "mqtt_api_v2.h"
#include "mqtt_v5_hooks.h"
#include "utf-8.h"

static int prop_kind(unsigned id) {
    switch (id) {
    case 1:
    case 23:
    case 25:
    case 36:
    case 37:
    case 40:
    case 41:
    case 42:
        return 1;
    case 19:
    case 33:
    case 34:
    case 35:
        return 2;
    case 2:
    case 17:
    case 24:
    case 39:
        return 4;
    case 11:
        return 3;
    case 9:
    case 22:
        return 5;
    case 38:
        return 7;
    case 3:
    case 8:
    case 18:
    case 21:
    case 26:
    case 28:
    case 31:
        return 6;
    default:
        return 0;
    }
}
static int utf8_bytes(const uint8_t *p, uint32_t n) {
    return n <= 65535 && (!n || (p && !memchr(p, 0, n) && UTF8_validate(n, (const char *)p)));
}
static int prop_allowed(unsigned id, int packet) {
    if (id == 38)
        return 1;
    switch (packet) {
    case 1:
        return id == 17 || id == 23 || id == 25 || id == 33 || id == 39;
    case 3:
        return id == 1 || id == 2 || id == 3 || id == 8 || id == 9;
    case 8:
        return id == 11;
    case 10:
        return 0;
    case 14:
        return id == 17;
    case 99:
        return id == 24 || id == 1 || id == 2 || id == 3 || id == 8 || id == 9;
    default:
        return 0;
    }
}
static int properties_in(const mqtt_properties *input, MQTTProperties *out, int packet) {
    *out = (MQTTProperties)MQTTProperties_initializer;
    if (!input)
        return 0;
    if (input->count > 4096 || (input->count && !input->items))
        return MQTT_E_INVALID;
    uint64_t seen = 0;
    size_t total = 0;
    for (uint32_t i = 0; i < input->count; i++) {
        const mqtt_property *p = &input->items[i];
        int kind = prop_kind(p->id);
        if (!kind || !prop_allowed(p->id, packet) || (p->id != 38 && (seen & (1ull << p->id))))
            goto invalid;
        seen |= 1ull << p->id;
        if ((kind == 1 && p->number > 1) || (kind == 2 && (p->number == 0 || p->number > 65535)) ||
            (kind == 3 && (!p->number || p->number > 268435455)) || (p->id == 39 && !p->number))
            goto invalid;
        if ((kind >= 5 && p->length > 65535) || (p->length && !p->data) ||
            (kind >= 6 && !utf8_bytes(p->data, p->length)) ||
            (kind == 7 && !utf8_bytes(p->value, p->value_length)))
            goto invalid;
        if (p->id == 8 &&
            (!p->length || memchr(p->data, '+', p->length) || memchr(p->data, '#', p->length)))
            goto invalid;
        total += p->length + p->value_length + 16;
        if (total > MAX_BYTES)
            goto invalid;
        MQTTProperty v = {0};
        v.identifier = p->id;
        if (kind == 1)
            v.value.byte = (unsigned char)p->number;
        else if (kind == 2)
            v.value.integer2 = (unsigned short)p->number;
        else if (kind <= 4)
            v.value.integer4 = p->number;
        else {
            v.value.data.len = (int)p->length;
            v.value.data.data = (char *)p->data;
            if (kind == 7) {
                v.value.value.len = (int)p->value_length;
                v.value.value.data = (char *)p->value;
            }
        }
        if (MQTTProperties_add(out, &v)) {
            MQTTProperties_free(out);
            return MQTT_E_MEMORY;
        }
    }
    return 0;
invalid:
    MQTTProperties_free(out);
    return MQTT_E_INVALID;
}
static void properties_free(mqtt_properties *p) {
    for (uint32_t i = 0; i < p->count; i++) {
        free((void *)p->items[i].data);
        free((void *)p->items[i].value);
    }
    free((void *)p->items);
    memset(p, 0, sizeof(*p));
}
static int properties_out(mqtt_properties *out, const MQTTProperties *in) {
    memset(out, 0, sizeof(*out));
    if (!in || !in->count)
        return 0;
    mqtt_property *items = calloc((size_t)in->count, sizeof(*items));
    if (!items)
        return MQTT_E_MEMORY;
    out->items = items;
    out->count = (uint32_t)in->count;
    for (int i = 0; i < in->count; i++) {
        const MQTTProperty *p = &in->array[i];
        mqtt_property *v = &items[i];
        v->id = p->identifier;
        int kind = prop_kind(v->id);
        if (kind == 1)
            v->number = p->value.byte;
        else if (kind == 2)
            v->number = p->value.integer2;
        else if (kind <= 4)
            v->number = p->value.integer4;
        else {
            v->length = (uint32_t)p->value.data.len;
            uint8_t *data = malloc(v->length + 1);
            if (!data)
                goto fail;
            if (v->length)
                memcpy(data, p->value.data.data, v->length);
            data[v->length] = 0;
            v->data = data;
            if (kind == 7) {
                v->value_length = (uint32_t)p->value.value.len;
                data = malloc(v->value_length + 1);
                if (!data)
                    goto fail;
                if (v->value_length)
                    memcpy(data, p->value.value.data, v->value_length);
                data[v->value_length] = 0;
                v->value = data;
            }
        }
    }
    return 0;
fail:
    properties_free(out);
    return MQTT_E_MEMORY;
}
static int add_number(MQTTProperties *p, unsigned id, unsigned value) {
    MQTTProperty v = {0};
    v.identifier = id;
    v.value.integer4 = value;
    return MQTTProperties_add(p, &v) ? MQTT_E_MEMORY : 0;
}
static int add_reason(MQTTProperties *p, const char *reason) {
    MQTTProperty v = {0};
    v.identifier = 31;
    v.value.data.len = (int)strlen(reason);
    v.value.data.data = (char *)reason;
    return MQTTProperties_add(p, &v) ? MQTT_E_MEMORY : 0;
}
static unsigned numeric(const MQTTProperties *p, int id, unsigned fallback) {
    MQTTProperty *v = MQTTProperties_getProperty((MQTTProperties *)p, id);
    if (!v)
        return fallback;
    switch (prop_kind(id)) {
    case 1:
        return v->value.byte;
    case 2:
        return v->value.integer2;
    default:
        return v->value.integer4;
    }
}
