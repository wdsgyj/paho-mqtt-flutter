import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('org.paho.mqtt/native_api');
final _libraries = <String, DynamicLibrary>{};
MqttNativeApiMock? _activeMock;

/// Enables the real MQTT 3.1.1 and MQTT 5 clients in host Flutter tests.
///
/// Call once in a test, setUp, or setUpAll, before creating any clients:
/// `setUpAll(() => setUpMqttHostTests());`
/// Loads [libraryPath], then MQTT_TEST_LIBRARY, falling back to the repository's
/// dist/test/macos-arm64/release/libmqtt_sdk.dylib, and installs the platform
/// bootstrap channel. Missing libraries/ABI 2 tables fail immediately;
/// the SDK validates the full ABI and initializes FFI on the first client create.
/// All client operations then use the real native library, including callbacks.
/// Network operations still require a broker and appropriate TLS configuration.
///
/// The channel mock is removed automatically at the end of the test scope.
/// Close clients before that scope ends. The library stays loaded because the
/// SDK caches its function pointers for the isolate's lifetime. Installing this
/// helper again does not reset that cache or switch the initialized SDK's library.
/// Use separate test files/isolates for incompatible bootstrap scenarios.
///
/// [beforeBootstrap] optionally delays the platform reply for concurrency tests;
/// ordinary tests should omit it. The returned handle only tracks channel calls
/// and allows early cleanup; callers do not need to keep it.
MqttNativeApiMock setUpMqttHostTests({
  String? libraryPath,
  FutureOr<void> Function()? beforeBootstrap,
}) {
  final api = _loadMqttTestApi(libraryPath);
  return mockMqttNativeApi(reply: () async {
    if (beforeBootstrap != null) await beforeBootstrap();
    return _mqttTestApiReply(api);
  });
}

// The library owns the table; never free it. Only host tests use symbol lookup.
Pointer<Void> _loadMqttTestApi([String? libraryPath]) {
  final environmentPath = Platform.environment['MQTT_TEST_LIBRARY'];
  final path = libraryPath ??
      (environmentPath != null && environmentPath.isNotEmpty
          ? environmentPath
          : _defaultMqttTestLibrary());
  if (path.isEmpty) {
    throw ArgumentError.value(path, 'libraryPath', 'Must not be empty');
  }
  final resolvedPath = File(path).absolute.path;
  final library = _libraries.putIfAbsent(
      resolvedPath, () => DynamicLibrary.open(resolvedPath));
  final getApi = library.lookupFunction<Pointer<Void> Function(Uint32),
      Pointer<Void> Function(int)>('mqtt_get_api');
  final api = getApi(2);
  if (api == nullptr) {
    throw StateError('Host library does not provide MQTT ABI 2: $path');
  }
  return api;
}

// Flutter CLI and IDE runners may start from different directories in the repo.
// Locate the repository independently of whether its host artifact is built yet.
String _defaultMqttTestLibrary() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File.fromUri(directory.uri.resolve('src/flutter/pubspec.yaml'))
            .existsSync() &&
        File.fromUri(directory.uri.resolve('src/native/CMakeLists.txt'))
            .existsSync()) {
      final library = File.fromUri(directory.uri
          .resolve('dist/test/macos-arm64/release/libmqtt_sdk.dylib'));
      if (!library.existsSync()) {
        throw StateError('Host library not found: ${library.path}. '
            'Build with `go -C scripts run . native --platform host` '
            'from the repository root (see docs/build.md).');
      }
      return library.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Cannot locate the MQTT repository from '
          '${Directory.current.path}. Run tests inside the repository, '
          'or pass libraryPath or set MQTT_TEST_LIBRARY (see docs/build.md).');
    }
    directory = parent;
  }
}

/// Builds the platform bootstrap reply, including pointer width for this process.
/// The address is deliberately not validated, allowing null-pointer test cases.
Map<String, Object> _mqttTestApiReply(Pointer<Void> api) => {
      'addressHex': api.address.toRadixString(16),
      'abiVersion': 2,
      'pointerBits': sizeOf<IntPtr>() * 8,
    };

