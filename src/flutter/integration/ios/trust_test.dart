import 'connection_probe.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS system trust and exclusive custom CA via real FFI', (
    tester,
  ) async {
    final config = jsonDecode(const String.fromEnvironment('MQTT_TRUST_JSON'))
        as Map<String, dynamic>;
    final dir = await Directory.systemTemp.createTemp('mqtt-trust-');
    try {
      final caA = (await File(
        '${dir.path}/a.pem',
      ).writeAsString(config['pemA'] as String))
          .path;
      final caB = (await File(
        '${dir.path}/b.pem',
      ).writeAsString(config['pemB'] as String))
          .path;
      final bad = (await File(
        '${dir.path}/bad.pem',
      ).writeAsString('not a CA'))
          .path;
      final empty = (await File(
        '${dir.path}/empty.pem',
      ).writeAsString(''))
          .path;
      final a = config['uriA'] as String, b = config['uriB'] as String;
      final cases = <(String, String?, bool)>[
        (a, null, true),
        (b, null, false),
        (a, caA, true),
        (b, caB, true),
        (a, caB, false),
        (b, caA, false),
        (a, bad, false),
        (a, empty, false),
        (a, '$caA.missing', false),
        (a, '', false),
        (a.replaceFirst('localhost', '127.0.0.1'), null, false),
        (a.replaceFirst('localhost', '127.0.0.1'), caA, false),
        (config['uriExpired'] as String, null, false),
        (config['uriExpired'] as String, caA, false),
        (config['uriWrongPurpose'] as String, null, false),
        (config['uriWrongPurpose'] as String, caA, false),
      ];
      for (var i = 0; i < cases.length; ++i) {
        final (uri, ca, expected) = cases[i];
        await probe(uri, ca, expected, 'case-$i');
      }
      await Future.wait([
        probe(a, null, true, 'parallel-system'),
        probe(b, caB, true, 'parallel-custom'),
      ]);
      final debugCases = <(String, String?)>[
        (b, null),
        (a.replaceFirst('localhost', '127.0.0.1'), null),
        (config['uriExpired'] as String, null),
        (config['uriWrongPurpose'] as String, null),
        (a, bad),
        (a, empty),
        (a, '$caA.missing'),
        (a, caB),
      ];
      for (var i = 0; i < debugCases.length; ++i) {
        final (uri, ca) = debugCases[i];
        await probe(uri, ca, true, 'debug-$i', insecure: true);
      }
      await probe(b, null, false, 'strict-after-debug');
      await probe(a, caB, false, 'custom-after-debug');
    } finally {
      await dir.delete(recursive: true);
    }
  });
}

Future<void> probe(
  String uri,
  String? ca,
  bool expected,
  String label, {
  bool insecure = false,
}) async {
  final client = await MqttClient.create(
    MqttOptions(
      serverUri: uri,
      clientId: 'dart-trust-$label',
      tls: MqttTlsOptions(trustStore: ca, insecureSkipVerify: insecure),
      connectTimeoutSeconds: 5,
    ),
  );
  var accepted = false;
  try {
    try {
      await client.connectAndWaitForTest();
      await client.disconnect();
      await client.connectAndWaitForTest();
      accepted = true;
    } on MqttException catch (error) {
      expect(
        error.info,
        anyOf(isA<MqttCertificateError>(), isA<MqttTlsConfigurationError>()),
        reason: label,
      );
      expect(error.info.message, isNotEmpty);
      if (ca == null)
        expect(
          (error.info as MqttCertificateError).diagnostics.platform,
          isNotNull,
        );
      if (['case-10', 'case-11'].contains(label)) {
        expect(
          (error.info as MqttCertificateError).reason,
          MqttCertificateReason.hostnameMismatch,
        );
      }
      if (['case-12', 'case-13'].contains(label)) {
        expect(
          (error.info as MqttCertificateError).reason,
          MqttCertificateReason.expired,
        );
      }
      if (['case-6', 'case-7', 'case-8', 'case-9'].contains(label)) {
        expect(error.info, isA<MqttTlsConfigurationError>());
      }
    }
    expect(accepted, expected, reason: label);
  } finally {
    await client.close();
  }
}
