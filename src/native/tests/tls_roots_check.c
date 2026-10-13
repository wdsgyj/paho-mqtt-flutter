#include "mqtt_tls.h"
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <stdlib.h>
#include <stdio.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); abort(); } } while (0)

static X509 *read_cert(const char *path) {
    FILE *f = fopen(path, "r"); CHECK(f);
    X509 *c = PEM_read_X509(f, NULL, NULL, NULL); fclose(f); CHECK(c); return c;
}
static int verifies(SSL_CTX *ctx, X509 *leaf) {
    X509_STORE_CTX *v = X509_STORE_CTX_new(); CHECK(v);
    CHECK(X509_STORE_CTX_init(v, SSL_CTX_get_cert_store(ctx), leaf, NULL) == 1);
    CHECK(X509_STORE_CTX_set_purpose(v, X509_PURPOSE_SSL_SERVER) == 1);
    CHECK(X509_VERIFY_PARAM_set1_host(X509_STORE_CTX_get0_param(v), "localhost", 0) == 1);
    int result = X509_verify_cert(v); X509_STORE_CTX_free(v); return result == 1;
}
int main(int argc, char **argv) {
    CHECK(argc == 7); /* preferred-dir, legacy-dir, empty-dir, leafA, leafB, CA-B */
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method()); CHECK(ctx);
    X509 *a = read_cert(argv[4]), *b = read_cert(argv[5]);
    const char *dirs[] = {argv[1], argv[2], NULL};
    CHECK(mqtt_tls_load_android_roots(SSL_CTX_get_cert_store(ctx), dirs));
    CHECK(verifies(ctx, a)); CHECK(!verifies(ctx, b)); /* no merge with legacy */
    CHECK(mqtt_tls_configure_trust(ctx, argv[6], NULL, 0));
    CHECK(!verifies(ctx, a)); CHECK(verifies(ctx, b)); /* reset old roots */
    CHECK(!mqtt_tls_configure_trust(ctx, "", NULL, 0));
    CHECK(!verifies(ctx, a)); CHECK(!verifies(ctx, b));
    CHECK(!mqtt_tls_configure_trust(ctx, "/missing/ca.pem", NULL, 0));
    SSL_CTX_free(ctx); ctx = SSL_CTX_new(TLS_client_method()); CHECK(ctx);
    const char *fallback[] = {"/missing/system-ca-dir", argv[2], NULL};
    CHECK(mqtt_tls_load_android_roots(SSL_CTX_get_cert_store(ctx), fallback));
    CHECK(!verifies(ctx, a)); CHECK(verifies(ctx, b));
    SSL_CTX_free(ctx); ctx = SSL_CTX_new(TLS_client_method()); CHECK(ctx);
    const char *empty[] = {argv[3], argv[2], NULL};
    CHECK(!mqtt_tls_load_android_roots(SSL_CTX_get_cert_store(ctx), empty));
    CHECK(!verifies(ctx, b)); /* empty preferred store must not resurrect old CAs */
    CHECK(mqtt_tls_configure_trust(ctx, "/missing/ca.pem", NULL, 1));
    CHECK(SSL_CTX_get_verify_mode(ctx) == SSL_VERIFY_NONE);
    CHECK(mqtt_tls_configure_trust(ctx, argv[6], NULL, 0));
    CHECK(SSL_CTX_get_verify_mode(ctx) == SSL_VERIFY_PEER);
    CHECK(!verifies(ctx, a)); CHECK(verifies(ctx, b));
    SSL_CTX_free(ctx); X509_free(a); X509_free(b);
    puts("ANDROID_ROOT_LOADING_PASSED"); return 0;
}
