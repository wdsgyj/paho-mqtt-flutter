import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart' as v3;
import 'package:paho_mqtt_ffi/mqtt5.dart' as v5;

void main() {
  test(
      'nested configuration diagnostics retain useful fields and redact secrets',
      () {
    final credentials = v5.MqttCredentials.text(
        username: 'device-a', password: 'password-secret');
    const tls = v5.MqttTlsOptions(
        privateKey: '/keys/client.pem', privateKeyPassword: 'key-secret');
    final options = v5.MqttOptions(
      serverUri:
          'ssl://user:uri-secret@broker.example:8883?token=query-secret#fragment-secret',
      clientId: 'device-a',
      credentials: credentials,
      tls: tls,
      session: const v5.MqttSessionOptions(expiryIntervalSeconds: 60),
      will: v5.MqttWillOptions(
          topic: 'status', payload: Uint8List.fromList([0, 255])),
    );
    final text = options.toString();
    expect(text, contains('MqttOptions('));
    expect(text, contains('broker.example:8883'));
    expect(text, contains('device-a'));
    expect(text, contains('expiryIntervalSeconds: 60'));
    expect(text, contains('payload: <2 bytes>'));
    expect(text, contains('<redacted>'));
    expect(text, isNot(contains("Instance of")));
    for (final secret in [
      'password-secret',
      'key-secret',
      'uri-secret',
      'query-secret',
      'fragment-secret'
    ]) {
      expect(text, isNot(contains(secret)));
    }
    final old = v3.MqttOptions(
            serverUri: options.serverUri,
            clientId: 'device-a',
            credentials: credentials,
            tls: tls)
        .toString();
    expect(old, contains('cleanSession: true'));
    expect(old, isNot(contains('secret')));
    expect(
        const v5.MqttCredentials().toString(), contains('passwordBytes: null'));
    expect(v5.MqttCredentials(passwordBytes: Uint8List(0)).toString(),
        contains('<redacted>'));
  });

  test('binary data and large repeated properties produce bounded previews',
      () {
    final payload = Uint8List(1024 * 1024);
    final text = v5.MqttPublishProperties(
      correlationData: payload,
      userProperties:
          List.generate(100, (i) => v5.MqttUserProperty('same', 'value-$i')),
    ).toString();
    expect(text, contains('correlationData: <1048576 bytes>'));
    expect(text, contains('value-0'));
    expect(text, contains('value-1'));
    expect(text, contains('100 items'));
    expect(text.length, lessThan(1200));
    expect(payload.length, 1024 * 1024);
    final long = v5.MqttUserProperty('line\nkey', 'x' * 10000).toString();
    expect(long, contains(r'line\nkey'));
    expect(long, contains('10000 chars'));
    expect(long, isNot(contains('\n')));
    expect(long.length, lessThan(400));
    expect(const v5.MqttPublishProperties().toString(),
        contains('correlationData: null'));
    expect(v5.MqttPublishProperties(correlationData: Uint8List(0)).toString(),
        contains('<0 bytes>'));
  });
}
