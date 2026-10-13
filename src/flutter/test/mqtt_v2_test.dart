import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paho_mqtt_ffi/mqtt311.dart' as v3;
import 'package:paho_mqtt_ffi/mqtt5.dart' as v5;

import 'support/native_bootstrap.dart';

List<int> vbi(int n) {
  final b = <int>[];
  do {
    final d = n % 128;
    n ~/= 128;
    b.add(d | (n > 0 ? 128 : 0));
  } while (n > 0);
  return b;
}

List<int> str(String s) {
  final b = utf8.encode(s);
  return [b.length >> 8, b.length & 255, ...b];
}

List<int> props(List<int> b) => [...vbi(b.length), ...b];
List<int> reason(String s) => [31, ...str(s)];
List<int> user(String k, String v) => [38, ...str(k), ...str(v)];

class Frame {
  Frame(this.header, this.body);
  final int header;
  final List<int> body;
  int get type => header >> 4;
}

class Peer {
  Peer(this.socket) {
    socket.listen((bytes) {
      buffer.addAll(bytes);
      while (buffer.length >= 2) {
        var n = 0, m = 1, i = 1;
        while (i < buffer.length) {
          final d = buffer[i++];
          n += (d & 127) * m;
          m *= 128;
          if (d < 128) break;
        }
        if (buffer[i - 1] >= 128 || buffer.length < i + n) return;
        final f = Frame(buffer[0], buffer.sublist(i, i + n));
        buffer.removeRange(0, i + n);
        received.add(f);
        frames.add(f);
      }
    });
  }
  final received = <Frame>[];
  final Socket socket;
  final buffer = <int>[];
  final frames = StreamController<Frame>();
  late final StreamIterator<Frame> iterator = StreamIterator(frames.stream);
  Future<Frame> next([int? type]) async {
    expect(await iterator.moveNext().timeout(const Duration(seconds: 8)), true);
    final f = iterator.current;
    if (type != null) expect(f.type, type);
    return f;
  }

  void send(int h, List<int> b) {
    socket.add([h, ...vbi(b.length), ...b]);
  }
}

