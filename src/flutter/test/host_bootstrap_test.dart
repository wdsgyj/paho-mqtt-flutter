import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart' as v3;
import 'package:paho_mqtt_ffi/mqtt5.dart' as v5;

import 'support/native_bootstrap.dart';

void main() {
  test('host setup reports missing libraries before client creation', () async {
    final directory = await Directory.systemTemp.createTemp('mqtt-host-test-');
    try {
      expect(
        () =>
            setUpMqttHostTests(libraryPath: '${directory.path}/missing.dylib'),
        throwsArgumentError,
      );
    } finally {
      await directory.delete();
    }
  });

  test('one host setup enables both protocols through the real native library',
      () async {
    final host = setUpMqttHostTests();
    final v3Client = await v3.MqttClient.create(const v3.MqttOptions(
      serverUri: 'tcp://127.0.0.1:1',
      clientId: 'host-311',
    ));
    try {
      final v5Client = await v5.MqttClient.create(const v5.MqttOptions(
        serverUri: 'tcp://127.0.0.1:1',
        clientId: 'host-5',
      ));
      try {
        expect(v3Client.pahoVersion, matches(r'^\d+\.\d+\.\d+'));
        expect(v5Client.pahoVersion, v3Client.pahoVersion);
        expect(host.calls, 1);
      } finally {
        await v5Client.close();
      }
    } finally {
      await v3Client.close();
    }
    expect(host.calls, 1);
  });
}
