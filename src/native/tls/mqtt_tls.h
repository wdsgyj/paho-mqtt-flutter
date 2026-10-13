#ifndef MQTT_SDK_TLS_H
#define MQTT_SDK_TLS_H
#include <openssl/ssl.h>
/* Called by the opt-in Paho build hook, before SSL_new. No language callbacks. */
int mqtt_tls_configure_trust(SSL_CTX *ctx, const char *ca_file, const char *ca_path, int insecure_skip_verify);
/* Internal helper also exercised by host tests; not exported in the mobile ABI.
 * The first readable directory is authoritative, even if empty/corrupt. */
int mqtt_tls_load_android_roots(X509_STORE *store, const char *const *directories);
#endif