class Broker {
  Broker(this.server) {
    server.listen((s) {
      final p = Peer(s);
      peers.add(p);
      arrivals.add(p);
    });
  }
  final ServerSocket server;
  final peers = <Peer>[];
  final arrivals = StreamController<Peer>();
  late final StreamIterator<Peer> iterator = StreamIterator(arrivals.stream);
  String get uri => 'tcp://127.0.0.1:${server.port}';
  static Future<Broker> create() async =>
      Broker(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
  Future<Peer> accept() async {
    expect(await iterator.moveNext().timeout(const Duration(seconds: 8)), true);
    return iterator.current;
  }

  Future<void> close() async {
    for (final p in peers) {
      p.socket.destroy();
    }
    await server.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => mockMqttNativeApi());
  test(
      'MQTT5 wire properties, ACK snapshots, subscriptions and server disconnect',
      () async {
    final broker = await Broker.create();
    final connected = Completer<v5.MqttConnected>();
    final disconnected = Completer<v5.MqttDisconnected>();
    final arrived = Completer<v5.MqttMessage>();
    final client = await v5.MqttClient.create(v5.MqttOptions(
        serverUri: broker.uri,
        clientId: 'wire-v5',
        keepAliveSeconds: 0,
        credentials: v5.MqttCredentials(
            username: 'a', passwordBytes: Uint8List.fromList([0, 255])),
        connectProperties:
            const v5.MqttConnectProperties(requestResponseInformation: true)));
    try {
      await expectLater(client.publishQos1('offline', Uint8List(0)),
          throwsA(isA<v5.MqttException>()));
      await client.startConnecting(v5.MqttEventListener(onEvent: (e) {
        if (e is v5.MqttConnected) connected.complete(e);
        if (e is v5.MqttDisconnected) disconnected.complete(e);
        if (e is v5.MqttMessage) arrived.complete(e);
      }));
      final peer = await broker.accept();
      final connect = await peer.next(1);
      expect(connect.body[6], 5);
      expect(connect.body.sublist(connect.body.length - 4), [0, 2, 0, 255]);
      peer.send(0x20, [
        0,
        0,
        ...props([
          26,
          ...str('replies/wire'),
          33,
          0,
          7,
          ...user('dup', '1'),
          ...user('dup', '2')
        ])
      ]);
      final c = await connected.future.timeout(const Duration(seconds: 8));
      expect(c.properties.responseInformation, 'replies/wire');
      expect(c.settings.serverReceiveMaximum, 7);
      expect(c.properties.userProperties.map((e) => e.value), ['1', '2']);
      final Future<v5.MqttQos1PublishResult> published = client.publishQos1(
          'wire/topic', Uint8List.fromList([1, 0, 255]),
          properties: v5.MqttPublishProperties(
              responseTopic: 'reply',
              correlationData: Uint8List.fromList([0, 255]),
              userProperties: const [v5.MqttUserProperty('request', 'only')]));
      final pub = await peer.next(3);
      final topicLen = pub.body[0] * 256 + pub.body[1];
      final pid = pub.body.sublist(2 + topicLen, 4 + topicLen);
      expect(pub.body, containsAllInOrder([9, 0, 2, 0, 255]));
      peer.send(0x40, [
        ...pid,
        0x10,
        ...props([...reason('no peers'), ...user('ack', 'actual')])
      ]);
      final result = await published;
      final v5.MqttAcknowledgementProperties ackProperties =
          result.puback.properties;
      expect(ackProperties.reasonString, 'no peers');
      expect(result.puback.reasonCode.rawValue, 0x10);
      expect(
          result.toString(),
          contains(
              'MqttQos1PublishResult(puback: MqttPublishAcknowledgement('));
      expect(result.toString(), contains('no peers'));
      expect(result.toString(), isNot(contains('Instance of')));
      expect(result.puback.properties.reasonString, 'no peers');
      expect(result.puback.properties.userProperties.single.name, 'ack');
      final Future<v5.MqttQos2PublishResult> qos2 =
          client.publishQos2('q2', Uint8List(0));
      var qos2Completed = false;
      unawaited(qos2.then((_) {
        qos2Completed = true;
      }));
      final p2 = await peer.next(3);
      final id2 = p2.body.sublist(4, 6);
      peer.send(0x50, [...id2, 0, ...props(reason('rec'))]);
      await peer.next(6);
      expect(qos2Completed, false, reason: 'PUBREC must not complete QoS 2');
      peer.send(0x70, [...id2, 0, ...props(reason('comp'))]);
      final r2 = await qos2;
      expect([r2.pubrec.packetType, r2.pubcomp.packetType], [5, 7]);
      expect([
        r2.pubrec.properties.reasonString,
        r2.pubcomp.properties.reasonString
      ], [
        'rec',
        'comp'
      ]);
      final sub = client.subscribeMany(const [
        v5.MqttSubscription('same',
            noLocal: true,
            retainAsPublished: true,
            retainHandling: v5.MqttRetainHandling.never),
        v5.MqttSubscription('same')
      ],
          properties:
              const v5.MqttSubscribeProperties(subscriptionIdentifier: 17));
      final s = await peer.next(8);
      expect(s.body, containsAllInOrder([11, 17]));
      expect(s.body, contains(0x2d));
      peer.send(0x90, [...s.body.take(2), ...props(reason('mixed')), 1, 0x87]);
      final sr = await sub;
      expect(sr.entries.map((e) => e.accepted), [true, false]);
      expect(
          () => sr.requireAllAccepted(),
          throwsA(isA<v5.MqttProtocolException>()
              .having((e) => e.subscribeResult, 'complete batch', same(sr))
              .having((e) => e.properties, 'properties', same(sr.properties))
              .having((e) => e.properties.reasonString, 'reason', 'mixed')));
      final single = client.subscribe(const v5.MqttSubscription('denied'));
      final ss = await peer.next(8);
      peer.send(0x90, [...ss.body.take(2), 0, 0x87]);
      expect((await single).entries.single.accepted, false);
      final unsub = client.unsubscribeMany(['same', 'absent']);
      final u = await peer.next(10);
      peer.send(0xb0, [...u.body.take(2), ...props(reason('gone')), 0, 0x11]);
      final ur = await unsub;
      expect(ur.entries.map((e) => e.succeeded), [true, true]);
      final v5.MqttAcknowledgementProperties unsubProperties = ur.properties;
      expect(unsubProperties.reasonString, 'gone');
      final deniedUnsub = client.unsubscribe('denied');
      final du = await peer.next(10);
      peer.send(
          0xb0, [...du.body.take(2), ...props(reason('not allowed')), 0x87]);
      final deniedResult = await deniedUnsub;
      expect(
          deniedResult.requireAllSucceeded,
          throwsA(isA<v5.MqttProtocolException>()
              .having((e) => e.unsubscribeResult, 'complete batch',
                  same(deniedResult))
              .having(
                  (e) => e.properties.reasonString, 'reason', 'not allowed')));
      peer.send(0x30, [
        ...str('incoming'),
        ...props(
            [9, 0, 0, 11, 17, 11, 18, ...user('a', '1'), ...user('a', '2')]),
        0,
        255
      ]);
      final incoming = await arrived.future;
      expect(incoming.payload, [0, 255]);
      expect(incoming.toString(), contains('payload: <2 bytes>'));
      expect(
          incoming.toString(), contains('subscriptionIdentifiers: [17, 18]'));
      expect(incoming.properties.correlationData, isEmpty);
      expect(incoming.properties.subscriptionIdentifiers, [17, 18]);
      peer.send(0xe0, [
        0x9c,
        ...props([
          ...reason('move'),
          28,
          ...str('other.example'),
          ...user('x', '1'),
          ...user('x', '2')
        ])
      ]);
      final lost =
          await disconnected.future.timeout(const Duration(seconds: 8));
      expect(lost.source, v5.MqttDisconnectSource.server);
      expect(lost.toString(), contains('MqttDisconnected('));
      expect(lost.toString(), contains('other.example'));
      expect(lost.toString(), isNot(contains('Instance of')));
      expect(lost.serverDisconnect!.reasonCode.rawValue, 0x9c);
      expect(
          lost.serverDisconnect!.properties.serverReference, 'other.example');
      expect(lost.serverDisconnect!.properties.userProperties.length, 2);
      expect(lost.serverDisconnect!.properties.reasonString, 'move');
      expect(lost.serverDisconnect!.properties.sessionExpiryIntervalSeconds,
          isNull);
      expect(result.puback.properties.reasonString, 'no peers');
    } finally {
      await client.close();
      await broker.close();
    }
  });
  test('four disconnect methods encode fixed/default/custom reasons', () async {
    for (var mode = 0; mode < 7; mode++) {
      final broker = await Broker.create();
      final ready = Completer<void>();
      final client = await v5.MqttClient.create(
          v5.MqttOptions(serverUri: broker.uri, clientId: 'disconnect-$mode'));
      try {
        await client.startConnecting(v5.MqttEventListener(onEvent: (e) {
          if (e is v5.MqttConnected) ready.complete();
        }));
        final p = await broker.accept();
        await p.next(1);
        p.send(0x20, [0, 0, 0]);
        await ready.future;
        Future<void> operation = switch (mode) {
          0 => client.disconnect(),
          1 => client.disconnectWithWillMessage(),
          2 => client.disconnectWithUnspecifiedError(),
          3 => client.disconnectWithImplementationError(),
          4 => client.disconnectWithImplementationError(reason: ''),
          5 => client.disconnectWithImplementationError(
              reason: 'business failure'),
          _ => client.disconnectWithImplementationError(reason: '   ')
        };
        final d = await p.next(14);
        expect(d.body[0], [0, 4, 128, 131, 131, 131, 131][mode]);
        final text = [
          'Normal disconnection',
          'Disconnect with Will Message',
          'Unspecified error',
          'Implementation specific error',
          'Implementation specific error',
          'business failure',
          '   '
        ][mode];
        expect(d.body.sublist(2), reason(text));
        await operation;
        await expectLater(
            client.disconnect(), throwsA(isA<v5.MqttException>()));
      } finally {
        await client.close();
        await broker.close();
      }
    }
  });
  test('3.1.1 shares ABI2, preserves binary will and normalized SUBACK',
      () async {
    final broker = await Broker.create();
    final ready = Completer<void>();
    final client = await v3.MqttClient.create(v3.MqttOptions(
        serverUri: broker.uri,
        clientId: 'wire-v3',
        keepAliveSeconds: 0,
        will: v3.MqttWillOptions(
            topic: 'will', payload: Uint8List.fromList([0, 255]))));
    try {
      await client.startConnecting(v3.MqttEventListener(onEvent: (e) {
        if (e is v3.MqttConnected) ready.complete();
      }));
      final p = await broker.accept();
      final connect = await p.next(1);
      expect(connect.body[6], 4);
      expect(connect.body.sublist(connect.body.length - 4), [0, 2, 0, 255]);
      p.send(0x20, [0, 0]);
      await ready.future;
      final sub = client.subscribe(const v3.MqttSubscription('deny'));
      final s = await p.next(8);
      p.send(0x90, [...s.body.take(2), 0x80]);
      expect((await sub).entries.single.accepted, false);
      final pub = client.publishQos0('test', Uint8List(0));
      await p.next(3);
      await pub;
      final d = client.disconnect(drainTimeoutMs: 0);
      expect((await p.next(14)).body, isEmpty);
      await d;
    } finally {
      await client.close();
      await broker.close();
    }
  });
  test('CONNACK refusal and automatic reconnect replace connection properties',
      () async {
    final broker = await Broker.create();
    final events = StreamController<v5.MqttEvent>();
    final iterator = StreamIterator(events.stream);
    final client = await v5.MqttClient.create(v5.MqttOptions(
        serverUri: broker.uri,
        clientId: 'reconnect',
        automaticReconnect: true,
        minRetrySeconds: 1,
        maxRetrySeconds: 1,
        session: const v5.MqttSessionOptions(
            cleanStart: v5.MqttCleanStartPolicy.firstConnection,
            expiryIntervalSeconds: 60),
        keepAliveSeconds: 0));
    Future<T> event<T>() async {
      while (await iterator.moveNext().timeout(const Duration(seconds: 10))) {
        if (iterator.current is T) return iterator.current as T;
      }
      throw StateError('missing $T');
    }

    final listener = v5.MqttEventListener(onEvent: events.add);
    try {
      await client.startConnecting(listener);
      final first = await broker.accept();
      expect((await first.next(1)).body[7] & 2, 2);
      first.send(0x20, [
        0,
        0x87,
        ...props([...reason('denied'), 28, ...str('refused.example')])
      ]);
      final refused = await event<v5.MqttConnectFailed>();
      expect(refused.reasonCode!.rawValue, 0x87);
      expect(refused.properties!.reasonString, 'denied');
      expect(refused.properties!.serverReference, 'refused.example');
      final refusal = refused.error as v5.MqttProtocolException;
      expect(refusal.properties, isA<v5.MqttConnackProperties>());
      expect((refusal.properties as v5.MqttConnackProperties).serverReference,
          'refused.example');
      await expectLater(client.disconnect(), throwsA(isA<v5.MqttException>()));
      final second = await broker.accept();
      expect((await second.next(1)).body[7] & 2, 2);
      second.send(0x20, [
        0,
        0,
        ...props(
            [26, ...str('first-response'), 17, 0, 0, 0, 30, 19, 0, 2, 33, 0, 1])
      ]);
      final connected = await event<v5.MqttConnected>();
      expect(connected.settings.sessionExpiryIntervalSeconds, 30);
      expect(connected.settings.keepAliveSeconds, 2);
      second.socket.destroy();
      await event<v5.MqttDisconnected>();
      final third = await broker.accept();
      expect((await third.next(1)).body[7] & 2, 0);
      third.send(0x20, [1, 0, 0]);
      final reconnected = await event<v5.MqttReconnected>();
      expect(reconnected.sessionPresent, true);
      expect(reconnected.properties.responseInformation, isNull);
      expect(reconnected.settings.serverReceiveMaximum, 65535);
      expect(reconnected.settings.keepAliveSeconds, 0);
      expect(reconnected.settings.sessionExpiryIntervalSeconds, 60);
      final pending = client.publishQos1('blocked', Uint8List(0));
      await third.next(3);
      final expectation = expectLater(pending, throwsA(isA<Exception>()));
      await client.close();
      await expectation;
    } finally {
      await client.close();
      await broker.close();
      await iterator.cancel();
      await events.close();
    }
  });
  for (final serverInitiated in [false, true]) {
    test(
        'MQTT5 ${serverInitiated ? "server" : "local"} disconnect resets retry cycle',
        () async {
      final broker = await Broker.create();
      final queue = StreamController<v5.MqttEvent>();
      final events = StreamIterator(queue.stream);
      final client = await v5.MqttClient.create(v5.MqttOptions(
        serverUri: broker.uri,
        clientId: 'retry-cycle-$serverInitiated',
        automaticReconnect: true,
        minRetrySeconds: 1,
        maxRetrySeconds: 1,
        keepAliveSeconds: 0,
      ));
      final listener = v5.MqttEventListener(onEvent: queue.add);
      var sequence = 0;
      Future<T> next<T extends v5.MqttConnectionEvent>() async {
        expect(
            await events.moveNext().timeout(const Duration(seconds: 10)), true);
        expect(events.current, isA<T>());
        final event = events.current as T;
        expect(event.sequence, ++sequence);
        expect(event.droppedEvents, 0);
        return event;
      }

      try {
        // Seed a nonzero retry counter before the first successful connection.
        await client.startConnecting(listener);
        final rejected = await broker.accept();
        await rejected.next(1);
        rejected.send(0x20, [0, 0x87, 0]);
        final failure = await next<v5.MqttConnectFailed>();
        expect(failure.retryAttempt, 0);
        expect(failure.totalRetryAttempts, 0);
        final initialRetry = await next<v5.MqttReconnecting>();
        expect(initialRetry.retryAttempt, 1);
        expect(initialRetry.totalRetryAttempts, 1);
        var peer = await broker.accept();
        await peer.next(1);
        peer.send(0x20, [0, 0, 0]);
        final connected = await next<v5.MqttConnected>();
        expect(connected.retryAttempt, 1);
        expect(connected.connectionCount, 1);

        for (var cycle = 1; cycle <= 2; cycle++) {
          if (serverInitiated) {
            peer.send(0xe0, [0x80, ...props(reason('cycle-$cycle'))]);
            await peer.socket.flush();
          } else {
            final disconnect = client.disconnect(drainTimeoutMs: 0);
            await peer.next(14);
            await disconnect;
          }
          final lost = await next<v5.MqttDisconnected>();
          expect(lost.retryAttempt, 0);
          expect(lost.totalRetryAttempts, cycle);
          expect(lost.connectionCount, cycle);
          expect(lost.reconnectCount, cycle - 1);
          expect(lost.willRetry, serverInitiated);
          expect(
              lost.source,
              serverInitiated
                  ? v5.MqttDisconnectSource.server
                  : v5.MqttDisconnectSource.local);
          if (serverInitiated) {
            expect(
                lost.serverDisconnect!.properties.reasonString, 'cycle-$cycle');
          } else {
            await client.startConnecting(listener);
          }
          final retry = await next<v5.MqttReconnecting>();
          expect(retry.retryAttempt, 1);
          expect(retry.totalRetryAttempts, cycle + 1);
          expect(retry.automatic, serverInitiated);
          peer = await broker.accept();
          await peer.next(1);
          peer.send(0x20, [0, 0, 0]);
          final restored = await next<v5.MqttReconnected>();
          expect(restored.retryAttempt, 1);
          expect(restored.totalRetryAttempts, cycle + 1);
          expect(restored.connectionCount, cycle + 1);
          expect(restored.reconnectCount, cycle);
          expect(restored.automatic, serverInitiated);
        }
      } finally {
        await client.close();
        await events.cancel();
        await queue.close();
        await broker.close();
      }
    });
  }
  test(
      'server limits and disconnect validation reject without corrupting live connection',
      () async {
    final broker = await Broker.create();
    final ready = Completer<void>();
    final client = await v5.MqttClient.create(
        v5.MqttOptions(serverUri: broker.uri, clientId: 'limits'));
    try {
      await client.startConnecting(v5.MqttEventListener(onEvent: (e) {
        if (e is v5.MqttConnected) ready.complete();
      }));
      final p = await broker.accept();
      await p.next(1);
      p.send(0x20, [
        0,
        0,
        ...props([39, 0, 0, 0, 40, 36, 0, 37, 0, 40, 0, 41, 0, 42, 0])
      ]);
      await ready.future;
      await expectLater(client.publishQos1('x', Uint8List(0)),
          throwsA(isA<v5.MqttException>()));
      await expectLater(client.publishQos0('x', Uint8List(0), retained: true),
          throwsA(isA<v5.MqttException>()));
      await expectLater(client.publishQos0('x', Uint8List(50)),
          throwsA(isA<v5.MqttException>()));
      await expectLater(client.subscribe(const v5.MqttSubscription('a/+')),
          throwsA(isA<v5.MqttException>()));
      await expectLater(
          client.subscribe(const v5.MqttSubscription(r'$share/g/x')),
          throwsA(isA<v5.MqttException>()));
      await expectLater(
          client.subscribe(const v5.MqttSubscription('x'),
              properties:
                  const v5.MqttSubscribeProperties(subscriptionIdentifier: 1)),
          throwsA(isA<v5.MqttException>()));
      await expectLater(
          client.disconnect(
              properties: const v5.MqttDisconnectProperties(
                  sessionExpiryIntervalSeconds: 10)),
          throwsA(isA<v5.MqttException>()));
      await expectLater(
          client.disconnectWithImplementationError(reason: 'x' * 50),
          throwsA(isA<v5.MqttException>()));
      await expectLater(
          client.disconnectWithImplementationError(reason: 'bad\u0000reason'),
          throwsArgumentError);
      await expectLater(
          client.disconnect(drainTimeoutMs: -1), throwsArgumentError);
      final publish = client.publishQos0('ok', Uint8List(0));
      expect((await p.next(3)).body, [0, 2, 111, 107, 0]);
      await publish;
      final sub = client.subscribe(
          const v5.MqttSubscription('ok', qos: v5.MqttQos.exactlyOnce));
      final f = await p.next(8);
      p.send(0x90, [...f.body.take(2), 0, 0]);
      expect((await sub).entries.single.accepted, true);
      final d = client.disconnect();
      await p.next(14);
      await d;
    } finally {
      await client.close();
      await broker.close();
    }
  });

  test('smaller Receive Maximum throttles recovered in-flight publishes',
      () async {
    final broker = await Broker.create();
    final events = StreamController<v5.MqttEvent>();
    final it = StreamIterator(events.stream);
    final client = await v5.MqttClient.create(v5.MqttOptions(
        serverUri: broker.uri,
        clientId: 'quota',
        automaticReconnect: true,
        minRetrySeconds: 1,
        maxRetrySeconds: 1,
        session: const v5.MqttSessionOptions(
            cleanStart: v5.MqttCleanStartPolicy.firstConnection,
            expiryIntervalSeconds: 60)));
    Future<T> event<T>() async {
      while (await it.moveNext().timeout(const Duration(seconds: 10))) {
        if (it.current is T) return it.current as T;
      }
      throw StateError('missing $T');
    }

    final futures = <Future<v5.MqttQos1PublishResult>>[];
    try {
      await client.startConnecting(v5.MqttEventListener(onEvent: events.add));
      final a = await broker.accept();
      await a.next(1);
      a.send(0x20, [
        0,
        0,
        ...props([33, 0, 3])
      ]);
      await event<v5.MqttConnected>();
      for (var n = 0; n < 3; n++) {
        futures.add(client.publishQos1('x', Uint8List.fromList([n])));
        await a.next(3);
      }
      a.socket.destroy();
      await event<v5.MqttDisconnected>();
      final b = await broker.accept();
      await b.next(1);
      b.send(0x20, [
        1,
        0,
        ...props([33, 0, 1])
      ]);
      await event<v5.MqttReconnected>();
      for (var n = 0; n < 3; n++) {
        final p = await b.next(3);
        expect(p.header & 8, 8);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(b.received.where((f) => f.type == 3).length, n + 1);
        b.send(0x40, [...p.body.sublist(3, 5), 0, 0]);
      }
      final results =
          await Future.wait(futures).timeout(const Duration(seconds: 8));
      expect(results.length, 3);
      expect(results.map((r) => r.puback.packetType), [4, 4, 4]);
    } finally {
      await client.close();
      await broker.close();
      await it.cancel();
      await events.close();
    }
  });
  test(
      'failed PUBREC retains typed properties and incoming size stops before body',
      () async {
    final broker = await Broker.create();
    final ready = Completer<void>();
    final lost = Completer<v5.MqttDisconnected>();
    final client = await v5.MqttClient.create(v5.MqttOptions(
        serverUri: broker.uri,
        clientId: 'failed-rec',
        automaticReconnect: true,
        minRetrySeconds: 1,
        maxRetrySeconds: 1,
        connectProperties:
            const v5.MqttConnectProperties(maximumPacketSize: 64)));
    try {
      await client.startConnecting(v5.MqttEventListener(onEvent: (e) {
        if (e is v5.MqttConnected) ready.complete();
        if (e is v5.MqttDisconnected) lost.complete(e);
      }));
      final p = await broker.accept();
      await p.next(1);
      p.send(0x20, [0, 0, 0]);
      await ready.future;
      final operation = client.publishQos2('x', Uint8List(0));
      final failure = expectLater(
          operation,
          throwsA(isA<v5.MqttProtocolException>()
              .having((e) => e.packetType, 'packet', 5)
              .having((e) => e.reasonCode, 'reason', 0x87)
              .having((e) => e.properties, 'typed properties',
                  isA<v5.MqttAcknowledgementProperties>())
              .having(
                  (e) => e.properties.reasonString, 'reason string', 'denied')
              .having((e) => e.acknowledgements.single.properties.reasonString,
                  'PUBREC reason', 'denied')));
      final packet = await p.next(3);
      p.send(0x50,
          [...packet.body.sublist(3, 5), 0x87, ...props(reason('denied'))]);
      await failure;
      p.socket.add([
        0x30,
        ...vbi(500000)
      ]); // No body: must reject from Remaining Length alone.
      final disconnected =
          await lost.future.timeout(const Duration(seconds: 8));
      expect(disconnected.willRetry, false);
      expect((disconnected.error as v5.MqttException).info,
          isA<v5.MqttResourceError>());
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(broker.peers.length, 1);
      await expectLater(client.publishQos1('x', Uint8List(0)),
          throwsA(isA<v5.MqttException>()));
    } finally {
      await client.close();
      await broker.close();
    }
  });
  test(
      'persistence identities isolate protocol and broker and lock duplicate opens',
      () async {
    final directory = await Directory.systemTemp.createTemp('mqtt-v2-persist-');
    final persistence = v5.MqttPersistenceOptions(
        directory: directory.path, onCreate: v5.MqttPersistenceRestore.restore);
    v5.MqttOptions options(String uri) => v5.MqttOptions(
        serverUri: uri, clientId: 'persistent', persistence: persistence);
    final a = await v5.MqttClient.create(options('tcp://127.0.0.1:1883'));
    try {
      await expectLater(v5.MqttClient.create(options('tcp://127.0.0.1:1883')),
          throwsA(isA<v5.MqttException>()));
      final b = await v5.MqttClient.create(options('tcp://127.0.0.1:1884'));
      await b.close();
      final c = await v3.MqttClient.create(v3.MqttOptions(
          serverUri: 'tcp://127.0.0.1:1883',
          clientId: 'persistent',
          persistence: persistence));
      await c.close();
      await a.close();
      final reopened =
          await v5.MqttClient.create(options('tcp://127.0.0.1:1883'));
      await reopened.close();
    } finally {
      await a.close();
      await directory.delete(recursive: true);
    }
  });
}
