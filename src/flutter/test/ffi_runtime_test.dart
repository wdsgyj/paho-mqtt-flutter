import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

import 'connection_probe.dart';
import 'support/native_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('concurrent create initializes once and all MQTT operations use FFI',
      () async {
    final bootstrapEntered = Completer<void>();
    final allowBootstrap = Completer<void>();
    final bootstrap = setUpMqttHostTests(beforeBootstrap: () async {
      bootstrapEntered.complete();
      await allowBootstrap.future;
    });
    final creates = List.generate(
        8,
        (i) => MqttClient.create(MqttOptions(
            serverUri: 'tcp://127.0.0.1:1', clientId: 'lazy-init-$i')));
    await bootstrapEntered.future;
    expect(bootstrap.calls, 1);
    allowBootstrap.complete();
    final clients = await Future.wait(creates);
    try {
      expect(clients.first.pahoVersion, matches(r'^\d+\.\d+\.\d+'));
    } finally {
      await Future.wait(clients.map((client) => client.close()));
    }
    expect(bootstrap.calls, 1);
    // Rapid DNS failure: listener is already installed, and can await close.
    final quick = await MqttClient.create(const MqttOptions(
        serverUri: 'tcp://start-listener.invalid:1883',
        clientId: 'listener-race'));
    final closedInCallback = Completer<void>();
    var failures = 0;
    final callbackError = StateError("business callback failed");
    final listener = MqttEventListener(onEvent: (event) async {
      if (event is MqttConnectFailed) {
        failures++;
        throw callbackError;
      }
      if (event is MqttErrorEvent) {
        expect(event.error, same(callbackError));
        expect(event.terminal, false);
        expect(event.stackTrace.toString(), isNotEmpty);
        await quick.close();
        closedInCallback.complete();
      }
    });
    await quick.startConnecting(listener);
    await closedInCallback.future.timeout(const Duration(seconds: 10));
    expect(failures, 1);
    await expectLater(
        quick.startConnecting(listener), throwsA(isA<MqttException>()));

    await checkNoRecursiveErrors();
    final broker = Platform.environment['MQTT_TEST_BROKER'];
    if (broker != null) {
      await checkListenerOverflow(broker, Platform.environment['MQTT_TEST_CA']);
      final client = await MqttClient.create(MqttOptions(
          serverUri: broker,
          tls: MqttTlsOptions(trustStore: Platform.environment['MQTT_TEST_CA']),
          clientId: 'dart-${DateTime.now().microsecondsSinceEpoch}'));
      final messages = <MqttMessage>[];
      final arrived = Completer<void>();
      final burstArrived = Completer<void>();
      final batchArrived = Completer<void>();
      final unsubscribeBarrier = Completer<void>();
      final subscription = client.events.listen((event) {
        if (event is MqttMessage) {
          messages.add(event);
          if (event.topic == 'sdk/dart/测试' &&
              event.payload.length == 1 &&
              event.payload[0] == 200) {
            unsubscribeBarrier.complete();
          }
          if (messages.length == 102 && !batchArrived.isCompleted)
            batchArrived.complete();
          if (messages.length == 3 && !arrived.isCompleted) arrived.complete();
          if (messages.length == 99 && !burstArrived.isCompleted)
            burstArrived.complete();
        }
      });
      try {
        expect(await client.connectAndWaitForTest(), false);
        expect(
            (await client.subscribe(
                    MqttSubscription('sdk/dart/测试', qos: MqttQos.exactlyOnce)))
                .entries
                .single
                .grantedQos,
            MqttQos.exactlyOnce);
        for (var qos = 0; qos <= 2; qos++) {
          await [
            client.publishQos0,
            client.publishQos1,
            client.publishQos2
          ][qos]('sdk/dart/测试', Uint8List.fromList([0, 255, qos, 65]));
        }
        await arrived.future.timeout(const Duration(seconds: 10));
        expect(messages.map((m) => m.topic), everyElement('sdk/dart/测试'));
        expect(messages.map((m) => m.payload[2]).toSet(), {0, 1, 2});
        expect(messages.map((m) => m.payload[1]), everyElement(255));
        await Future.wait(List.generate(96,
            (i) => client.publishQos1('sdk/dart/测试', Uint8List.fromList([i]))));
        await burstArrived.future.timeout(const Duration(seconds: 10));
        expect(messages.length, 99);
        final batch = await client.subscribeMany(List.generate(
            3,
            (i) =>
                MqttSubscription('sdk/dart/batch/$i', qos: MqttQos.values[i])));
        expect(batch.entries.map((e) => e.grantedQos?.index), [0, 1, 2]);
        for (var i = 0; i < 3; i++) {
          await client.publishQos2(
              'sdk/dart/batch/$i', Uint8List.fromList([i]));
        }
        await batchArrived.future.timeout(const Duration(seconds: 10));
        expect(messages.skip(99).map((m) => m.qos.index), [0, 1, 2]);
        await client
            .unsubscribeMany(List.generate(3, (i) => 'sdk/dart/batch/$i'));
        for (var i = 0; i < 3; i++) {
          await client.publishQos1(
              'sdk/dart/batch/$i', Uint8List.fromList([99]));
        }
        // Same broker connection preserves the publish order. A surviving
        // subscription gives us a barrier after the unsubscribed publications.
        await client.publishQos1('sdk/dart/测试', Uint8List.fromList([200]));
        await unsubscribeBarrier.future.timeout(const Duration(seconds: 10));
        expect(messages.length, 103);
        await client.unsubscribe('sdk/dart/测试');
        await client.disconnect();
        await expectLater(
            client.unsubscribeMany(['offline']), throwsA(isA<MqttException>()));
        await expectLater(client.publishQos1('sdk/fail', Uint8List(0)),
            throwsA(isA<MqttException>()));
      } finally {
        await client.close();
        await client.close();
        await subscription.cancel();
      }
      await expectLater(
          client.connectAndWaitForTest(), throwsA(isA<MqttException>()));
      // A failed create must close/release its native handle as well.
      await expectLater(
          MqttClient.create(const MqttOptions(
              serverUri: 'invalid://bad', clientId: 'invalid')),
          throwsA(isA<MqttException>()));
      await Future.wait(List.generate(8, (i) async {
        final peer = await MqttClient.create(MqttOptions(
            serverUri: broker,
            tls: MqttTlsOptions(
                trustStore: Platform.environment['MQTT_TEST_CA']),
            clientId: 'notify-peer-$i'));
        try {
          await peer.connectAndWaitForTest();
        } finally {
          await peer.close();
        }
      }));
      expect(
          bootstrap.calls, 1); // All MQTT calls were FFI, never MethodChannel.
    }
  });
}

