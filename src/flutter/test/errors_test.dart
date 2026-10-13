import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

import 'support/native_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = Platform.environment['MQTT_ERROR_FIXTURE'];
  test('structured failures and initial automatic retries', () async {
    final f = Map<String, String>.from(jsonDecode(source!) as Map);
    mockMqttNativeApi();
    Future<void> failure(String uri, Matcher expected,
        {String? ca, bool auto = false}) async {
      final client = await MqttClient.create(MqttOptions(
          serverUri: uri,
          clientId: 'dart-errors',
          tls: MqttTlsOptions(trustStore: ca),
          automaticReconnect: auto,
          connectTimeoutSeconds: 4,
          minRetrySeconds: 1,
          maxRetrySeconds: 1));
      final failures = <MqttConnectFailed>[];
      final first = Completer<MqttErrorInfo>();
      final enough = Completer<void>();
      final listener = MqttEventListener(onEvent: (e) {
        if (e is MqttConnectFailed) {
          failures.add(e);
          if (!first.isCompleted)
            first.complete((e.error as MqttException).info);
          if (failures.length >= (auto ? 2 : 1) && !enough.isCompleted)
            enough.complete();
        }
        if (e is MqttErrorEvent) fail('Listener failed: ${e.error}');
      });
      try {
        await client
            .startConnecting(listener); // Network failure must not reject this.
        final info = await first.future.timeout(const Duration(seconds: 15));
        final replacement = MqttEventListener(onEvent: (_) {});
        await expectLater(
            client.startConnecting(replacement), throwsStateError);
        if (auto) {
          await expectLater(
              client.startConnecting(listener), throwsA(isA<MqttException>()));
        }
        expect(info, expected);
        expect(info.operationType, MqttOperation.connect);
        expect(info.attempt!.id, 1);
        expect(info.message, isNotEmpty);
        expect(info.attempt!.willRetry, auto);
        await enough.future.timeout(const Duration(seconds: 15));
        expect(failures.length, greaterThanOrEqualTo(auto ? 2 : 1));
        expect((failures.first.error as MqttException).info.attempt!.id,
            info.attempt!.id);
        expect((failures.first.error as MqttException).info.timestampMs,
            info.timestampMs);
        expect(
            (failures.first.error as MqttException).info.details, info.details);
        if (auto)
          expect((failures[1].error as MqttException).info.attempt!.id,
              greaterThan(info.attempt!.id));
      } finally {
        await client.close();
      }
    }

    await failure(
        f['refused']!,
        isA<MqttNetworkError>()
            .having(
                (e) => e.reason, 'reason', MqttNetworkReason.connectionRefused)
            .having((e) => e.systemCode, 'errno', isNotNull),
        auto: true);
    await failure(f['dns']!,
        isA<MqttDnsError>().having((e) => e.dnsCode, 'DNS code', isNotNull),
        auto: true);
    await failure(
        f['mismatch']!,
        isA<MqttCertificateError>()
            .having((e) => e.reason, 'reason',
                MqttCertificateReason.hostnameMismatch)
            .having((e) => e.diagnostics.verifyCode, 'X509 code', isNotNull),
        ca: f['ca']);
    await failure(f['tls']!, isA<MqttTlsConfigurationError>(),
        ca: '${f['ca']}.missing');
    await failure(f['badTls']!, isA<MqttTlsHandshakeError>());
    await failure(f['reject']!,
        isA<MqttBrokerError>().having((e) => e.code, 'CONNACK', 5));
    await failure(
        f['stall']!,
        isA<MqttNetworkError>()
            .having((e) => e.reason, 'reason', MqttNetworkReason.timeout));
  },
      skip: source == null
          ? 'Run go -C scripts run . test --suite errors'
          : false,
      timeout: const Timeout(Duration(seconds: 100)));
}
