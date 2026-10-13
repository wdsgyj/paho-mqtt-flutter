import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

import 'support/native_bootstrap.dart';

void main() {
  test('reject native table without event-only start support before use',
      () async {
    final bootstrap =
        mockMqttBootstrapFailure(MqttBootstrapFault.missingStartConnecting);
    const options =
        MqttOptions(serverUri: 'tcp://127.0.0.1:1', clientId: 'legacy');
    await expectLater(MqttClient.create(options), throwsStateError);
    await expectLater(MqttClient.create(options), throwsStateError);
    expect(bootstrap.calls, 1);
  });
}
