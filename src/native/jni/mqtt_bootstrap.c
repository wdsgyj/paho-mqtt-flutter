#include <jni.h>
#include <stdint.h>
#include "mqtt_api_v2.h"

static jlong api_address(JNIEnv *env, jobject receiver, jint version) {
    (void)env;
    (void)receiver;
    return (jlong)(intptr_t)mqtt_get_api((uint32_t)version);
}
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK)
        return JNI_ERR;
    jclass plugin = (*env)->FindClass(env, "org/paho/mqtt/ffi/PahoMqttFfiPlugin");
    if (!plugin)
        return JNI_ERR;
    const JNINativeMethod methods[] = {{"nativeApiAddress", "(I)J", (void *)api_address}};
    jint rc = (*env)->RegisterNatives(env, plugin, methods, 1);
    (*env)->DeleteLocalRef(env, plugin);
    return rc == JNI_OK ? JNI_VERSION_1_6 : JNI_ERR;
}
