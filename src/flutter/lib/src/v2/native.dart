import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import '../errors.dart' as errors;
import '../../common.dart';

typedef _VersionN = Pointer<Utf8> Function();
typedef _SubmitN = Int32 Function(
    Uint64, Uint64, Int32, Pointer<Utf8>, Pointer<Uint8>, Uint32, Int32, Int32);
typedef _TakeN = Int32 Function(Uint64, Pointer<Pointer<_Event>>);
typedef _FreeN = Void Function(Pointer<_Event>);
typedef _InitializeN = Int32 Function(Pointer<Void>);
typedef _PortN = Int32 Function(Uint64, Int64);
typedef _ReleaseN = Int32 Function(Uint64);

final class _Config extends Struct {
  @Uint32()
  external int structSize;
  @Int32()
  external int keepAlive;
  @Int32()
  external int connectTimeout;
  @Int32()
  external int cleanSession;
  @Int32()
  external int automaticReconnect;
  @Int32()
  external int minRetry;
  @Int32()
  external int maxRetry;
  @Int32()
  external int insecureSkipVerify;
  external Pointer<Utf8> serverUri;
  external Pointer<Utf8> clientId;
  external Pointer<Utf8> username;
  external Pointer<Utf8> password;
  external Pointer<Utf8> trustStore;
  external Pointer<Utf8> certificate;
  external Pointer<Utf8> privateKey;
  external Pointer<Utf8> privateKeyPassword;
  external Pointer<Utf8> persistencePath;
}

final class _Event extends Struct {
  @Uint64()
  external int request;
  @Int32()
  external int type;
  @Int32()
  external int operation;
  @Int32()
  external int code;
  @Int32()
  external int value;
  @Uint32()
  external int flags;
  @Uint32()
  external int topicLength;
  @Uint32()
  external int payloadLength;
  @Uint32()
  external int reserved;
  external Pointer<Utf8> topic;
  external Pointer<Uint8> payload;
  @Uint64()
  external int timestampMs;
  @Uint64()
  external int sequence;
  @Uint64()
  external int connectionCount;
  @Uint64()
  external int reconnectCount;
  @Uint64()
  external int retryAttempt;
  @Uint64()
  external int totalRetryAttempts;
  @Uint64()
  external int disconnectedAtMs;
  @Uint64()
  external int downtimeMs;
  @Uint64()
  external int attemptStartedAtMs;
  @Uint64()
  external int droppedEvents;
  external Pointer<errors.NativeError> error;
}

final class _CoreApi extends Struct {
  @Uint32()
  external int abiVersion;
  @Uint32()
  external int structSize;
  @Uint64()
  external int capabilities;
  external Pointer<NativeFunction<_VersionN>> pahoVersion;
  external Pointer<NativeFunction<_SubmitN>> submit;
  external Pointer<NativeFunction<_TakeN>> take;
  external Pointer<NativeFunction<_FreeN>> free;
  external Pointer<NativeFunction<_ReleaseN>> release;
  external Pointer<Void>
      setNotifier; // Native dispatcher callback registration, not invoked by Dart.
  external Pointer<NativeFunction<_InitializeN>> initializeDart;
  external Pointer<NativeFunction<_PortN>> setPort;
  external Pointer<
          NativeFunction<
              Void Function(Int32, Int32, Pointer<errors.NativeError>)>>
      describeError;
}

final class _Property extends Struct {
  @Uint32()
  external int id;
  @Uint32()
  external int number;
  @Uint32()
  external int length;
  @Uint32()
  external int valueLength;
  external Pointer<Uint8> data;
  external Pointer<Uint8> value;
}

final class _Properties extends Struct {
  @Uint32()
  external int count;
  external Pointer<_Property> items;
}

final class _Config2 extends Struct {
  external _Config base;
  @Uint32()
  external int structSize;
  @Uint32()
  external int protocol;
  @Uint32()
  external int cleanPolicy;
  @Uint32()
  external int sessionExpiry;
  @Uint32()
  external int maxPending;
  @Uint32()
  external int maxBuffered;
  @Uint32()
  external int maxInflight;
  @Uint32()
  external int maxMessages;
  @Uint32()
  external int maxBytes;
  @Uint32()
  external int passwordPresent;
  @Uint32()
  external int passwordLength;
  external Pointer<Uint8> passwordBytes;
  external Pointer<Utf8> willTopic;
  external Pointer<Uint8> willPayload;
  @Uint32()
  external int willLength;
  @Uint32()
  external int willQos;
  @Uint32()
  external int willRetained;
  external _Properties connectProperties;
  external _Properties willProperties;
  @Uint32()
  external int restoreMessages;
  @Uint32()
  external int persistQos0;
}

