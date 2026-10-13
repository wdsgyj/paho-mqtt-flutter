import 'connection_probe.dart';
import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS static bootstrap, QoS 0/1/2 and background isolate FFI', (
    tester,
  ) async {
    const broker = String.fromEnvironment('MQTT_TEST_BROKER');
    expect(broker, isNotEmpty);
    const bootstrap = MethodChannel('org.paho.mqtt/native_api');
    final dartTable = await bootstrap.invokeMapMethod<String, Object>(
      'getNativeApi',
      {'abiVersion': 2},
    );
    expect(dartTable!['abiVersion'], 2);
    expect(dartTable['pointerBits'], 64);
    expect(
      int.parse(dartTable['addressHex']! as String, radix: 16),
      greaterThan(0),
    );
    await expectLater(
      bootstrap.invokeMethod<Object>('getNativeApi', {'abiVersion': 1}),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      bootstrap.invokeMethod<Object>('getNativeApi', {'abiVersion': 99}),
      throwsA(isA<PlatformException>()),
    );
    final quick = await MqttClient.create(
      const MqttOptions(
        serverUri: 'tcp://start-listener.invalid:1883',
        clientId: 'dart-ios-race',
      ),
    );
    final closed = Completer<void>();
    final callbackError = StateError("business callback failed");
    await quick.startConnecting(
      MqttEventListener(
        onEvent: (event) async {
          if (event is MqttConnectFailed) throw callbackError;
          if (event is MqttErrorEvent) {
            expect(event.error, same(callbackError));
            expect(event.terminal, false);
            await quick.close();
            closed.complete();
          }
        },
      ),
    );
    await closed.future.timeout(const Duration(seconds: 10));
    final client = await MqttClient.create(
      const MqttOptions(serverUri: broker, clientId: 'dart-ios-check'),
    );
    final messages = <MqttMessage>[];
    final connected = Completer<MqttConnected>();
    final disconnected = Completer<MqttDisconnected>();
    final received = StreamController<MqttMessage>.broadcast();
    final subscription = client.events.listen((event) {
      if (event is MqttConnected) connected.complete(event);
      if (event is MqttDisconnected) disconnected.complete(event);
      if (event is MqttMessage) {
        messages.add(event);
        received.add(event);
      }
    });
    try {
      expect(await client.connectAndWaitForTest(), false);
      expect(
        (await connected.future.timeout(
          const Duration(seconds: 15),
        ))
            .sessionPresent,
        false,
      );
      final results = await client.subscribeMany(const [
        MqttSubscription('ios/dart/out', qos: MqttQos.exactlyOnce),
        MqttSubscription('ios/dart/extra', qos: MqttQos.atLeastOnce),
      ]);
      expect(results.entries.map((e) => e.grantedQos?.index), [2, 1]);
      for (var qos = 0; qos <= 2; qos++) {
        final reply = received.stream.first.timeout(
          const Duration(seconds: 15),
        );
        final payload = Uint8List.fromList([0, 255, qos, 0, 42]);
        await [client.publishQos0, client.publishQos1, client.publishQos2][qos](
          'ios/dart/out',
          payload,
        );
        expect((await reply).payload, payload);
      }
      final token = RootIsolateToken.instance!;
      final reply = received.stream.first.timeout(const Duration(seconds: 15));
      await publishFromWorker(token, broker);
      expect((await reply).payload, [99]);
      await client.unsubscribeMany(['ios/dart/out', 'ios/dart/extra']);
      await client.disconnect();
      expect(
        (await disconnected.future.timeout(
          const Duration(seconds: 15),
        ))
            .intentional,
        true,
      );
      expect(messages.length, 4);
    } catch (error, stack) {
      print("iOS integration error: $error\n$stack");
      rethrow;
    } finally {
      await client.close();
      await subscription.cancel();
      await received.close();
    }
  });
}

// Keep the isolate closure separate from the test's client/stream context.
Future<void> publishFromWorker(RootIsolateToken token, String broker) =>
    Isolate.run(() async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      final worker = await MqttClient.create(
        MqttOptions(serverUri: broker, clientId: 'dart-ios-worker'),
      );
      try {
        await worker.connectAndWaitForTest();
        await worker.publishQos2('ios/dart/out', Uint8List.fromList([99]));
      } finally {
        await worker.close();
      }
    });
