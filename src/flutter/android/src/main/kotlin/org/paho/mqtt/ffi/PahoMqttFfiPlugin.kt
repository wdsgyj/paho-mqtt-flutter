package org.paho.mqtt.ffi

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** The channel only returns a C function-table address. No MQTT calls use it. */
class PahoMqttFfiPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private external fun nativeApiAddress(version: Int): Long

    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "org.paho.mqtt/native_api")
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getNativeApi") {
            result.notImplemented()
            return
        }
        val version = call.argument<Int>("abiVersion") ?: 0
        try {
            System.loadLibrary("mqtt_sdk")
            val address = nativeApiAddress(version)
            require(address != 0L) { "Unsupported MQTT C ABI: $version" }
            result.success(mapOf(
                "addressHex" to java.lang.Long.toHexString(address),
                "abiVersion" to version,
                "pointerBits" to 64
            ))
        } catch (error: IllegalArgumentException) {
            result.error("ABI_MISMATCH", error.message, null)
        } catch (error: LinkageError) {
            result.error("NATIVE_LOAD_FAILED", error.message, null)
        }
    }
}

