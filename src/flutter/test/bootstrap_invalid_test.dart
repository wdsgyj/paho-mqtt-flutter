import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

import 'support/native_bootstrap.dart';

// Separate test file/isolate gives production's one-time initializer a fresh scope.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('invalid bootstrap is cached for concurrent and later create calls',
      () async {
    final bootstrap = mockMqttNativeApi(
        reply: () => {
              ...mqttTestApiReply(Pointer<Void>.fromAddress(1)),
              'abiVersion': 1,
            });
    const options =
        MqttOptions(serverUri: 'tcp://127.0.0.1:1', clientId: 'invalid');
    await Future.wait(List.generate(
        8, (_) => expectLater(MqttClient.create(options), throwsStateError)));
    await expectLater(MqttClient.create(options), throwsStateError);
    expect(bootstrap.calls, 1);
  });
}