Future<void> checkListenerOverflow(String uri, String? ca) async {
  final client = await MqttClient.create(MqttOptions(
      serverUri: uri,
      clientId: 'dart-overflow',
      queueLimits: const MqttQueueLimits(maxReceivedMessages: 8),
      tls: MqttTlsOptions(trustStore: ca)));
  final entered = Completer<void>();
  final unblock = Completer<void>();
  final terminal = Completer<MqttErrorEvent>();
  final listener = MqttEventListener(onEvent: (event) async {
    if (event is MqttConnected) {
      entered.complete();
      await unblock.future;
    } else if (event is MqttErrorEvent) {
      await client.close();
      terminal.complete(event);
    }
  });
  try {
    await client.startConnecting(listener);
    await entered.future.timeout(const Duration(seconds: 10));
    await client.subscribe(MqttSubscription('sdk/listener/overflow'));
    for (var i = 0; i < 64; i++) {
      try {
        await client.publishQos1(
            'sdk/listener/overflow', Uint8List.fromList([1]));
      } on MqttException catch (e) {
        // Queue overflow closes ABI2 immediately, even with a blocked listener.
        expect(
            e.info,
            anyOf(
              isA<MqttStateError>()
                  .having((e) => e.reason, 'reason', MqttStateReason.closed),
              isA<MqttCancelledError>(),
            ));
        break;
      }
    }
    unblock.complete();
    final failure = await terminal.future.timeout(const Duration(seconds: 10));
    expect(failure.terminal, true);
    expect(failure.error, isA<StateError>());
  } finally {
    if (!unblock.isCompleted) unblock.complete();
    await client.close();
  }
}

Future<void> checkNoRecursiveErrors() async {
  final client = await MqttClient.create(const MqttOptions(
      serverUri: 'tcp://error-recursion.invalid:1883',
      clientId: 'error-recursion'));
  final original = StateError('business failure');
  final handlerFailure = StateError('error handler failure');
  final uncaught = Completer<Object>();
  var calls = 0;
  final listener = MqttEventListener(onEvent: (event) {
    calls++;
    if (event is MqttConnectFailed) throw original;
    if (event is MqttErrorEvent) {
      expect(event.error, same(original));
      throw handlerFailure;
    }
  });
  runZonedGuarded(() async {
    await client.startConnecting(listener);
  }, (error, stack) {
    uncaught.complete(error);
  });
  try {
    expect(await uncaught.future.timeout(const Duration(seconds: 10)),
        same(handlerFailure));
    expect(calls, 2);
    await expectLater(client.startConnecting(listener), throwsStateError);
  } finally {
    await client.close();
  }
}