final class _Subscription extends Struct {
  external Pointer<Utf8> filter;
  @Uint32()
  external int qos;
  @Uint32()
  external int noLocal;
  @Uint32()
  external int rap;
  @Uint32()
  external int rh;
}

final class _Ack extends Struct {
  @Int32()
  external int packetType;
  @Int32()
  external int reason;
  external _Properties properties;
}

final class _Details extends Struct {
  @Int32()
  external int packetType;
  @Int32()
  external int reason;
  @Int32()
  external int source;
  @Int32()
  external int willRetry;
  external _Properties properties;
  @Uint32()
  external int ackCount;
  external Pointer<_Ack> acks;
}

typedef _Create2N = Int32 Function(Pointer<_Config2>, Pointer<Uint64>);
typedef _Publish2N = Int32 Function(Uint64, Uint64, Pointer<Utf8>,
    Pointer<Uint8>, Uint32, Uint32, Uint32, Pointer<_Properties>);
typedef _Subscribe2N = Int32 Function(
    Uint64, Uint64, Uint32, Pointer<_Subscription>, Pointer<_Properties>);
typedef _Unsubscribe2N = Int32 Function(
    Uint64, Uint64, Uint32, Pointer<Pointer<Utf8>>, Pointer<_Properties>);
typedef _Disconnect2N = Int32 Function(
    Uint64, Uint64, Uint32, Pointer<_Properties>);
typedef _DisconnectImplN = Int32 Function(
    Uint64, Uint64, Pointer<Utf8>, Uint32, Pointer<_Properties>);

final class _Api2 extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int structSize;
  @Uint64()
  external int capabilities;
  external Pointer<_CoreApi> core;
  external Pointer<NativeFunction<_Create2N>> create;
  external Pointer<NativeFunction<_Publish2N>> publish;
  external Pointer<NativeFunction<_Subscribe2N>> subscribe;
  external Pointer<NativeFunction<_Unsubscribe2N>> unsubscribe;
  external Pointer<NativeFunction<_Disconnect2N>> disconnect;
  external Pointer<NativeFunction<_Disconnect2N>> disconnectWill;
  external Pointer<NativeFunction<_Disconnect2N>> disconnectUnspecified;
  external Pointer<NativeFunction<_DisconnectImplN>> disconnectImplementation;
  external Pointer<NativeFunction<Pointer<_Details> Function(Pointer<_Event>)>>
      details;
}

final class PropertyValue {
  const PropertyValue(this.id, this.value, [this.second]);
  final int id;
  final Object value;
  final String? second;
}

final class NativeOptions {
  const NativeOptions(
      {required this.protocol,
      required this.serverUri,
      required this.clientId,
      this.credentials = const MqttCredentials(),
      this.tls = const MqttTlsOptions(),
      this.limits = const MqttQueueLimits(),
      this.persistence,
      this.keepAlive = 60,
      this.timeout = 30,
      this.cleanSession = true,
      this.cleanPolicy = 0,
      this.sessionExpiry = 0,
      this.reconnect = false,
      this.minRetry = 1,
      this.maxRetry = 60,
      this.properties = const [],
      this.willTopic,
      this.willPayload,
      this.willQos = 0,
      this.willRetained = false,
      this.willProperties = const [],
      this.protocolError});
  final int protocol,
      keepAlive,
      timeout,
      cleanPolicy,
      sessionExpiry,
      minRetry,
      maxRetry,
      willQos;
  final String serverUri, clientId;
  final String? willTopic;
  final MqttPersistenceOptions? persistence;
  final bool cleanSession, reconnect, willRetained;
  final MqttCredentials credentials;
  final MqttTlsOptions tls;
  final MqttQueueLimits limits;
  final List<PropertyValue> properties, willProperties;
  final Uint8List? willPayload;
  final Object Function(int, int, List<PropertyValue>, List<NativeAck>)?
      protocolError;
}

