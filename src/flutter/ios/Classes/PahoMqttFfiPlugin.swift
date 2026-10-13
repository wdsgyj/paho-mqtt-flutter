import Flutter
import CMqttSdk

public final class PahoMqttFfiPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "org.paho.mqtt/native_api", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(PahoMqttFfiPlugin(), channel: channel)
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "getNativeApi" else { result(FlutterMethodNotImplemented); return }
        guard let arguments = call.arguments as? [String: Any],
              let version = arguments["abiVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 2 else {
            result(FlutterError(code: "ABI_MISMATCH", message: "Unsupported MQTT C ABI", details: nil))
            return
        }
        guard let api = mqtt_get_api(version.uint32Value) else {
            result(FlutterError(code: "ABI_MISMATCH", message: "Unsupported MQTT C ABI", details: nil))
            return
        }
        result(["addressHex": String(UInt(bitPattern: api), radix: 16),
                "abiVersion": version.intValue,
                "pointerBits": MemoryLayout<UnsafeRawPointer>.size * 8])
    }
}
