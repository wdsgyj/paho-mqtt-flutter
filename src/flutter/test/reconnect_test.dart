import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart';

import 'connection_probe.dart';
import 'support/native_bootstrap.dart';

bool? sessionFromEvent(MqttEvent event) => switch (event) {
      MqttConnected(:final sessionPresent) => sessionPresent,
      MqttReconnected(:final sessionPresent) => sessionPresent,
      MqttDisconnected() => null,
      MqttReconnecting() => null,
      MqttMessage() => null,
      MqttErrorEvent(:final error) => throw error,
      MqttConnectionFailure() => null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final control = Platform.environment['MQTT_TEST_CONTROL'];
  test('ordered connection transitions, counts, timestamps and recovery',
      () async {
    setUpMqttHostTests();
    Future<void> broker(String command) async {
      final socket = await Socket.connect('127.0.0.1', int.parse(control!));
      try {
        socket.write('$command\n');
        expect(
            await utf8.decoder
                .bind(socket)
                .transform(const LineSplitter())
                .first,
            'ok');
      } finally {
        socket.destroy();
      }
    }

    Future<MqttClient> create(String id) => MqttClient.create(MqttOptions(
        serverUri: Platform.environment['MQTT_TEST_BROKER']!,
        clientId: id,
        automaticReconnect: true,
        minRetrySeconds: 1,
        maxRetrySeconds: 1,
        connectTimeoutSeconds: 2));

    Future<void> exercise(MqttClient client,
        {required bool initialFailure}) async {
      // StreamIterator subscribes lazily; attach the broadcast listener now,
      // before connect(), and buffer events in a single-subscription stream.
      final queue = StreamController<MqttConnectionEvent>();
      final listener = client.events.listen((event) {
        if (event is MqttConnectionEvent) {
          if (event is MqttConnectionEstablished)
            expect(sessionFromEvent(event), event.sessionPresent);
          queue.add(event);
        }
      });
      final events = StreamIterator(queue.stream);
      var sequence = 0;
      var total = 0;
      Future<T> next<T extends MqttConnectionEvent>() async {
        expect(
            await events.moveNext().timeout(const Duration(seconds: 20)), true);
        final e = events.current;
        expect(e, isA<T>());
        expect(e.sequence, ++sequence);
        expect(e.droppedEvents, 0);
        expect(e.timestampMs, greaterThan(1700000000000));
        expect(e.totalRetryAttempts, greaterThanOrEqualTo(total));
        expect(e.downtimeMs, greaterThanOrEqualTo(0));
        if (e is MqttConnectionEstablished) expect(e.sessionPresent, false);
        total = e.totalRetryAttempts;
        return e as T;
      }

      Future<T> success<T extends MqttConnectionEstablished>() async {
        while (true) {
          // Retry notifications may already be queued when broker startup completes.
          expect(await events.moveNext().timeout(const Duration(seconds: 20)),
              true);
          final e = events.current;
          expect(e.sequence, ++sequence);
          expect(e.droppedEvents, 0);
          expect(e.totalRetryAttempts, greaterThanOrEqualTo(total));
          total = e.totalRetryAttempts;
          if (e is MqttReconnecting || e is MqttConnectionFailure) continue;
          if (e is! MqttConnectionEstablished)
            fail("Expected successful connection");
          expect(e, isA<T>());
          expect(e.automatic, true);
          expect(e.sessionPresent, false);
          expect(e.retryAttempt, greaterThan(0));
          expect(e.attemptStartedAtMs, lessThanOrEqualTo(e.timestampMs));
          return e as T;
        }
      }

      try {
        if (initialFailure) {
          await expectLater(
              client.connectAndWaitForTest(), throwsA(isA<MqttException>()));
          expect(
              ((await next<MqttConnectFailed>()).error as MqttException)
                  .info
                  .attempt!
                  .willRetry,
              true);
          final retry = await next<MqttReconnecting>();
          expect(retry.retryAttempt, 1);
          expect(retry.connectionCount, 0);
          expect(retry.disconnectedAtMs, isNull);
          await broker('start');
          final first = await success<MqttConnected>();
          expect(first.connectionCount, 1);
          expect(first.reconnectCount, 0);
          return;
        }
        await client.connectAndWaitForTest();
        final first = await next<MqttConnected>();
        expect(first.connectionCount, 1);
        expect(first.reconnectCount, 0);
        expect(first.retryAttempt, 0);
        expect(first.automatic, false);
        expect(first.disconnectedAtMs, isNull);
        expect(first.sessionPresent, false);
        await expectLater(
            client.connectAndWaitForTest(), throwsA(isA<MqttException>()));
        for (var cycle = 1; cycle <= 2; cycle++) {
          await broker('stop');
          final lost = await next<MqttDisconnected>();
          expect(lost.intentional, false);
          expect(lost.retryAttempt, 0);
          expect(lost.disconnectedAtMs, isNotNull);
          final retry = await next<MqttReconnecting>();
          expect(retry.retryAttempt, 1);
          expect(retry.automatic, true);
          expect(retry.totalRetryAttempts, lost.totalRetryAttempts + 1);
          if (cycle == 1) {
            final failed = await next<MqttReconnectFailed>();
            expect(
                (failed.error as MqttException).info.attempt!.willRetry, true);
            expect(failed.automatic, true);
            final again = await next<MqttReconnecting>();
            expect(again.retryAttempt, 2);
            expect(again.totalRetryAttempts, retry.totalRetryAttempts + 1);
          }
          await broker('start');
          final restored = await success<MqttReconnected>();
          expect(restored.connectionCount, cycle + 1);
          expect(restored.reconnectCount, cycle);
          expect(restored.disconnectedAtMs, lost.disconnectedAtMs);
          expect(restored.downtimeMs, greaterThanOrEqualTo(retry.downtimeMs));
        }
        await client.disconnect();
        final lost = await next<MqttDisconnected>();
        expect(lost.intentional, true);
        await client.connectAndWaitForTest();
        final retry = await next<MqttReconnecting>();
        expect(retry.retryAttempt, 1);
        expect(retry.automatic, false);
        final restored = await next<MqttReconnected>();
        expect(restored.reconnectCount, 3);
        expect(restored.connectionCount, 4);
        expect(restored.automatic, false);
        expect(restored.sessionPresent, false);
      } finally {
        await client.close();
        await events.cancel();
        await listener.cancel();
        await queue.close();
      }
    }

    Future<void> persistentSession() async {
      final client = await MqttClient.create(MqttOptions(
          serverUri: Platform.environment['MQTT_TEST_BROKER']!,
          clientId: 'dart-persistent',
          cleanSession: false,
          automaticReconnect: true,
          minRetrySeconds: 1,
          maxRetrySeconds: 1,
          connectTimeoutSeconds: 2));
      final queue = StreamController<MqttConnectionEvent>();
      final messages = StreamController<MqttMessage>();
      final listener = client.events.listen((e) {
        if (e is MqttConnectionEvent) queue.add(e);
        if (e is MqttMessage) messages.add(e);
      });
      final events = StreamIterator(queue.stream);
      final received = StreamIterator(messages.stream);
      Future<void> success<T extends MqttConnectionEstablished>(
          bool session, bool automatic) async {
        while (await events.moveNext().timeout(const Duration(seconds: 20))) {
          final e = events.current;
          if (e is! MqttConnectionEstablished) continue;
          final bool sessionPresent =
              e.sessionPresent; // Compile-time non-null.
          expect(sessionPresent, session);
          expect(e, isA<T>());
          expect(e.sessionPresent, session);
          expect(e.automatic, automatic);
          return;
        }
        fail('Connection stream ended before success');
      }

      try {
        expect(await client.connectAndWaitForTest(), false);
        await success<MqttConnected>(false, false);
        await client.subscribe(
            MqttSubscription('sdk/dart/session', qos: MqttQos.atLeastOnce));
        await client.disconnect();
        expect(await client.connectAndWaitForTest(), true);
        await success<MqttReconnected>(true, false);
        // Graceful broker restart reloads the persisted MQTT session.
        await broker('stop');
        await broker('resume');
        await success<MqttReconnected>(true, true);
        await client.publishQos1('sdk/dart/session', Uint8List.fromList([42]));
        expect(await received.moveNext().timeout(const Duration(seconds: 10)),
            true);
        expect(
            received.current.payload, [42]); // Subscription actually survived.
        // Same client ID/cleanSession=false, but broker has lost the session.
        await broker('stop');
        await broker('start');
        await success<MqttReconnected>(false, true);
      } finally {
        await client.close();
        await listener.cancel();
        await events.cancel();
        await received.cancel();
        await queue.close();
        await messages.close();
      }
    }

    await exercise(await create('dart-reconnect'), initialFailure: false);
    await persistentSession();
    await broker('stop');
    try {
      await exercise(await create('dart-initial-retry'), initialFailure: true);
    } finally {
      await broker('start');
    }
  },
      skip: control == null
          ? 'Run go -C scripts run . test --suite reconnect'
          : false,
      timeout: const Timeout(Duration(seconds: 120)));
}
