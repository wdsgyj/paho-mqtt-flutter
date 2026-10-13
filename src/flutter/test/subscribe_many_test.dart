import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

import 'connection_probe.dart';
import 'support/native_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('one packet subscriptions and per-topic SUBACK results', () async {
    setUpMqttHostTests();
    final client = await MqttClient.create(MqttOptions(
        serverUri: Platform.environment['MQTT_TEST_BROKER']!,
        clientId: 'dart-many'));
    try {
      await client.connectAndWaitForTest();
      final result = await client.subscribeMany(const [
        MqttSubscription('batch/中文', qos: MqttQos.atMostOnce),
        MqttSubscription('batch/deny'),
        MqttSubscription('batch/down', qos: MqttQos.exactlyOnce),
      ]);
      expect(result.entries.map((e) => e.topicFilter),
          ['batch/中文', 'batch/deny', 'batch/down']);
      expect(result.entries.map((e) => e.requestedQos.index), [0, 1, 2]);
      expect(result.entries.map((e) => e.rawReturnCode), [0, 128, 1]);
      expect(result.entries.map((e) => e.grantedQos?.index), [0, null, 1]);
      expect(result.entries.map((e) => e.accepted), [true, false, true]);
      expect(
          (await client.subscribeMany(const [MqttSubscription('batch/deny')]))
              .entries
              .single
              .rawReturnCode,
          128);
      final denied =
          await client.subscribe(const MqttSubscription('batch/deny'));
      expect(
          denied.requireAllAccepted,
          throwsA(isA<MqttProtocolException>()
              .having((e) => e.reasonCode, 'reasonCode', 128)));
      final duplicates = await client.subscribeMany(const [
        MqttSubscription('batch/dup', qos: MqttQos.atMostOnce),
        MqttSubscription('batch/dup', qos: MqttQos.exactlyOnce)
      ]);
      expect(duplicates.entries.map((e) => e.grantedQos?.index), [0, 2]);
      final largest = await client.subscribeMany(List.generate(
          256, (i) => MqttSubscription('max/$i', qos: MqttQos.values[i % 3])));
      expect(largest.entries.map((e) => e.grantedQos?.index),
          List.generate(256, (i) => i % 3));
      for (final invalid in <List<MqttSubscription>>[
        [],
        List.filled(257, const MqttSubscription('too-many')),
        [const MqttSubscription('ok'), const MqttSubscription('')],
        [const MqttSubscription('bad\u0000topic')],
      ]) {
        await expectLater(client.subscribeMany(invalid),
            throwsA(anyOf(isA<MqttException>(), isA<ArgumentError>())));
      }
      await expectLater(
          client.subscribeMany(
              const [MqttSubscription('ok'), MqttSubscription('bad/#/filter')]),
          throwsA(isA<MqttException>()));
      final results = await Future.wait([
        client.subscribeMany(const [MqttSubscription('async/a')]),
        client.subscribeMany(
            const [MqttSubscription('async/b', qos: MqttQos.exactlyOnce)]),
      ]);
      expect(results.map((r) => r.entries.single.grantedQos?.index), [1, 2]);
      await client.unsubscribeMany(
          ['batch/中文', 'devices/+/status', 'missing/#', 'batch/中文']);
      await client.unsubscribe('single/missing');
      await client.unsubscribeMany(List.generate(256, (i) => 'max/$i'));
      for (final invalid in <List<String>>[
        [],
        List.filled(257, 'too-many'),
        ['ok', ''],
        ['bad\u0000topic']
      ]) {
        await expectLater(client.unsubscribeMany(invalid),
            throwsA(anyOf(isA<MqttException>(), isA<ArgumentError>())));
      }
      await expectLater(client.unsubscribeMany(['ok', 'bad/#/filter']),
          throwsA(isA<MqttException>()));
      final order = <String>[];
      await Future.wait([
        client.unsubscribeMany(['unsub/async/a']).then((_) => order.add('a')),
        client.unsubscribeMany(['unsub/async/b']).then((_) => order.add('b')),
      ]);
      expect(order, ['b', 'a']); // Completion waits for the matching UNSUBACK.
      final pendingUnsubscribe = expectLater(
          client.unsubscribeMany(['unsub/pending']),
          throwsA(isA<MqttException>()));
      final pending = expectLater(
          client.subscribeMany(const [MqttSubscription('pending/close')]),
          throwsA(isA<MqttException>()));
      await client.close();
      await pending;
      await pendingUnsubscribe;
      await expectLater(
          client.unsubscribeMany(["closed"]), throwsA(isA<MqttException>()));
      await expectLater(
          client.subscribeMany(const [MqttSubscription('closed')]),
          throwsA(isA<MqttException>()));
    } finally {
      await client.close();
    }
  },
      skip: Platform.environment['MQTT_TEST_BATCH'] == null
          ? 'Run go -C scripts run . test --suite subscribe'
          : false);
}