final class NativeSubscription {
  const NativeSubscription(this.filter, this.qos,
      [this.noLocal = false, this.rap = false, this.rh = 0]);
  final String filter;
  final int qos, rh;
  final bool noLocal, rap;
}

final class NativeAck {
  const NativeAck(this.packetType, this.reason, this.properties);
  final int packetType, reason;
  final List<PropertyValue> properties;
}

final class NativeEvent {
  NativeEvent(
      this.type,
      this.operation,
      this.value,
      this.flags,
      this.topic,
      this.payload,
      this.packetType,
      this.reason,
      this.source,
      this.willRetry,
      this.properties,
      this.acks,
      this.history,
      this.error);
  final int type, operation, value, flags, packetType, reason, source;
  final bool willRetry;
  final String? topic;
  final Uint8List payload;
  final List<PropertyValue> properties;
  final List<NativeAck> acks;
  final Map<String, int> history;
  final Object? error;
  int get estimatedBytes {
    int sizeOfProperty(PropertyValue p) =>
        32 +
        (p.value is String
            ? (p.value as String).length * 3
            : p.value is Uint8List
                ? (p.value as Uint8List).length
                : 8) +
        (p.second?.length ?? 0) * 3;
    return 256 +
        (topic?.length ?? 0) * 3 +
        payload.length +
        properties.fold<int>(0, (n, p) => n + sizeOfProperty(p)) +
        acks.fold<int>(
            0,
            (n, a) =>
                n +
                32 +
                a.properties.fold<int>(0, (m, p) => m + sizeOfProperty(p)));
  }
}

Pointer<Utf8> _string(Arena a, String? s) {
  if (s == null) return nullptr;
  if (s.runes.any((r) => r == 0 || (r >= 0xd800 && r <= 0xdfff)) ||
      utf8.encode(s).length > 65535)
    throw ArgumentError('Invalid MQTT UTF-8 string');
  return s.toNativeUtf8(allocator: a);
}

Pointer<Uint8> _bytes(Arena a, Uint8List? data) {
  if (data == null) return nullptr;
  final p = a<Uint8>(data.isEmpty ? 1 : data.length);
  p.asTypedList(data.length).setAll(0, data);
  return p;
}

void _props(Arena a, _Properties p, List<PropertyValue> values) {
  p.count = values.length;
  p.items = values.isEmpty ? nullptr : a<_Property>(values.length);
  for (var i = 0; i < values.length; i++) {
    final v = values[i], n = (p.items + i).ref;
    n.id = v.id;
    if (v.value is int) {
      final number = v.value as int;
      if (number < 0 || number > 0xffffffff)
        throw ArgumentError('Property range');
      n.number = number;
    } else {
      if (v.value is String) _string(a, v.value as String);
      if (v.second != null) _string(a, v.second);
      final b = v.value is String
          ? Uint8List.fromList(utf8.encode(v.value as String))
          : v.value as Uint8List;
      n.length = b.length;
      n.data = _bytes(a, b);
      if (v.second != null) {
        final b2 = Uint8List.fromList(utf8.encode(v.second!));
        n.valueLength = b2.length;
        n.value = _bytes(a, b2);
      }
    }
  }
}

Pointer<_Properties> _propPointer(Arena a, List<PropertyValue> values) {
  final p = a<_Properties>();
  _props(a, p.ref, values);
  return p;
}

List<PropertyValue> _readProps(_Properties p) =>
    List.unmodifiable(List.generate(p.count, (i) {
      final v = (p.items + i).ref;
      if ([1, 2, 11, 17, 19, 23, 24, 25, 33, 34, 35, 36, 37, 39, 40, 41, 42]
          .contains(v.id)) return PropertyValue(v.id, v.number);
      final bytes = v.length == 0
          ? Uint8List(0)
          : Uint8List.fromList(v.data.asTypedList(v.length));
      return PropertyValue(
          v.id,
          [9, 22].contains(v.id) ? bytes : utf8.decode(bytes),
          v.id == 38 ? utf8.decode(v.value.asTypedList(v.valueLength)) : null);
    }));

