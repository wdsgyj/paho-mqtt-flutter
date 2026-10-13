import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

import 'support/native_bootstrap.dart';

void main() {
  test('reject removed shared core ABI before calling function pointers',
      () async {
    final bootstrap =
        mockMqttBootstrapFailure(MqttBootstrapFault.obsoleteCoreVersion);
    const options =
        MqttOptions(serverUri: 'tcp://127.0.0.1:1', clientId: 'legacy');
    await expectLater(MqttClient.create(options), throwsStateError);
    await expectLater(MqttClient.create(options), throwsStateError);
    expect(bootstrap.calls, 1);
  });
}
