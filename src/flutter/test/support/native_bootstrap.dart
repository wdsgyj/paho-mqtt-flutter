import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('org.paho.mqtt/native_api');
DynamicLibrary? _library;
MqttNativeApiMock? _activeMock;

/// Loads the host ABI 2 table from MQTT_TEST_LIBRARY. The library owns the table;
/// callers must not free it. Only host tests use symbol lookup, never product code.
Pointer<Void> loadMqttTestApi() {
  final path = Platform.environment['MQTT_TEST_LIBRARY'];
  if (path == null || path.isEmpty) {
    throw StateError('Build the host library and set MQTT_TEST_LIBRARY to its '
        'absolute path (see docs/build.md).');
  }
  final library = _library ??= DynamicLibrary.open(path);
  final getApi = library.lookupFunction<Pointer<Void> Function(Uint32),
      Pointer<Void> Function(int)>('mqtt_get_api');
  final api = getApi(2);
  if (api == nullptr) {
    throw StateError('MQTT_TEST_LIBRARY does not provide MQTT ABI 2: $path');
  }
  return api;
}

/// Builds the platform bootstrap reply, including pointer width for this process.
/// The address is deliberately not validated, allowing null-pointer test cases.
Map<String, Object> mqttTestApiReply(Pointer<Void> api) => {
      'addressHex': api.address.toRadixString(16),
      'abiVersion': 2,
      'pointerBits': sizeOf<IntPtr>() * 8,
    };

/// Installs the host bootstrap in a test, setUp or setUpAll, with automatic
/// cleanup at that scope's end. Ordinary tests need only mockMqttNativeApi().
///
/// Supply [api] for a synthetic table, or [reply] for an invalid/delayed response;
/// neither option loads the host library. The caller owns synthetic table memory
/// and must keep it alive until all clients are closed, then dispose this mock
/// before freeing it. This does not reset the SDK's cached initializer: bootstrap
/// failure scenarios still need separate test files/isolates.
MqttNativeApiMock mockMqttNativeApi({
  Pointer<Void>? api,
  FutureOr<Object?> Function()? reply,
}) {
  if (api != null && reply != null) {
    throw ArgumentError('Specify either api or reply, not both.');
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  final response = reply ?? () => mqttTestApiReply(api ?? loadMqttTestApi());
  final mock = MqttNativeApiMock._();
  _activeMock = mock;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    mock._calls++;
    expect(call.method, 'getNativeApi');
    expect(call.arguments, {'abiVersion': 2});
    return await response();
  });
  addTearDown(mock.dispose);
  return mock;
}

/// Counts bootstrap requests and supports early, idempotent cleanup for FFI tests.
final class MqttNativeApiMock {
  MqttNativeApiMock._();

  int _calls = 0;
  int get calls => _calls;

  void dispose() {
    // An older scope must not accidentally remove a subsequently installed mock.
    if (!identical(_activeMock, this)) return;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    _activeMock = null;
  }
}