class _Binding {
  _Binding(this.pointer);
  final Pointer<_Api2> pointer;
  _Api2 get api => pointer.ref;
  _CoreApi get core => api.core.ref;
  static final Future<_Binding> instance = _load();
  static Future<_Binding> _load() async {
    if (RootIsolateToken.instance != null)
      WidgetsFlutterBinding.ensureInitialized();
    final result = await const MethodChannel('org.paho.mqtt/native_api')
        .invokeMapMethod<String, Object?>('getNativeApi', {'abiVersion': 2});
    if (result == null ||
        result['abiVersion'] != 2 ||
        result['pointerBits'] != sizeOf<IntPtr>() * 8)
      throw StateError('MQTT ABI 2 bootstrap mismatch; rebuild native library');
    final address =
        int.tryParse(result['addressHex'] as String? ?? '', radix: 16);
    if (address == null || address == 0)
      throw StateError('Invalid MQTT native address');
    final b = _Binding(Pointer<_Api2>.fromAddress(address));
    if (b.api.version != 2 ||
        b.api.structSize < sizeOf<_Api2>() ||
        b.api.capabilities & 1 == 0)
      throw StateError('MQTT ABI 2 table mismatch');
    if (b.api.core == nullptr ||
        b.core.abiVersion != 2 ||
        b.core.structSize < sizeOf<_CoreApi>() ||
        b.core.capabilities & 1661 != 1661 ||
        b.core.pahoVersion == nullptr ||
        (b.core.capabilities & 2 != 0 && b.core.capabilities & 384 != 384))
      throw StateError('MQTT shared core ABI mismatch');
    final rc = b.core.initializeDart.asFunction<int Function(Pointer<Void>)>()(
        NativeApi.initializeApiDLData);
    if (rc != 0) throw b.error(rc, 0);
    return b;
  }

  Object error(int code, int op) => using((a) {
        final e = a<errors.NativeError>();
        core.describeError.asFunction<
            void Function(
                int, int, Pointer<errors.NativeError>)>()(code, op, e);
        return errors.decodeNativeException(e);
      });
}

/// Private transport shared by the two typed protocol facades.
final class NativeClient {
  NativeClient._(this._b, this.id, this._protocolError) {
    _pending[0] = Completer<NativeEvent>();
    _port.listen((_) => _drain());
    final rc = _b.core.setPort.asFunction<int Function(int, int)>()(
        id, _port.sendPort.nativePort);
    if (rc != 0) throw _b.error(rc, 0);
  }
  final _Binding _b;
  final Object Function(int, int, List<PropertyValue>, List<NativeAck>)?
      _protocolError;
  final int id;
  int _request = 0;
  bool _closed = false, _closing = false;
  Future<void>? _close;
  final _port = ReceivePort();
  final _pending = <int, Completer<NativeEvent>>{};
  final _events = StreamController<NativeEvent>();
  Stream<NativeEvent> get events => _events.stream;
  String get pahoVersion => _b.core.pahoVersion
      .asFunction<Pointer<Utf8> Function()>()()
      .toDartString();
  static Future<NativeClient> create(NativeOptions o) async {
    final b = await _Binding.instance;
    final id = using((a) {
      // Range-check before FFI unsigned conversion can wrap.
      for (final n in [o.keepAlive, o.timeout, o.minRetry, o.maxRetry]) {
        if (n < 0 || n > 0x7fffffff)
          throw ArgumentError('MQTT option outside int32 range');
      }
      for (final n in [
        o.sessionExpiry,
        o.cleanPolicy,
        o.limits.maxPendingOperations,
        o.limits.maxBufferedPublishes,
        o.limits.maxInflightPublishes,
        o.limits.maxReceivedMessages,
        o.limits.maxBytes
      ]) {
        if (n < 0 || n > 0xffffffff)
          throw ArgumentError('MQTT option outside uint32 range');
      }
      final c = a<_Config2>();
      c.ref
        ..restoreMessages =
            o.persistence?.onCreate == MqttPersistenceRestore.discard ? 0 : 1
        ..persistQos0 = o.persistence?.persistQos0 == true ? 1 : 0
        ..structSize = sizeOf<_Config2>()
        ..protocol = o.protocol
        ..cleanPolicy = o.cleanPolicy
        ..sessionExpiry = o.sessionExpiry
        ..maxPending = o.limits.maxPendingOperations
        ..maxBuffered = o.limits.maxBufferedPublishes
        ..maxInflight = o.limits.maxInflightPublishes
        ..maxMessages = o.limits.maxReceivedMessages
        ..maxBytes = o.limits.maxBytes
        ..passwordPresent = o.credentials.passwordBytes == null ? 0 : 1
        ..passwordLength = o.credentials.passwordBytes?.length ?? 0
        ..passwordBytes = _bytes(a, o.credentials.passwordBytes)
        ..willTopic = _string(a, o.willTopic)
        ..willPayload = _bytes(a, o.willPayload)
        ..willLength = o.willPayload?.length ?? 0
        ..willQos = o.willQos
        ..willRetained = o.willRetained ? 1 : 0;
      c.ref.base
        ..structSize = sizeOf<_Config>()
        ..keepAlive = o.keepAlive
        ..connectTimeout = o.timeout
        ..cleanSession = o.cleanSession ? 1 : 0
        ..automaticReconnect = o.reconnect ? 1 : 0
        ..minRetry = o.minRetry
        ..maxRetry = o.maxRetry
        ..insecureSkipVerify = o.tls.insecureSkipVerify ? 1 : 0
        ..serverUri = _string(a, o.serverUri)
        ..clientId = _string(a, o.clientId)
        ..username = _string(a, o.credentials.username)
        ..trustStore = _string(a, o.tls.trustStore)
        ..certificate = _string(a, o.tls.certificate)
        ..privateKey = _string(a, o.tls.privateKey)
        ..privateKeyPassword = _string(a, o.tls.privateKeyPassword)
        ..persistencePath = _string(a, o.persistence?.directory);
      _props(a, c.ref.connectProperties, o.properties);
      _props(a, c.ref.willProperties, o.willProperties);
      final out = a<Uint64>();
      final rc = b.api.create
              .asFunction<int Function(Pointer<_Config2>, Pointer<Uint64>)>()(
          c, out);
      if (rc != 0) throw b.error(rc, 0);
      return out.value;
    });
    final c = NativeClient._(b, id, o.protocolError);
    try {
      await c._pending[0]!.future;
    } catch (_) {
      await c.close();
      rethrow;
    }
    return c;
  }