/// Low-level injection for tests that construct their own native function table.
/// Ordinary host tests should use [setUpMqttHostTests]; compatibility tests should
/// use [mockMqttBootstrapFailure]. Cleanup is automatic at the test scope's end.
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
  if ((api == null) == (reply == null)) {
    throw ArgumentError('Specify exactly one of api or reply.');
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  final response = reply ?? () => _mqttTestApiReply(api!);
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

/// Deliberately incompatible bootstrap scenarios. Each needs a fresh isolate
/// because the SDK caches both successful initialization and initialization errors.
enum MqttBootstrapFault {
  nullAddress,
  incompatibleReplyVersion,
  obsoleteCoreVersion,
  missingConnectionDetails,
  missingSessionPresent,
  missingSubscribeMany,
  missingUnsubscribeMany,
  missingPlatformTrust,
  missingInsecureTls,
  missingStartConnecting,
}

/// Installs a failing bootstrap, owning all copied table memory and its cleanup.
/// The real library table is never modified. Only the two invalid-reply cases
/// work without a host library; all other cases clone its tables before mutation.
MqttNativeApiMock mockMqttBootstrapFailure(MqttBootstrapFault fault) {
  if (fault == MqttBootstrapFault.nullAddress) {
    return mockMqttNativeApi(api: nullptr);
  }
  if (fault == MqttBootstrapFault.incompatibleReplyVersion) {
    // Address 1 must never be dereferenced: reject the reply version first.
    return mockMqttNativeApi(
        reply: () => {
              ..._mqttTestApiReply(Pointer<Void>.fromAddress(1)),
              'abiVersion': 1,
            });
  }
  final source = _loadMqttTestApi().cast<_ApiPrefix>();
  final table = _copyTable(source.cast());
  Pointer<Uint8>? core;
  try {
    core = _copyTable(source.ref.core);
    final header = core.cast<_ApiHeader>().ref;
    if (fault == MqttBootstrapFault.obsoleteCoreVersion) {
      header.abiVersion = 1;
    } else {
      // Capability values are defined in src/native/include/mqtt_api.h.
      final missingBit = switch (fault) {
        MqttBootstrapFault.missingConnectionDetails => 8,
        MqttBootstrapFault.missingSessionPresent => 16,
        MqttBootstrapFault.missingSubscribeMany => 32,
        MqttBootstrapFault.missingUnsubscribeMany => 64,
        MqttBootstrapFault.missingPlatformTrust => 128,
        MqttBootstrapFault.missingInsecureTls => 256,
        MqttBootstrapFault.missingStartConnecting => 1024,
        _ => throw StateError('Unexpected table fault: $fault'),
      };
      if (fault == MqttBootstrapFault.missingPlatformTrust ||
          fault == MqttBootstrapFault.missingInsecureTls) {
        header.capabilities |= 2; // TLS builds must advertise these policies.
      }
      header.capabilities &= ~missingBit;
    }
    table.cast<_ApiPrefix>().ref.core = core.cast();
    final mock = mockMqttNativeApi(api: table.cast());
    final ownedCore = core;
    addTearDown(() {
      mock.dispose();
      calloc.free(ownedCore);
      calloc.free(table);
    });
    return mock;
  } catch (_) {
    if (core != null) calloc.free(core);
    calloc.free(table);
    rethrow;
  }
}

// Only the common header and outer core pointer are needed to clone the tables.
// Keep these prefixes aligned with mqtt_api.h and mqtt_api_v2.h.
final class _ApiHeader extends Struct {
  @Uint32()
  external int abiVersion;
  @Uint32()
  external int structSize;
  @Uint64()
  external int capabilities;
}

final class _ApiPrefix extends Struct {
  external _ApiHeader header;
  external Pointer<Void> core;
}

Pointer<Uint8> _copyTable(Pointer<Void> source) {
  final size = source.cast<_ApiHeader>().ref.structSize;
  final copy = calloc<Uint8>(size);
  copy.asTypedList(size).setAll(0, source.cast<Uint8>().asTypedList(size));
  return copy;
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
