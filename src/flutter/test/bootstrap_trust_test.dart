import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

import 'support/native_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reject native table without platform trust policy before use',
      () async {
    final sourceV2 = loadMqttTestApi();
    final source = (sourceV2.cast<Uint8>() + 16).cast<Pointer<Void>>().value;
    final sizeV2 = sourceV2.cast<Uint32>()[1];
    final tableV2 = calloc<Uint8>(sizeV2);
    tableV2
        .asTypedList(sizeV2)
        .setAll(0, sourceV2.cast<Uint8>().asTypedList(sizeV2));
    final size = source.cast<Uint32>()[1];
    final legacy = calloc<Uint8>(size);
    // A stale TLS build must not silently keep the old default-trust behavior.
    legacy.asTypedList(size).setAll(0, source.cast<Uint8>().asTypedList(size));
    legacy.cast<Uint64>()[1] = (legacy.cast<Uint64>()[1] | 2) & ~128;
    (tableV2 + 16).cast<Pointer<Void>>().value = legacy.cast();
    final bootstrap = mockMqttNativeApi(api: tableV2.cast());
    try {
      const options =
          MqttOptions(serverUri: 'tcp://127.0.0.1:1', clientId: 'legacy');
      await expectLater(MqttClient.create(options), throwsStateError);
      await expectLater(MqttClient.create(options), throwsStateError);
      expect(bootstrap.calls, 1);
    } finally {
      bootstrap.dispose();
      calloc.free(legacy);
      calloc.free(tableV2);
    }
  });
}
