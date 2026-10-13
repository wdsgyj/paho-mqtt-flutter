#include "mqtt_tls.h"
#ifdef MQTT_SDK_DIAGNOSTICS
#include "mqtt_diagnostics.h"
#endif
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <openssl/err.h>
#include <openssl/pem.h>

#if defined(__APPLE__)
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#endif

int mqtt_tls_load_android_roots(X509_STORE *store, const char *const *directories) {
    DIR *directory = NULL;
    const char *path = NULL;
    for (size_t i = 0; directories[i]; ++i) {
        directory = opendir(directories[i]);
        if (directory) { path = directories[i]; break; }
    }
    if (!directory) return 0;
    int count = 0, failed = 0;
    struct dirent *entry;
    for (;;) {
        errno = 0;
        entry = readdir(directory);
        if (!entry) { if (errno) failed = 1; break; }
        if (entry->d_name[0] == '.') continue;
        size_t length = strlen(path) + strlen(entry->d_name) + 2;
        char *filename = malloc(length);
        if (!filename) { failed = 1; break; }
        snprintf(filename, length, "%s/%s", path, entry->d_name);
        FILE *file = fopen(filename, "r");
        free(filename);
        if (!file) continue;
        struct stat status;
        if (fstat(fileno(file), &status) != 0 || !S_ISREG(status.st_mode)) {
            fclose(file); continue;
        }
        /* Scan PEM contents, independent of Android's certificate hash names.
         * Never use environment paths, user CA directories, or default roots. */
        X509 *certificate;
        while ((certificate = PEM_read_X509(file, NULL, NULL, NULL)) != NULL) {
            if (X509_STORE_add_cert(store, certificate) == 1) ++count;
            else if (ERR_GET_REASON(ERR_peek_last_error()) == X509_R_CERT_ALREADY_IN_HASH_TABLE) ++count;
            else failed = 1;
            X509_free(certificate);
            if (failed) break;
            ERR_clear_error();
        }
        ERR_clear_error(); /* Non-certificate files/PEM end are not trust anchors. */
        if (ferror(file)) failed = 1;
        fclose(file);
        if (failed) break;
    }
    closedir(directory);
    return !failed && count > 0;
}

#if defined(__APPLE__)
static int append_certificate(CFMutableArrayRef certificates, X509 *certificate) {
    unsigned char *der = NULL;
    int length = i2d_X509(certificate, &der);
    if (length <= 0) return 0;
    CFDataRef bytes = CFDataCreate(kCFAllocatorDefault, der, length);
    OPENSSL_free(der);
    if (!bytes) return 0;
    SecCertificateRef item = SecCertificateCreateWithData(kCFAllocatorDefault, bytes);
    CFRelease(bytes);
    if (!item) return 0;
    CFArrayAppendValue(certificates, item);
    CFRelease(item);
    return 1;
}

static int verify_apple_chain(X509_STORE_CTX *store, void *unused) {
    (void)unused;
    int accepted = 0;
    CFMutableArrayRef certificates = NULL;
    CFStringRef name = NULL;
    SecPolicyRef policy = NULL;
    SecTrustRef trust = NULL;
    CFErrorRef error = NULL;
    SSL *ssl = X509_STORE_CTX_get_ex_data(store, SSL_get_ex_data_X509_STORE_CTX_idx());
    /* Paho sets SNI from the connection URI before SSL_connect, including for
     * literal IP addresses. The peer cannot choose this verification identity. */
    const char *hostname = ssl ? SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name) : NULL;
    X509 *leaf = X509_STORE_CTX_get0_cert(store);
    if (!hostname || !*hostname || !leaf) goto done;
    certificates = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!certificates || !append_certificate(certificates, leaf)) goto done;
    STACK_OF(X509) *chain = X509_STORE_CTX_get0_untrusted(store);
    for (int i = 0; i < sk_X509_num(chain); ++i) {
        X509 *item = sk_X509_value(chain, i);
        if (X509_cmp(item, leaf) != 0 && !append_certificate(certificates, item)) goto done;
    }
    name = CFStringCreateWithCString(kCFAllocatorDefault, hostname, kCFStringEncodingUTF8);
    if (!name) goto done;
    policy = SecPolicyCreateSSL(true, name); /* Server auth purpose AND hostname. */
    if (!policy || SecTrustCreateWithCertificates(certificates, policy, &trust) != errSecSuccess) goto done;
    /* No auxiliary AIA/OCSP network calls while Paho's handshake thread waits.
     * The broker must send its intermediate chain. System trust is still used. */
    if (SecTrustSetNetworkFetchAllowed(trust, false) != errSecSuccess) goto done;
    accepted = SecTrustEvaluateWithError(trust, &error) ? 1 : 0;
