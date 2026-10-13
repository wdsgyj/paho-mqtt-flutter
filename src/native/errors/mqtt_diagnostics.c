#include "mqtt_diagnostics.h"
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#ifdef MQTT_SDK_TLS
#include <openssl/x509_vfy.h>
#endif
static _Thread_local mqtt_error *current;
void mqtt_diag_enter(mqtt_error *record) { current = record; }
void mqtt_diag_leave(void) { current = NULL; }
void mqtt_diag_stage(int stage) { if (current) current->stage = stage; }
void mqtt_diag_text(const char *text, unsigned long length) {
    if (!current || !text) return;
    size_t used = strlen(current->details), available = sizeof(current->details)-used-1;
    if (length > available) { length = available; current->flags |= MQTT_ERROR_TRUNCATED; }
    memcpy(current->details+used, text, length);
    current->details[used+length] = 0;
    /* Truncation must not leave an incomplete UTF-8 character. */
    if (current->flags & MQTT_ERROR_TRUNCATED) {
        size_t n = used+length, start = n;
        while (start && ((unsigned char)current->details[start-1] & 0xc0) == 0x80) --start;
        if (start) { unsigned char c = (unsigned char)current->details[start-1];
            unsigned expected = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc0 ? 2 : 1;
            if (n-(start-1) < expected) current->details[start-1] = 0;
        }
    }
}
void mqtt_diag_system(int code) {
    if (!current || !code || code == EINPROGRESS || code == EWOULDBLOCK || code == EAGAIN || code == EINTR) return;
    current->system_code = code; current->flags |= MQTT_ERROR_SYSTEM;
    current->category = MQTT_ERR_NETWORK;
    current->reason = code == ECONNREFUSED ? MQTT_REASON_CONNECTION_REFUSED :
        code == ETIMEDOUT ? MQTT_REASON_TIMEOUT :
        code == ENETUNREACH || code == EHOSTUNREACH ? MQTT_REASON_UNREACHABLE :
        code == ECONNRESET || code == EPIPE ? MQTT_REASON_CONNECTION_RESET : MQTT_REASON_UNKNOWN;
    snprintf(current->message, sizeof(current->message), "%s", strerror(code));
}
void mqtt_diag_dns(int code, int system_code) {
    if (!current || !code) return;
    current->category=MQTT_ERR_DNS; current->reason=MQTT_REASON_DNS_FAILURE;
    current->stage=MQTT_STAGE_DNS; current->dns_code=code; current->flags |= MQTT_ERROR_DNS;
    if (code == EAI_SYSTEM) { current->system_code=system_code; current->flags |= MQTT_ERROR_SYSTEM; }
    snprintf(current->message,sizeof(current->message),"DNS resolution failed: %s",gai_strerror(code));
}
void mqtt_diag_tls(int ssl_code, long verify_code, int system_code, const char *message) {
    if (!current) return;
    if (system_code) mqtt_diag_system(system_code);
    current->category=MQTT_ERR_TLS;
    if (!current->reason || current->reason < MQTT_REASON_TLS_CONFIG)
        current->reason=current->stage == MQTT_STAGE_TLS_CONFIG ? MQTT_REASON_TLS_CONFIG : MQTT_REASON_TLS_HANDSHAKE;
    if (ssl_code >= 0) { current->tls_code=ssl_code; current->flags |= MQTT_ERROR_TLS; }
    if (verify_code >= 0) { current->verify_code=(int)verify_code; current->flags |= MQTT_ERROR_VERIFY; }
#ifdef MQTT_SDK_TLS
    if (verify_code > 0 && !(current->flags & MQTT_ERROR_PLATFORM)) {
        switch (verify_code) {
        case X509_V_ERR_CERT_HAS_EXPIRED:
            current->reason=MQTT_REASON_CERTIFICATE_EXPIRED; break;
        case X509_V_ERR_CERT_NOT_YET_VALID:
            current->reason=MQTT_REASON_CERTIFICATE_NOT_YET_VALID; break;
        case X509_V_ERR_HOSTNAME_MISMATCH: case X509_V_ERR_IP_ADDRESS_MISMATCH:
            current->reason=MQTT_REASON_HOSTNAME_MISMATCH; break;
        case X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT: case X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN:
        case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT: case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY:
        case X509_V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE:
            current->reason=MQTT_REASON_CERTIFICATE_UNTRUSTED; break;
        default: current->reason=MQTT_REASON_CERTIFICATE_REJECTED;
        }
        snprintf(current->message,sizeof(current->message),"TLS certificate validation failed: %s",X509_verify_cert_error_string(verify_code));
    }
#endif
    if (!current->message[0]) snprintf(current->message,sizeof(current->message),"%s: %s",
        current->stage == MQTT_STAGE_TLS_CONFIG ? "TLS configuration failed" : "TLS handshake failed", message ? message : "unknown TLS error");
}
void mqtt_diag_platform(int code, const char *domain, const char *message, int reason) {
    if (!current) return;
    current->category=MQTT_ERR_TLS; current->reason=reason;
    current->platform_code=code; current->flags |= MQTT_ERROR_PLATFORM;
    snprintf(current->platform_domain,sizeof(current->platform_domain),"%s",domain ? domain : "");
    snprintf(current->message,sizeof(current->message),"%s",message ? message : "System trust validation failed");
    if (message) mqtt_diag_text(message, strlen(message));
}
void mqtt_error_complete(mqtt_error *e, int code, int operation, const char *message) {
    e->code=code; e->operation=operation;
    struct timespec t; clock_gettime(CLOCK_REALTIME,&t);
    e->timestamp_ms=(uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000;
    if (!e->category) {
        const char *description = "MQTT operation failed";
        switch (code) {
        case -1000: case -5: case -6: case -8: case -9: case -14: case -15: case -16:
            e->category=MQTT_ERR_ARGUMENT; e->reason=MQTT_REASON_INVALID_ARGUMENT; description="Invalid MQTT argument"; break;
        case -1001: e->category=MQTT_ERR_STATE; e->reason=MQTT_REASON_CLOSED; description="MQTT client is closing or closed"; break;
        case -1005: e->category=MQTT_ERR_STATE; e->reason=MQTT_REASON_INVALID_STATE; description="Invalid MQTT state or incompatible native library"; break;
        case -1002: case -4: case -10: case -12:
            e->category=MQTT_ERR_RESOURCE; e->reason=MQTT_REASON_LIMIT; description="MQTT capacity limit reached"; break;
        case -1003: case -99: e->category=MQTT_ERR_RESOURCE; e->reason=MQTT_REASON_NO_MEMORY; description="MQTT memory allocation failed"; break;
        case -1004: e->category=MQTT_ERR_CANCELLED; e->reason=MQTT_REASON_CANCELLED; description="MQTT operation cancelled"; break;
        case -11: e->category=MQTT_ERR_CANCELLED; e->reason=MQTT_REASON_OPERATION_INCOMPLETE; description="MQTT operation interrupted before completion"; break;
        case -3: e->category=MQTT_ERR_STATE; e->reason=MQTT_REASON_NOT_CONNECTED; description="MQTT client is not connected"; break;
        default:
            if ((operation == 1 && code >= 1 && code <= 5) || code == 128) {
                static const char *reasons[]={"", "Unsupported MQTT protocol", "Client identifier rejected", "Broker unavailable", "Bad username or password", "Not authorized"};
                e->category=MQTT_ERR_BROKER; e->reason=MQTT_REASON_BROKER_REJECTED;
                description=code == 128 ? "Subscription rejected" : reasons[code];
            }
        }
        if (!e->message[0]) snprintf(e->message,sizeof(e->message),"%s",e->category == MQTT_ERR_UNKNOWN && message && *message ? message : description);
    }
    if (!e->stage) e->stage=(e->category == MQTT_ERR_ARGUMENT || e->category == MQTT_ERR_STATE)
        ? MQTT_STAGE_ADMISSION : MQTT_STAGE_OPERATION;
    if (message && *message) {
        size_t n=strlen(e->details);
        int written = snprintf(e->details+n,sizeof(e->details)-n,"%s%s",n ? "\n" : "",message);
        if (written >= (int)(sizeof(e->details)-n)) e->flags |= MQTT_ERROR_TRUNCATED;
    }
}
void mqtt_error_describe(int32_t code, int32_t operation, mqtt_error *out) {
    if (!out) return;
    memset(out,0,sizeof(*out)); out->stage=code == 128 ? MQTT_STAGE_OPERATION : MQTT_STAGE_ADMISSION;
    mqtt_error_complete(out,code,operation,NULL);
}