  Future<NativeEvent> _call(int op, int Function(Arena, int) invoke) {
    if (_closed || (_closing && op != 6))
      return Future.error(_b.error(-1001, op));
    final request = ++_request;
    try {
      final rc = using((a) => invoke(a, request));
      if (rc != 0) return Future.error(_b.error(rc, op));
      final done = Completer<NativeEvent>();
      _pending[request] = done;
      return done.future;
    } catch (e, s) {
      return Future.error(e, s);
    }
  }

  Future<NativeEvent> control(int op) => _call(
      op,
      (a, r) => _b.core.submit.asFunction<
          int Function(int, int, int, Pointer<Utf8>, Pointer<Uint8>, int, int,
              int)>()(id, r, op, nullptr, nullptr, 0, 0, 0));
  Future<NativeEvent> publish(String topic, Uint8List payload, int qos,
          bool retained, List<PropertyValue> props) =>
      _call(
          4,
          (a, r) => _b.api.publish.asFunction<
                  int Function(int, int, Pointer<Utf8>, Pointer<Uint8>, int,
                      int, int, Pointer<_Properties>)>()(
              id,
              r,
              _string(a, topic),
              _bytes(a, payload),
              payload.length,
              qos,
              retained ? 1 : 0,
              _propPointer(a, props)));
  Future<NativeEvent> subscribe(
          List<NativeSubscription> subs, List<PropertyValue> props) =>
      _call(7, (a, r) {
        final p = a<_Subscription>(subs.isEmpty ? 1 : subs.length);
        for (var i = 0; i < subs.length; i++) {
          (p + i).ref
            ..filter = _string(a, subs[i].filter)
            ..qos = subs[i].qos
            ..noLocal = subs[i].noLocal ? 1 : 0
            ..rap = subs[i].rap ? 1 : 0
            ..rh = subs[i].rh;
        }
        return _b.api.subscribe.asFunction<
                int Function(int, int, int, Pointer<_Subscription>,
                    Pointer<_Properties>)>()(
            id, r, subs.length, p, _propPointer(a, props));
      });
  Future<NativeEvent> unsubscribe(
          List<String> topics, List<PropertyValue> props) =>
      _call(8, (a, r) {
        final p = a<Pointer<Utf8>>(topics.isEmpty ? 1 : topics.length);
        for (var i = 0; i < topics.length; i++) p[i] = _string(a, topics[i]);
        return _b.api.unsubscribe.asFunction<
                int Function(int, int, int, Pointer<Pointer<Utf8>>,
                    Pointer<_Properties>)>()(
            id, r, topics.length, p, _propPointer(a, props));
      });
  Future<NativeEvent> disconnect(int kind, int drain, List<PropertyValue> props,
          {String? reason}) =>
      _call(5, (a, r) {
        if (drain < 0 || drain > 0x7fffffff)
          throw ArgumentError.value(drain, 'drainTimeoutMs');
        if (kind == 3)
          return _b.api.disconnectImplementation.asFunction<
                  int Function(
                      int, int, Pointer<Utf8>, int, Pointer<_Properties>)>()(
              id, r, _string(a, reason), drain, _propPointer(a, props));
        final fn = kind == 0
            ? _b.api.disconnect
            : kind == 1
                ? _b.api.disconnectWill
                : _b.api.disconnectUnspecified;
        return fn.asFunction<
                int Function(int, int, int, Pointer<_Properties>)>()(
            id, r, drain, _propPointer(a, props));
      });
  Future<void> close() => _close ??= () async {
        _closing = true;
        await control(6);
        final rc = _b.core.release.asFunction<int Function(int)>()(id);
        if (rc != 0) throw _b.error(rc, 6);
        _closed = true;
        _port.close();
        unawaited(_events.close());
      }();
  void _drain() {
    if (_closed) return;
    using((a) {
      final out = a<Pointer<_Event>>();
      for (var i = 0; i < 64; i++) {
        final rc = _b.core.take
            .asFunction<int Function(int, Pointer<Pointer<_Event>>)>()(id, out);
        if (rc <= 0) return;
        final p = out.value;
        try {
          final e = p.ref,
              d = _b.api.details
                  .asFunction<Pointer<_Details> Function(Pointer<_Event>)>()(p)
                  .ref;
          final properties = _readProps(d.properties);
          final acknowledgements =
              List<NativeAck>.unmodifiable(List.generate(d.ackCount, (i) {
            final n = (d.acks + i).ref;
            return NativeAck(n.packetType, n.reason, _readProps(n.properties));
          }));
          Object? error = e.code == 0
              ? null
              : (e.error == nullptr
                  ? _b.error(e.code, e.operation)
                  : errors.decodeNativeException(e.error));
          if (e.code != 0 && d.reason >= 128)
            error = _protocolError?.call(
                    d.packetType, d.reason, properties, acknowledgements) ??
                _b.error(e.code, e.operation);
          final event = NativeEvent(
              e.type,
              e.operation,
              e.value,
              e.flags,
              e.topic == nullptr
                  ? null
                  : utf8
                      .decode(e.topic.cast<Uint8>().asTypedList(e.topicLength)),
              e.payloadLength == 0
                  ? Uint8List(0)
                  : Uint8List.fromList(e.payload.asTypedList(e.payloadLength)),
              d.packetType,
              d.reason,
              d.source,
              d.willRetry != 0,
              properties,
              acknowledgements,
              {
                'timestampMs': e.timestampMs,
                'sequence': e.sequence,
                'connectionCount': e.connectionCount,
                'reconnectCount': e.reconnectCount,
                'retryAttempt': e.retryAttempt,
                'totalRetryAttempts': e.totalRetryAttempts,
                'disconnectedAtMs': e.disconnectedAtMs,
                'downtimeMs': e.downtimeMs,
                'attemptStartedAtMs': e.attemptStartedAtMs,
                'droppedEvents': e.droppedEvents
              },
              error);
          if (e.type == 1) {
            final pending = _pending.remove(e.request);
            if (pending != null) {
              if (error != null)
                pending.completeError(error);
              else
                pending.complete(event);
            }
          } else if (!_closing) _events.add(event);
        } catch (e, s) {
          final pending =
              p.ref.type == 1 ? _pending.remove(p.ref.request) : null;
          if (pending != null) {
            pending.completeError(e, s);
          } else {
            _events.addError(e, s);
          }
        } finally {
          _b.core.free.asFunction<void Function(Pointer<_Event>)>()(p);
        }
      }
      scheduleMicrotask(_drain);
    });
  }
}