done:
#ifdef MQTT_SDK_DIAGNOSTICS
    if (error) {
        char domain[64] = "", description[1024] = "System trust rejected the certificate";
        CFStringRef text = CFErrorCopyDescription(error);
        CFStringGetCString(CFErrorGetDomain(error), domain, sizeof(domain), kCFStringEncodingUTF8);
        if (text) { CFStringGetCString(text, description, sizeof(description), kCFStringEncodingUTF8); CFRelease(text); }
        int code = (int)CFErrorGetCode(error);
        int reason = MQTT_REASON_CERTIFICATE_REJECTED;
        if (CFEqual(CFErrorGetDomain(error), kCFErrorDomainOSStatus)) {
            if (code == errSecCertificateExpired) reason = MQTT_REASON_CERTIFICATE_EXPIRED;
            else if (code == errSecCertificateNotValidYet) reason = MQTT_REASON_CERTIFICATE_NOT_YET_VALID;
            else if (code == errSecHostNameMismatch) reason = MQTT_REASON_HOSTNAME_MISMATCH;
            else if (code == errSecNotTrusted || code == errSecCreateChainFailed || code == errSSLUnknownRootCert) reason = MQTT_REASON_CERTIFICATE_UNTRUSTED;
        }
        mqtt_diag_platform(code, domain, description, reason);
    }
#endif
    if (error) CFRelease(error);
    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);
    if (name) CFRelease(name);
    if (certificates) CFRelease(certificates);
    /* SSL_VERIFY_PEER makes failure fatal; record the result for Paho and TLS
     * session state as well. Never override failure with an unconditional OK. */
    X509_STORE_CTX_set_error(store, accepted ? X509_V_OK : X509_V_ERR_CERT_REJECTED);
    return accepted;
}
#endif

int mqtt_tls_configure_trust(SSL_CTX *ctx, const char *ca_file, const char *ca_path, int insecure_skip_verify) {
    /* A new, empty store makes custom CA mode exclusive, even on reused ctx. */
    X509_STORE *store = X509_STORE_new();
    if (!store) return 0;
    SSL_CTX_set_cert_store(ctx, store); /* context owns the store */
    SSL_CTX_set_cert_verify_callback(ctx, NULL, NULL);
    SSL_CTX_set_verify(ctx, insecure_skip_verify ? SSL_VERIFY_NONE : SSL_VERIFY_PEER, NULL);
    /* Explicit per-client debug mode: no platform callback, CA loading or peer
     * checks. Paho also disables its post-handshake hostname verification. */
    if (insecure_skip_verify) return 1;
    if (ca_file || ca_path) {
        /* Empty strings/bad paths fail; they never select system fallback. */
        if ((ca_file && !*ca_file) || (ca_path && !*ca_path)) return 0;
        return SSL_CTX_load_verify_locations(ctx, ca_file, ca_path);
    }
#if defined(__ANDROID__)
    static const char *const directories[] = {
        "/apex/com.android.conscrypt/cacerts",
        "/system/etc/security/cacerts", NULL
    };
    return mqtt_tls_load_android_roots(store, directories);
#elif defined(__APPLE__)
    SSL_CTX_set_cert_verify_callback(ctx, verify_apple_chain, NULL);
    return 1;
#else
    /* Host checks only; product platforms are Android/iOS. */
    return SSL_CTX_set_default_verify_paths(ctx);
#endif
}
