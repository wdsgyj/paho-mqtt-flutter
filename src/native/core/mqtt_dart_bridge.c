#include "mqtt_dart_bridge.h"
#include "dart_api_dl.h"
#include "mqtt_api_v2.h"
#include <pthread.h>
#include <stdlib.h>
static pthread_mutex_t init_mutex = PTHREAD_MUTEX_INITIALIZER;
static int initialized;
int32_t mqtt_dart_initialize(void *data) {
    if (!data)
        return MQTT_E_INVALID;
    pthread_mutex_lock(&init_mutex);
    if (!initialized && Dart_InitializeApiDL(data) == 0 && Dart_PostCObject_DL)
        initialized = 1;
    int rc = initialized ? 0 : MQTT_E_STATE;
    pthread_mutex_unlock(&init_mutex);
    return rc;
}
static int32_t notify_port(void *context, uint64_t client) {
    Dart_CObject message;
    message.type = Dart_CObject_kInt64;
    message.value.as_int64 = (int64_t)client;
    return Dart_PostCObject_DL((int64_t)(intptr_t)context, &message) ? 1 : 0;
}
int32_t mqtt_dart_set_port(uint64_t client, int64_t port) {
    pthread_mutex_lock(&init_mutex);
    int ready = initialized;
    pthread_mutex_unlock(&init_mutex);
    if (!ready || port <= 0)
        return MQTT_E_INVALID;
    /* The positive port ID fits intptr_t on our ARM64 targets. No allocated
     * callback state and no Dart-owned pointers survive isolate termination. */
    return mqtt_get_api(2)->core->set_notifier(client, notify_port, (void *)(intptr_t)port, NULL);
}
