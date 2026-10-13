import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt5.dart' as mqtt;

import 'support/native_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final uri = Platform.environment['MQTT_TEST_BROKER'];
  setUpAll(() {
    if (uri != null) setUpMqttHostTests();
  });
  test('MQTT5 real broker session, retained expiry, binary properties and Will',
      () async {
    final prefix = 'v5-${DateTime.now().microsecondsSinceEpoch}';
    final tls =
        mqtt.MqttTlsOptions(trustStore: Platform.environment['MQTT_TEST_CA']);
    final subscriber = await mqtt.MqttClient.create(mqtt.MqttOptions(
        serverUri: uri!,
        clientId: '$prefix-sub',
        tls: tls,
        session: const mqtt.MqttSessionOptions(
            cleanStart: mqtt.MqttCleanStartPolicy.firstConnection,
            expiryIntervalSeconds: 30)));
    final publisher = await mqtt.MqttClient.create(mqtt.MqttOptions(
        serverUri: uri,
        clientId: '$prefix-pub',
        tls: tls,
        will: mqtt.MqttWillOptions(
            topic: '$prefix/will',
            payload: Uint8List.fromList([0, 255]),
            qos: mqtt.MqttQos.atLeastOnce)));
    final events = StreamController<mqtt.MqttEvent>();
    final it = StreamIterator(events.stream);
    final listener = mqtt.MqttEventListener(onEvent: events.add);
    Future<T> next<T>() async {
      while (await it.moveNext().timeout(const Duration(seconds: 10))) {
        if (it.current is T) return it.current as T;
      }
      throw StateError('missing $T');
    }

    final pubReady = Completer<void>();
    try {
      await subscriber.startConnecting(listener);
      expect((await next<mqtt.MqttConnected>()).sessionPresent, false);
      await publisher.startConnecting(mqtt.MqttEventListener(onEvent: (e) {
        if (e is mqtt.MqttConnected) pubReady.complete();
      }));
      await pubReady.future.timeout(const Duration(seconds: 10));
      (await subscriber.subscribe(
              mqtt.MqttSubscription('$prefix/#', qos: mqtt.MqttQos.exactlyOnce),
              properties: const mqtt.MqttSubscribeProperties(
                  subscriptionIdentifier: 42)))
          .requireAllAccepted();
      for (final qos in mqtt.MqttQos.values) {
        await [
          publisher.publishQos0,
          publisher.publishQos1,
          publisher.publishQos2
        ][qos.index]('$prefix/live', Uint8List.fromList([qos.index, 0, 255]),
            properties: mqtt.MqttPublishProperties(
                responseTopic: '$prefix/reply',
                correlationData: Uint8List.fromList([0, 255]),
                messageExpiryIntervalSeconds: 10,
                userProperties: const [
                  mqtt.MqttUserProperty('a', '1'),
                  mqtt.MqttUserProperty('a', '2')
                ]));
        final m = await next<mqtt.MqttMessage>();
        expect(m.payload, [qos.index, 0, 255]);
        expect(m.properties.correlationData, [0, 255]);
        expect(m.properties.subscriptionIdentifiers, [42]);
        expect(m.properties.userProperties.length, 2);
      }
      await subscriber.disconnect();
      await next<mqtt.MqttDisconnected>();
      await publisher.publishQos1('$prefix/offline', Uint8List.fromList([7]));
      await subscriber.startConnecting(listener);
      expect((await next<mqtt.MqttReconnected>()).sessionPresent, true);
      expect((await next<mqtt.MqttMessage>()).topic, '$prefix/offline');
      await publisher.publishQos1('$prefix/retained', Uint8List.fromList([8]),
          retained: true,
          properties: const mqtt.MqttPublishProperties(
              messageExpiryIntervalSeconds: 1));
      await next<mqtt.MqttMessage>();
      await subscriber.unsubscribe('$prefix/#');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      (await subscriber.subscribe(mqtt.MqttSubscription('$prefix/#')))
          .requireAllAccepted();
      await publisher.publishQos1('$prefix/barrier', Uint8List.fromList([9]));
      expect((await next<mqtt.MqttMessage>()).topic, '$prefix/barrier');
      await publisher.disconnectWithWillMessage();
      final will = await next<mqtt.MqttMessage>();
      expect(will.topic, '$prefix/will');
      expect(will.payload, [0, 255]);
    } finally {
      await publisher.close();
      await subscriber.close();
      await it.cancel();
      await events.close();
    }
  }, skip: uri == null ? 'Set MQTT_TEST_BROKER to run integration' : false);
}
