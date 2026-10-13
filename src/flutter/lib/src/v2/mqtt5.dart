import '../debug.dart';
import 'dart:async';
import 'dart:typed_data';
import '../../common.dart';
import 'native.dart';

enum MqttCleanStartPolicy { always, firstConnection, never }

enum MqttPayloadFormat { unspecified, utf8 }

enum MqttRetainHandling { always, onlyIfNew, never }

/// 连接断开的来源，不代表 Broker 是否确认客户端的操作。
enum MqttDisconnectSource {
  /// 客户端主动断开。
  local,

  /// 实际收到 Broker 发来的 DISCONNECT。
  server,

  /// 传输连接丢失，没有收到服务端 DISCONNECT。
  transport
}

final class MqttSessionOptions {
  const MqttSessionOptions(
      {this.cleanStart = MqttCleanStartPolicy.always,
      this.expiryIntervalSeconds = 0});
  final MqttCleanStartPolicy cleanStart;
  final int expiryIntervalSeconds;

  @override
  String toString() => mqttDebugString('MqttSessionOptions', {
        'cleanStart': cleanStart,
        'expiryIntervalSeconds': expiryIntervalSeconds,
      });
}

List<PropertyValue> _users(List<MqttUserProperty> values) =>
    values.map((p) => PropertyValue(38, p.name, p.value)).toList();

final class MqttConnectProperties {
  const MqttConnectProperties(
      {this.requestResponseInformation = false,
      this.requestProblemInformation = true,
      this.maximumPacketSize,
      this.userProperties = const []});
  final bool requestResponseInformation, requestProblemInformation;
  final int? maximumPacketSize;
  final List<MqttUserProperty> userProperties;
  List<PropertyValue> _toNative() => [
        PropertyValue(25, requestResponseInformation ? 1 : 0),
        PropertyValue(23, requestProblemInformation ? 1 : 0),
        if (maximumPacketSize != null) PropertyValue(39, maximumPacketSize!),
        ..._users(userProperties)
      ];

  @override
  String toString() => mqttDebugString('MqttConnectProperties', {
        'requestResponseInformation': requestResponseInformation,
        'requestProblemInformation': requestProblemInformation,
        'maximumPacketSize': maximumPacketSize,
        'userProperties': userProperties,
      });
}

final class MqttPublishProperties {
  const MqttPublishProperties(
      {this.responseTopic,
      this.correlationData,
      this.messageExpiryIntervalSeconds,
      this.contentType,
      this.payloadFormat,
      this.userProperties = const []});
  final String? responseTopic, contentType;
  final Uint8List? correlationData;
  final int? messageExpiryIntervalSeconds;
  final MqttPayloadFormat? payloadFormat;
  final List<MqttUserProperty> userProperties;
  List<PropertyValue> _toNative() => [
        if (responseTopic != null) PropertyValue(8, responseTopic!),
        if (correlationData != null) PropertyValue(9, correlationData!),
        if (messageExpiryIntervalSeconds != null)
          PropertyValue(2, messageExpiryIntervalSeconds!),
        if (contentType != null) PropertyValue(3, contentType!),
        if (payloadFormat != null) PropertyValue(1, payloadFormat!.index),
        ..._users(userProperties)
      ];

  @override
  String toString() => mqttDebugString('MqttPublishProperties', {
        'responseTopic': responseTopic,
        'correlationData': correlationData,
        'messageExpiryIntervalSeconds': messageExpiryIntervalSeconds,
        'contentType': contentType,
        'payloadFormat': payloadFormat,
        'userProperties': userProperties,
      });
}

final class MqttWillOptions {
  const MqttWillOptions(
      {required this.topic,
      required this.payload,
      this.qos = MqttQos.atMostOnce,
      this.retained = false,
      this.delayIntervalSeconds = 0,
      this.properties = const MqttPublishProperties()});
  final String topic;
  final Uint8List payload;
  final MqttQos qos;
  final bool retained;
  final int delayIntervalSeconds;
  final MqttPublishProperties properties;

  @override
  String toString() => mqttDebugString('MqttWillOptions', {
        'topic': topic,
        'payload': payload,
        'qos': qos,
        'retained': retained,
        'properties': properties,
        'delayIntervalSeconds': delayIntervalSeconds,
      });
}

final class MqttOptions {
  const MqttOptions(
      {required this.serverUri,
      required this.clientId,
      this.credentials = const MqttCredentials(),
      this.tls = const MqttTlsOptions(),
      this.queueLimits = const MqttQueueLimits(),
      this.persistence,
      this.keepAliveSeconds = 60,
      this.connectTimeoutSeconds = 30,
      this.automaticReconnect = false,
      this.minRetrySeconds = 1,
      this.maxRetrySeconds = 60,
      this.session = const MqttSessionOptions(),
      this.connectProperties = const MqttConnectProperties(),
      this.will});
  final String serverUri, clientId;
  final MqttCredentials credentials;
  final MqttTlsOptions tls;
  final MqttQueueLimits queueLimits;
  final MqttPersistenceOptions? persistence;
  final int keepAliveSeconds,
      connectTimeoutSeconds,
      minRetrySeconds,
      maxRetrySeconds;
  final bool automaticReconnect;
  final MqttSessionOptions session;
  final MqttConnectProperties connectProperties;
  final MqttWillOptions? will;
  NativeOptions _toNative() => NativeOptions(
      protocol: 5,
      protocolError: MqttProtocolException._native,
      serverUri: serverUri,
      clientId: clientId,
      credentials: credentials,
      tls: tls,
      limits: queueLimits,
      persistence: persistence,
      keepAlive: keepAliveSeconds,
      timeout: connectTimeoutSeconds,
      reconnect: automaticReconnect,
      minRetry: minRetrySeconds,
      maxRetry: maxRetrySeconds,
      cleanPolicy: session.cleanStart.index,
      sessionExpiry: session.expiryIntervalSeconds,
      properties: connectProperties._toNative(),
      willTopic: will?.topic,
      willPayload: will?.payload,
      willQos: will?.qos.index ?? 0,
      willRetained: will?.retained ?? false,
      willProperties: will == null
          ? const []
          : [
              PropertyValue(24, will!.delayIntervalSeconds),
              ...will!.properties._toNative()
            ]);

  @override
  String toString() => mqttDebugString('MqttOptions', {
        'serverUri': mqttDebugServerUri(serverUri),
        'clientId': clientId,
        'credentials': credentials,
        'tls': tls,
        'queueLimits': queueLimits,
        'persistence': persistence,
        'keepAliveSeconds': keepAliveSeconds,
        'connectTimeoutSeconds': connectTimeoutSeconds,
        'automaticReconnect': automaticReconnect,
        'minRetrySeconds': minRetrySeconds,
        'maxRetrySeconds': maxRetrySeconds,
        'will': will,
        'session': session,
        'connectProperties': connectProperties,
      });
}

// Wire IDs and untyped values never form part of the public API.
abstract class _PropertySnapshot {
  _PropertySnapshot(List<PropertyValue> values)
      : _values = List.unmodifiable(values);
  final List<PropertyValue> _values;
  T? _get<T>(int id) {
    for (final v in _values) {
      if (v.id == id) return v.value as T;
    }
    return null;
  }

  int? _number(int id) => _get<int>(id);
  List<MqttUserProperty> get userProperties => List.unmodifiable(_values
      .where((v) => v.id == 38)
      .map((v) => MqttUserProperty(v.value as String, v.second!)));
}

/// Decoded properties received on a PUBLISH. Absent properties remain null.
final class MqttReceivedPublishProperties extends _PropertySnapshot {
  MqttReceivedPublishProperties._(super.values);
  String? get responseTopic => _get<String>(8);
  Uint8List? get correlationData => _get<Uint8List>(9);
  String? get contentType => _get<String>(3);
  int? get messageExpiryIntervalSeconds => _number(2);
  MqttPayloadFormat? get payloadFormat =>
      _number(1) == null ? null : MqttPayloadFormat.values[_number(1)!];
  List<int> get subscriptionIdentifiers => List.unmodifiable(
      _values.where((v) => v.id == 11).map((v) => v.value as int));

  @override
  String toString() => mqttDebugString('MqttReceivedPublishProperties', {
        'responseTopic': responseTopic,
        'correlationData': correlationData,
        'contentType': contentType,
        'messageExpiryIntervalSeconds': messageExpiryIntervalSeconds,
        'payloadFormat': payloadFormat,
        'subscriptionIdentifiers': subscriptionIdentifiers,
        'userProperties': userProperties,
      });
}

/// Typed broker response properties, including those attached to a refusal.
/// Pattern match the concrete type for packet-specific fields.
sealed class MqttResponseProperties extends _PropertySnapshot {
  MqttResponseProperties._(super.values);
  String? get reasonString => _get<String>(31);
}

/// PUBACK, PUBREC, PUBCOMP, SUBACK and UNSUBACK share these properties.
final class MqttAcknowledgementProperties extends MqttResponseProperties {
  MqttAcknowledgementProperties._(super.values) : super._();

  @override
  String toString() => mqttDebugString('MqttAcknowledgementProperties', {
        'reasonString': reasonString,
        'userProperties': userProperties,
      });
}

/// Broker 在这次 CONNACK 中实际返回的解码属性快照。
///
/// 可选属性未出现时保留 null，不自动填入客户端配置或协议默认值；例如
/// [serverKeepAliveSeconds] 为 null 表示 Broker 没有覆盖客户端的 Keep Alive，
/// 并不表示禁用心跳。显式返回的 0、false 和空字符串与未返回属性不同。
/// User Property 未出现时为一个空列表，出现时保留顺序和重复键。
///
/// 用于检查 Broker 的原始响应，也可随连接拒绝事件交付。成功连接的有效参数
/// 见 [MqttConnectionEstablished.settings]，类型为 [MqttNegotiatedSettings]。
final class MqttConnackProperties extends MqttResponseProperties {
  MqttConnackProperties._(super.values) : super._();
  String? get responseInformation => _get<String>(26);
  String? get assignedClientIdentifier => _get<String>(18);
  String? get serverReference => _get<String>(28);
  String? get authenticationMethod => _get<String>(21);
  Uint8List? get authenticationData => _get<Uint8List>(22);
  int? get sessionExpiryIntervalSeconds => _number(17);
  int? get serverKeepAliveSeconds => _number(19);
  int? get receiveMaximum => _number(33);
  int? get maximumPacketSize => _number(39);
  MqttQos? get maximumQos =>
      _number(36) == null ? null : MqttQos.values[_number(36)!];
  bool? _bool(int id) => _number(id) == null ? null : _number(id) != 0;
  bool? get retainAvailable => _bool(37);
  bool? get wildcardSubscriptionAvailable => _bool(40);
  bool? get subscriptionIdentifierAvailable => _bool(41);
  bool? get sharedSubscriptionAvailable => _bool(42);
  int? get topicAliasMaximum => _number(34);

  @override
  String toString() => mqttDebugString('MqttConnackProperties', {
        'reasonString': reasonString,
        'userProperties': userProperties,
        'responseInformation': responseInformation,
        'assignedClientIdentifier': assignedClientIdentifier,
        'serverReference': serverReference,
        'authenticationMethod': authenticationMethod,
        'authenticationData': mqttDebugSecret(authenticationData),
        'sessionExpiryIntervalSeconds': sessionExpiryIntervalSeconds,
        'serverKeepAliveSeconds': serverKeepAliveSeconds,
        'receiveMaximum': receiveMaximum,
        'maximumPacketSize': maximumPacketSize,
        'maximumQos': maximumQos,
        'retainAvailable': retainAvailable,
        'wildcardSubscriptionAvailable': wildcardSubscriptionAvailable,
        'subscriptionIdentifierAvailable': subscriptionIdentifierAvailable,
        'sharedSubscriptionAvailable': sharedSubscriptionAvailable,
        'topicAliasMaximum': topicAliasMaximum,
      });
}

/// Properties actually received in a server DISCONNECT.
final class MqttReceivedDisconnectProperties extends MqttResponseProperties {
  MqttReceivedDisconnectProperties._(super.values) : super._();
  String? get serverReference => _get<String>(28);
  int? get sessionExpiryIntervalSeconds => _number(17);

  @override
  String toString() => mqttDebugString('MqttReceivedDisconnectProperties', {
        'reasonString': reasonString,
        'userProperties': userProperties,
        'serverReference': serverReference,
        'sessionExpiryIntervalSeconds': sessionExpiryIntervalSeconds,
      });
}

/// Broker refusal with owned, typed protocol snapshots.
final class MqttProtocolException implements Exception {
  const MqttProtocolException._(
      this.packetType, this.reasonCode, this.properties,
      {this.acknowledgements = const [],
      this.subscribeResult,
      this.unsubscribeResult});
  factory MqttProtocolException._native(int packet, int reason,
          List<PropertyValue> properties, List<NativeAck> acks) =>
      MqttProtocolException._(
          packet,
          reason,
          switch (packet) {
            2 => MqttConnackProperties._(properties),
            4 ||
            5 ||
            7 ||
            9 ||
            11 =>
              MqttAcknowledgementProperties._(properties),
            14 => MqttReceivedDisconnectProperties._(properties),
            _ => throw StateError('Unexpected refusal packet: $packet'),
          },
          acknowledgements:
              List.unmodifiable(acks.map(MqttPublishAcknowledgement._)));

  /// MQTT control packet type and raw broker reason code, retained for diagnostics.
  final int packetType, reasonCode;
  final MqttResponseProperties properties;
  final List<MqttPublishAcknowledgement> acknowledgements;

  /// Complete batch result when requireAllAccepted() rejects an entry.
  final MqttSubscribeResult? subscribeResult;

  /// Complete batch result when requireAllSucceeded() rejects an entry.
  final MqttUnsubscribeResult? unsubscribeResult;

  @override
  String toString() => mqttDebugString('MqttProtocolException', {
        'packetType': packetType,
        'reasonCode': reasonCode,
        'properties': properties,
        'acknowledgements': acknowledgements,
        'subscribeResult': subscribeResult,
        'unsubscribeResult': unsubscribeResult,
      });
}

/// 本次成功连接的有效参数快照，结合 CONNACK、客户端配置和协议默认值计算。
///
/// 与 [MqttConnackProperties] 保留 Broker 实际返回值不同，本类型的字段已解析
/// 缺省值，可直接用于了解当前连接的参数和服务端能力。“Negotiated”也包括服务端
/// 单方面声明的限制和协议默认值，不表示这些字段都经过双方协商。
///
/// 例如客户端配置 keepAliveSeconds 为 60，CONNACK 未包含 Server Keep Alive 时，
/// properties.serverKeepAliveSeconds 为 null，本对象的 [keepAliveSeconds] 为 60；
/// 若 Broker 返回 30，则两者均为 30。
///
/// 每次成功连接（包括重连）都会产生新的快照；旧事件中的快照不会被更新。
/// server 前缀的字段表示 Broker 的接收限制或支持能力，不代表客户端的接收限制，
/// 也不替代客户端本地队列限制。它们不是当前剩余配额。
final class MqttNegotiatedSettings {
  MqttNegotiatedSettings._(MqttOptions options, MqttConnackProperties p)
      : keepAliveSeconds = p.serverKeepAliveSeconds ?? options.keepAliveSeconds,
        sessionExpiryIntervalSeconds = p.sessionExpiryIntervalSeconds ??
            options.session.expiryIntervalSeconds,
        serverReceiveMaximum = p.receiveMaximum ?? 65535,
        serverMaximumPacketSizeBytes = p.maximumPacketSize ?? 268435460,
        serverMaximumQos = p.maximumQos ?? MqttQos.exactlyOnce,
        serverRetainAvailable = p.retainAvailable ?? true,
        serverWildcardSubscriptionAvailable =
            p.wildcardSubscriptionAvailable ?? true,
        serverSubscriptionIdentifierAvailable =
            p.subscriptionIdentifierAvailable ?? true,
        serverSharedSubscriptionAvailable =
            p.sharedSubscriptionAvailable ?? true;

  /// 优先使用 CONNACK 的 Server Keep Alive，否则使用客户端 keepAliveSeconds。
  /// 单位为秒；0 表示禁用 MQTT Keep Alive。
  final int keepAliveSeconds;

  /// 优先使用 CONNACK 的 Session Expiry Interval，否则使用客户端会话配置值。
  /// 单位为秒；0 表示连接结束时会话过期，0xffffffff 表示会话不过期。
  final int sessionExpiryIntervalSeconds;

  /// Broker 允许客户端同时在途的 QoS 1/2 发布数量上限，不限制 QoS 0。
  /// CONNACK 未提供 Receive Maximum 时，协议默认值为 65535。
  final int serverReceiveMaximum;

  /// 客户端向 Broker 发送的完整 MQTT 报文大小上限，包含报文头和属性，不只是 payload。
  /// 单位为字节。CONNACK 未提供时使用 MQTT 报文理论上限 268435460。
  final int serverMaximumPacketSizeBytes;

  /// Broker 接受的发布 QoS 上限。CONNACK 未提供 Maximum QoS 时默认为 QoS 2。
  /// 此字段不代表某次订阅实际获准的 QoS。
  final MqttQos serverMaximumQos;

  /// Broker 是否支持保留消息。CONNACK 未提供 Retain Available 时默认为 true。
  final bool serverRetainAvailable;

  /// Broker 是否支持通配符订阅。CONNACK 未提供该属性时默认为 true。
  final bool serverWildcardSubscriptionAvailable;

  /// Broker 是否支持订阅标识符。CONNACK 未提供该属性时默认为 true。
  final bool serverSubscriptionIdentifierAvailable;

  /// Broker 是否支持共享订阅。CONNACK 未提供该属性时默认为 true。
  final bool serverSharedSubscriptionAvailable;

  @override
  String toString() => mqttDebugString('MqttNegotiatedSettings', {
        'keepAliveSeconds': keepAliveSeconds,
        'sessionExpiryIntervalSeconds': sessionExpiryIntervalSeconds,
        'serverReceiveMaximum': serverReceiveMaximum,
        'serverMaximumPacketSizeBytes': serverMaximumPacketSizeBytes,
        'serverMaximumQos': serverMaximumQos,
        'serverRetainAvailable': serverRetainAvailable,
        'serverWildcardSubscriptionAvailable':
            serverWildcardSubscriptionAvailable,
        'serverSubscriptionIdentifierAvailable':
            serverSubscriptionIdentifierAvailable,
        'serverSharedSubscriptionAvailable': serverSharedSubscriptionAvailable,
      });
}

final class MqttReasonCode {
  const MqttReasonCode(this.rawValue);
  final int rawValue;
  bool get isFailure => rawValue >= 128;
  @override
  String toString() => '0x${rawValue.toRadixString(16).padLeft(2, '0')}';
}

final class MqttPublishAcknowledgement {
  MqttPublishAcknowledgement._(NativeAck a)
      : packetType = a.packetType,
        reasonCode = MqttReasonCode(a.reason),
        properties = MqttAcknowledgementProperties._(a.properties);
  final int packetType;
  final MqttReasonCode reasonCode;
  final MqttAcknowledgementProperties properties;

  @override
  String toString() => mqttDebugString('MqttPublishAcknowledgement', {
        'packetType': packetType,
        'reasonCode': reasonCode,
        'properties': properties,
      });
}

/// Successful QoS 1 exchange with the broker, not subscriber delivery.
final class MqttQos1PublishResult {
  MqttQos1PublishResult._(NativeEvent event)
      : puback = MqttPublishAcknowledgement._(
            event.acks.singleWhere((ack) => ack.packetType == 4));
  final MqttPublishAcknowledgement puback;

  @override
  String toString() => mqttDebugString('MqttQos1PublishResult', {
        'puback': puback,
      });
}

/// Successful QoS 2 exchange, retaining both broker acknowledgement snapshots.
final class MqttQos2PublishResult {
  MqttQos2PublishResult._(NativeEvent event)
      : pubrec = MqttPublishAcknowledgement._(
            event.acks.singleWhere((ack) => ack.packetType == 5)),
        pubcomp = MqttPublishAcknowledgement._(
            event.acks.singleWhere((ack) => ack.packetType == 7));
  final MqttPublishAcknowledgement pubrec;
  final MqttPublishAcknowledgement pubcomp;

  @override
  String toString() => mqttDebugString('MqttQos2PublishResult', {
        'pubrec': pubrec,
        'pubcomp': pubcomp,
      });
}

final class MqttSubscription {
  const MqttSubscription(this.topicFilter,
      {this.qos = MqttQos.atLeastOnce,
      this.noLocal = false,
      this.retainAsPublished = false,
      this.retainHandling = MqttRetainHandling.always});
  final String topicFilter;
  final MqttQos qos;
  final bool noLocal, retainAsPublished;
  final MqttRetainHandling retainHandling;
  NativeSubscription _toNative() => NativeSubscription(
      topicFilter, qos.index, noLocal, retainAsPublished, retainHandling.index);

  @override
  String toString() => mqttDebugString('MqttSubscription', {
        'topicFilter': topicFilter,
        'qos': qos,
        'noLocal': noLocal,
        'retainAsPublished': retainAsPublished,
        'retainHandling': retainHandling,
      });
}

final class MqttSubscribeProperties {
  const MqttSubscribeProperties(
      {this.subscriptionIdentifier, this.userProperties = const []});
  final int? subscriptionIdentifier;
  final List<MqttUserProperty> userProperties;
  List<PropertyValue> _toNative() => [
        if (subscriptionIdentifier != null)
          PropertyValue(11, subscriptionIdentifier!),
        ..._users(userProperties)
      ];

  @override
  String toString() => mqttDebugString('MqttSubscribeProperties', {
        'subscriptionIdentifier': subscriptionIdentifier,
        'userProperties': userProperties,
      });
}

final class MqttUnsubscribeProperties {
  const MqttUnsubscribeProperties({this.userProperties = const []});
  final List<MqttUserProperty> userProperties;

  @override
  String toString() => mqttDebugString('MqttUnsubscribeProperties', {
        'userProperties': userProperties,
      });
}

final class MqttSubscriptionResult {
  MqttSubscriptionResult._(this.topicFilter, this.requestedQos, int reason)
      : reasonCode = MqttReasonCode(reason);
  final String topicFilter;
  final MqttQos requestedQos;
  final MqttReasonCode reasonCode;
  bool get accepted => reasonCode.rawValue >= 0 && reasonCode.rawValue <= 2;
  MqttQos? get grantedQos =>
      accepted ? MqttQos.values[reasonCode.rawValue] : null;

  @override
  String toString() => mqttDebugString('MqttSubscriptionResult', {
        'topicFilter': topicFilter,
        'requestedQos': requestedQos,
        'accepted': accepted,
        'grantedQos': grantedQos,
        'reasonCode': reasonCode,
      });
}

final class MqttSubscribeResult {
  MqttSubscribeResult._(this.entries, this.properties);
  final List<MqttSubscriptionResult> entries;
  final MqttAcknowledgementProperties properties;
  void requireAllAccepted() {
    for (final e in entries) {
      if (!e.accepted)
        throw MqttProtocolException._(9, e.reasonCode.rawValue, properties,
            subscribeResult: this);
    }
  }

  @override
  String toString() => mqttDebugString('MqttSubscribeResult', {
        'entries': entries,
        'properties': properties,
      });
}

final class MqttUnsubscriptionResult {
  MqttUnsubscriptionResult._(this.topicFilter, int reason)
      : reasonCode = MqttReasonCode(reason);
  final String topicFilter;
  final MqttReasonCode reasonCode;
  bool get succeeded => !reasonCode.isFailure;

  @override
  String toString() => mqttDebugString('MqttUnsubscriptionResult', {
        'topicFilter': topicFilter,
        'reasonCode': reasonCode,
        'succeeded': succeeded,
      });
}

final class MqttUnsubscribeResult {
  MqttUnsubscribeResult._(this.entries, this.properties);
  final List<MqttUnsubscriptionResult> entries;
  final MqttAcknowledgementProperties properties;
  void requireAllSucceeded() {
    for (final e in entries) {
      if (!e.succeeded)
        throw MqttProtocolException._(11, e.reasonCode.rawValue, properties,
            unsubscribeResult: this);
    }
  }

  @override
  String toString() => mqttDebugString('MqttUnsubscribeResult', {
        'entries': entries,
        'properties': properties,
      });
}

final class MqttDisconnectProperties {
  const MqttDisconnectProperties(
      {this.sessionExpiryIntervalSeconds, this.userProperties = const []});
  final int? sessionExpiryIntervalSeconds;
  final List<MqttUserProperty> userProperties;
  List<PropertyValue> _toNative() => [
        if (sessionExpiryIntervalSeconds != null)
          PropertyValue(17, sessionExpiryIntervalSeconds!),
        ..._users(userProperties)
      ];

  @override
  String toString() => mqttDebugString('MqttDisconnectProperties', {
        'sessionExpiryIntervalSeconds': sessionExpiryIntervalSeconds,
        'userProperties': userProperties,
      });
}

sealed class MqttEvent {
  const MqttEvent._();
}

/// 收到 Broker 转发的一条 PUBLISH 消息。
///
/// [qos]、[retained] 和 [duplicate] 描述 Broker 到本客户端这一跳的报文，
/// 不一定等于发布方发送时的值。duplicate 是 MQTT DUP 标志，不是业务去重结果；
/// 即使为 false，也不能据此断定业务消息从未处理过。
///
/// [payload] 是已复制到 Dart 的二进制数据，不假定 UTF-8，也不依赖原生回调的生命周期。
/// 业务可以在回调后保存它，但该字节数组仍可修改。MQTT ACK 由底层处理，
/// 监听回调返回或抛错均不构成业务 ACK，也不能用来拒收或要求 Broker 重投。
/// 串行回调中不要等待依赖后续事件才能完成的业务响应，详见 [MqttEventListener]。
///
/// [properties] 是这条入站消息的属性，包含响应 Topic、关联数据等；SDK 不自动应答。
final class MqttMessage extends MqttEvent {
  MqttMessage._(NativeEvent e)
      : topic = e.topic!,
        payload = e.payload,
        qos = MqttQos.values[e.value],
        retained = e.flags & 1 != 0,
        duplicate = e.flags & 2 != 0,
        properties = MqttReceivedPublishProperties._(e.properties),
        super._();

  /// 收到消息的具体 Topic 名称，不是订阅时的 filter。
  final String topic;

  /// 原生数据的独立副本；可以保存到回调之后，但字节数组本身可修改。
  final Uint8List payload;

  /// Broker 到本客户端这一跳实际使用的 QoS。
  final MqttQos qos;

  /// 收到 PUBLISH 报文的 RETAIN 标志，不用于判断消息是否已经过期。
  final bool retained;

  /// 收到 PUBLISH 报文的 DUP 标志，不能替代业务幂等或去重。
  final bool duplicate;
  final MqttReceivedPublishProperties properties;

  @override
  String toString() => mqttDebugString('MqttMessage', {
        'topic': topic,
        'payload': payload,
        'qos': qos,
        'retained': retained,
        'duplicate': duplicate,
        'properties': properties,
      });
}

/// 一个连接状态事件发生时的历史快照，不是持续更新的客户端状态。
///
/// 所有计数均限定于当前 MqttClient 实例，重新创建实例后从零开始；
/// 不随 Broker 会话持久化，也不跨实例累计。成功次数、重试次数和事件序号是不同维度。
/// 时间字段中的 timestamp/At 使用 Unix epoch 毫秒，耗时使用单调时钟毫秒。
sealed class MqttConnectionEvent extends MqttEvent {
  MqttConnectionEvent._(NativeEvent e)
      : _history = Map.unmodifiable(e.history),
        automatic = e.flags & 4 != 0,
        super._();
  final Map<String, int> _history;

  /// 本次连接尝试是否由 SDK 自动重试发起；手动启动为 false。
  /// 断开事件固定为 false，不表示是否将自动恢复；后续重试计划见 willRetry。
  final bool automatic;

  /// 原生层产生该事件的 Unix epoch 毫秒时间，不是 Dart 回调开始执行的时间。
  /// 可能受系统校时影响；不要用两个 timestamp 相减代替单调耗时。
  int get timestampMs => _history['timestampMs']!;

  /// 本实例连接状态事件的累计序号，从 1 开始；不包含消息和操作结果事件。
  /// 原生层分配失败或队列淘汰可造成跳号，不能假定收到的事件总是连续编号。
  int get sequence => _history['sequence']!;

  /// 本实例成功建立 MQTT 连接的累计次数，仅收到成功 CONNACK 时增加。
  /// 首次成功为 1，下一次成功为 2；失败尝试不增加。首次成功前失败事件中为 0。
  /// 与 Broker 是否恢复会话无关，不能用它替代 sessionPresent。
  int get connectionCount => _history['connectionCount']!;

  /// 本实例首次成功之后，再次成功建立连接的累计次数。
  /// 等于 max(connectionCount - 1, 0)；包括手动和自动恢复的成功连接，不统计失败尝试。
  int get reconnectCount => _history['reconnectCount']!;

  /// 当前恢复周期已发起的重试次数，也作为最近一次重试的序号；首次手动尝试为 0。
  /// 开始一次重试时加 1，包含自动重试及后续手动启动；失败事件和成功事件保留该值。
  /// 成功本身不清零；网络断开、主动断开及收到服务端 DISCONNECT 时清零，
  /// 下一次重试从 1 开始。
  /// 这是尝试计数，不是失败次数：一次成功的重试也计入其中。
  int get retryAttempt => _history['retryAttempt']!;

  /// 本实例已发起的重试总次数；首次手动尝试不计入，后续手动和自动尝试均计入。
  /// 与 retryAttempt 同时递增，但断开或成功连接均不清零；仅新建客户端实例重新计数。
  /// 不等于 reconnectCount：例如三次重试只有最后一次成功，本字段增加 3，成功次数增加 1。
  int get totalRetryAttempts => _history['totalRetryAttempts']!;

  /// 从当前恢复起点到该事件产生时的单调耗时，单位毫秒。
  /// 首次连接从首次尝试开始计时，之后从最近一次断开开始；包括重试退避等待，
  /// 不只是本次 TCP/TLS/MQTT 握手耗时。在成功事件上表示此次建立或恢复连接总耗时。
  /// 尚无计时起点时为 0；不是客户端整个生命周期的累计离线时长。
  int get downtimeMs => _history['downtimeMs']!;

  /// 原生层累计未能保留的连接状态事件数，例如分配失败或状态队列满时淘汰旧事件。
  /// 此值是产生当前事件时的快照；增加表示连接历史可能不完整。
  /// 不统计 MQTT 消息丢失、业务回调异常或 Dart 监听队列溢出。
  int get droppedEvents => _history['droppedEvents']!;

  /// 最近一次记录断开的 Unix epoch 毫秒时间；从未记录断开时为 null。
  /// 恢复成功事件仍保留此前的断开时间，因此非 null 不表示此刻仍处于断开状态。
  int? get disconnectedAtMs =>
      _history['disconnectedAtMs'] == 0 ? null : _history['disconnectedAtMs'];

  /// 本次连接尝试开始的 Unix epoch 毫秒时间；尝试开始、失败和成功事件可关联同一时间。
  /// 断开事件不对应建连尝试，因此为 null；它不是“下次计划重试时间”。
  int? get attemptStartedAtMs => _history['attemptStartedAtMs'] == 0
      ? null
      : _history['attemptStartedAtMs'];
}

sealed class MqttConnectionEstablished extends MqttConnectionEvent {
  MqttConnectionEstablished._(NativeEvent e, MqttOptions o)
      : sessionPresent = e.value == 1,
        properties = MqttConnackProperties._(e.properties),
        settings =
            MqttNegotiatedSettings._(o, MqttConnackProperties._(e.properties)),
        super._(e);

  /// 本次成功 CONNACK 的 Session Present：Broker 是否恢复了已有会话。
  /// 与此客户端实例是否首次连接无关；false 时应用按需重新订阅。
  final bool sessionPresent;

  /// 本次 CONNACK 实际返回的属性；未返回的可选字段保留 null，不填入默认值。
  final MqttConnackProperties properties;

  /// 本次连接的有效参数，已应用客户端配置和协议默认值；重连成功后会重新计算。
  /// 若需要区分 Broker 显式返回与省略某属性，请读取 [properties]。
  final MqttNegotiatedSettings settings;
}

/// 当前 MqttClient 实例首次成功建立 MQTT 连接，已收到成功 CONNACK。
///
/// 此前即使发生过多次连接失败和自动重试，第一次成功仍是本事件，
/// 此时 [automatic] 也可能为 true。后续成功连接使用 [MqttReconnected]；
/// 重新创建客户端后计数重新开始，因此新实例恢复旧会话也会收到本事件。
///
/// [sessionPresent] 表示 Broker 是否恢复已有会话，不表示这是首次还是重连。
/// startConnecting 的 Future 只表示启动受理，业务应以本事件确认首次连接成功。
/// 事件是发生时的快照，回调执行前连接仍可能再次断开，后续操作也需处理失败。
///
/// [properties] 保留本次 CONNACK 实际属性；[settings] 提供已解析默认值的有效参数。
final class MqttConnected extends MqttConnectionEstablished {
  MqttConnected._(super.e, super.o) : super._();

  @override
  String toString() => mqttDebugString('MqttConnected', {
        'automatic': automatic,
        'timestampMs': timestampMs,
        'sequence': sequence,
        'connectionCount': connectionCount,
        'reconnectCount': reconnectCount,
        'retryAttempt': retryAttempt,
        'totalRetryAttempts': totalRetryAttempts,
        'downtimeMs': downtimeMs,
        'droppedEvents': droppedEvents,
        'disconnectedAtMs': disconnectedAtMs,
        'attemptStartedAtMs': attemptStartedAtMs,
        'sessionPresent': sessionPresent,
        'properties': properties,
        'settings': settings,
      });
}

/// 当前 MqttClient 实例曾成功连接过，现在再次收到成功 CONNACK。
///
/// 既包括自动恢复连接，也包括主动断开后使用同一实例手动重新连接；
/// 通过 [automatic] 区分本次尝试的来源，不能仅凭事件名称判断是自动重连。
/// 若此前从未连接成功，自动重试后的首次成功仍是 [MqttConnected]。
///
/// 重新连接成功不等于恢复了 Broker 会话；应检查 [sessionPresent]。
/// 为 false 时，应用按业务需要重新订阅，SDK 不自动补订阅。
/// 不要把本事件解释为此前在途发布已全部完成，应分别等待它们的 Future。
///
/// [properties] 和 [settings] 来自这次连接，请重新读取；Broker 的限制可能已改变。
final class MqttReconnected extends MqttConnectionEstablished {
  MqttReconnected._(super.e, super.o) : super._();

  @override
  String toString() => mqttDebugString('MqttReconnected', {
        'automatic': automatic,
        'timestampMs': timestampMs,
        'sequence': sequence,
        'connectionCount': connectionCount,
        'reconnectCount': reconnectCount,
        'retryAttempt': retryAttempt,
        'totalRetryAttempts': totalRetryAttempts,
        'downtimeMs': downtimeMs,
        'droppedEvents': droppedEvents,
        'disconnectedAtMs': disconnectedAtMs,
        'attemptStartedAtMs': attemptStartedAtMs,
        'sessionPresent': sessionPresent,
        'properties': properties,
        'settings': settings,
      });
}

/// SDK 开始一次再次连接尝试，此时尚未确认 MQTT 连接成功。
///
/// 包括首次连接失败后的自动重试、连接丢失后的自动重试，以及已有尝试后
/// 由应用重新调用 startConnecting 发起的手动尝试；首次手动尝试不发本事件。
/// [automatic] 表示本次尝试是否自动发起，[retryAttempt] 表示当前恢复周期的重试次数。
///
/// 该事件不是成功通知，也不表示 SDK 正在等待退避定时器。
/// 后续结果可能是 [MqttConnected]、[MqttReconnected]、[MqttConnectFailed]
/// 或 [MqttReconnectFailed]。不要在这里重复启动连接或把它当作可以发布的信号。
final class MqttReconnecting extends MqttConnectionEvent {
  MqttReconnecting._(super.e) : super._();

  @override
  String toString() => mqttDebugString('MqttReconnecting', {
        'automatic': automatic,
        'timestampMs': timestampMs,
        'sequence': sequence,
        'connectionCount': connectionCount,
        'reconnectCount': reconnectCount,
        'retryAttempt': retryAttempt,
        'totalRetryAttempts': totalRetryAttempts,
        'downtimeMs': downtimeMs,
        'droppedEvents': droppedEvents,
        'disconnectedAtMs': disconnectedAtMs,
        'attemptStartedAtMs': attemptStartedAtMs,
      });
}

sealed class MqttConnectionFailure extends MqttConnectionEvent {
  MqttConnectionFailure._(NativeEvent e)
      : willRetry = e.willRetry,
        error = e.error ?? StateError('Connection failed'),
        properties =
            e.packetType == 2 ? MqttConnackProperties._(e.properties) : null,
        reasonCode = e.packetType == 2 ? MqttReasonCode(e.reason) : null,
        super._(e);

  /// 本次尝试的错误诊断；不是 startConnecting 启动受理阶段的异常。
  final Object error;

  /// 事件产生时 SDK 是否计划继续自动重试；关闭客户端可取消该计划。
  final bool willRetry;

  /// 拒绝 CONNACK 的实际属性；未收到 CONNACK 时为 null。
  final MqttConnackProperties? properties;

  /// 拒绝 CONNACK 的实际原因码；DNS/TCP/TLS 等失败时为 null。
  final MqttReasonCode? reasonCode;
}

/// 一次连接尝试失败，且当前 MqttClient 实例尚未成功连接过。
///
/// 首次尝试失败和首次成功前的所有重试失败均使用此事件，不会因第二次尝试
/// 就改成 [MqttReconnectFailed]。通过 [error] 获取本次失败的实际诊断。
///
/// [willRetry] 表示事件产生时 SDK 是否计划继续自动重试，不保证将来必然重试或成功；
/// 应用随后 disconnect/close 可以取消重试。为 true 时不要再启动一套业务重连循环。
/// 启动受理阶段的参数或状态错误直接由 startConnecting 的 Future 抛出，
/// 不保证产生本事件。
///
/// 仅收到拒绝 CONNACK 时 [reasonCode] 和 [properties] 有值；DNS、TCP、TLS 等
/// 尚未收到 CONNACK 的失败不伪造 Broker 属性，详细原因从 [error] 读取。
final class MqttConnectFailed extends MqttConnectionFailure {
  MqttConnectFailed._(super.e) : super._();

  @override
  String toString() => mqttDebugString('MqttConnectFailed', {
        'automatic': automatic,
        'timestampMs': timestampMs,
        'sequence': sequence,
        'connectionCount': connectionCount,
        'reconnectCount': reconnectCount,
        'retryAttempt': retryAttempt,
        'totalRetryAttempts': totalRetryAttempts,
        'downtimeMs': downtimeMs,
        'droppedEvents': droppedEvents,
        'disconnectedAtMs': disconnectedAtMs,
        'attemptStartedAtMs': attemptStartedAtMs,
        'willRetry': willRetry,
        'error': error,
        'properties': properties,
        'reasonCode': reasonCode,
      });
}

/// 一次再次连接尝试失败，且当前 MqttClient 实例以前成功连接过。
///
/// 与 [MqttConnectFailed] 的区别是本实例是否有过成功连接，而不是本次是否自动尝试。
/// [automatic] 表示尝试来源；[error] 是本次失败诊断，不是最初连接丢失的诊断。
///
/// [willRetry] 表示事件产生时 SDK 是否计划继续自动重试，不保证最终恢复。
/// 为 true 时等待后续尝试；应用不应同时启动另一套重连循环。
/// 本事件本身不表示会话已经丢失；恢复后检查 [MqttReconnected.sessionPresent]。
///
/// 仅收到拒绝 CONNACK 时 [reasonCode] 和 [properties] 有值；DNS、TCP、TLS 等
/// 尚未收到 CONNACK 的失败不伪造 Broker 属性，详细原因从 [error] 读取。
final class MqttReconnectFailed extends MqttConnectionFailure {
  MqttReconnectFailed._(super.e) : super._();

  @override
  String toString() => mqttDebugString('MqttReconnectFailed', {
        'automatic': automatic,
        'timestampMs': timestampMs,
        'sequence': sequence,
        'connectionCount': connectionCount,
        'reconnectCount': reconnectCount,
        'retryAttempt': retryAttempt,
        'totalRetryAttempts': totalRetryAttempts,
        'downtimeMs': downtimeMs,
        'droppedEvents': droppedEvents,
        'disconnectedAtMs': disconnectedAtMs,
        'attemptStartedAtMs': attemptStartedAtMs,
        'willRetry': willRetry,
        'error': error,
        'properties': properties,
        'reasonCode': reasonCode,
      });
}

/// 服务端实际发送的 MQTT 5.0 DISCONNECT 报文快照，不是独立事件。
///
/// 通过 [MqttDisconnected.serverDisconnect] 获取。保留服务端的实际原因码和解码属性，
/// 不受客户端主动断开的四种 API 限制；未知原因码数值仍保留。
/// properties.serverReference 只是服务端提供的提示，SDK 不自动连接该地址。
final class MqttServerDisconnect {
  MqttServerDisconnect._(NativeEvent e)
      : reasonCode = MqttReasonCode(e.reason),
        properties = MqttReceivedDisconnectProperties._(e.properties);
  final MqttReasonCode reasonCode;
  final MqttReceivedDisconnectProperties properties;

  @override
  String toString() => mqttDebugString('MqttServerDisconnect', {
        'reasonCode': reasonCode,
        'properties': properties,
      });
}

/// 连接已断开，包括本地主动断开或网络连接丢失。
///
/// 与连接尝试失败事件不同，本事件报告断开状态，不描述一次建连尝试的结果。
/// [willRetry] 表示事件产生时是否安排自动恢复；断开不代表客户端对象已关闭释放，
/// 需要结束生命周期时仍须调用并等待 close()。不要依赖 close() 一定产生本事件。
///
/// [source] 区分本地主动断开、收到服务端 DISCONNECT 和传输连接丢失。
/// [serverDisconnect] 仅在实际收到服务端 DISCONNECT 时提供原因码及属性；
/// 网络断开不伪造此报文，不能将 error 为 null 解释为正常断开。
/// [intentional] 仅表示 source 为 local，不表示服务端已确认；DISCONNECT 没有响应 ACK。
final class MqttDisconnected extends MqttConnectionEvent {
  MqttDisconnected._(NativeEvent e)
      : source = e.source == 1
            ? MqttDisconnectSource.local
            : e.source == 2
                ? MqttDisconnectSource.server
                : MqttDisconnectSource.transport,
        serverDisconnect =
            e.packetType == 14 ? MqttServerDisconnect._(e) : null,
        willRetry = e.willRetry,
        error = e.error,
        super._(e);

  /// 本地主动断开、服务端 DISCONNECT 或传输连接丢失。
  final MqttDisconnectSource source;

  /// 仅收到服务端 DISCONNECT 时有值，含该报文的原因码和属性。
  final MqttServerDisconnect? serverDisconnect;

  /// 事件产生时是否计划自动恢复连接，不保证恢复成功。
  final bool willRetry;

  /// 可取得的额外断开诊断；null 不保证正常断开，服务端原因另见 serverDisconnect。
  final Object? error;
  bool get intentional => source == MqttDisconnectSource.local;

  @override
  String toString() => mqttDebugString('MqttDisconnected', {
        'automatic': automatic,
        'timestampMs': timestampMs,
        'sequence': sequence,
        'connectionCount': connectionCount,
        'reconnectCount': reconnectCount,
        'retryAttempt': retryAttempt,
        'totalRetryAttempts': totalRetryAttempts,
        'downtimeMs': downtimeMs,
        'droppedEvents': droppedEvents,
        'disconnectedAtMs': disconnectedAtMs,
        'attemptStartedAtMs': attemptStartedAtMs,
        'intentional': intentional,
        'willRetry': willRetry,
        'error': error,
        'source': source,
        'serverDisconnect': serverDisconnect,
      });
}

/// 事件解码/交付或业务监听回调发生异常。
///
/// 这不是所有 MQTT 操作失败的统一入口：连接尝试失败通过 [MqttConnectFailed] /
/// [MqttReconnectFailed] 报告；发布、订阅等操作失败通常由对应 Future 抛出。
///
/// [terminal] 为 false 通常表示业务 onEvent 抛出了异常，SDK 将异常和堆栈转交本事件，
/// 监听器可以记录后继续处理其他事件；SDK 不重放刚才失败的业务回调。
/// 为 true 表示事件交付发生终止性错误，例如接收队列溢出，SDK 停止接收新的交付事件
/// 并启动关闭；此前已排队的回调仍可能先执行。应清理该客户端，需要恢复时创建新实例。
///
/// 处理本事件时不要再次抛出异常；若错误处理本身抛错，SDK 不递归生成错误事件，
/// 而是交给当前 Zone 的未捕获异常处理器，并停止接收新的交付事件。
/// 此时应用仍应显式等待 client.close()，不要假定资源已释放。
final class MqttErrorEvent extends MqttEvent {
  const MqttErrorEvent._(this.error, this.stackTrace, {required this.terminal})
      : super._();

  /// 原始解码、交付或业务回调异常；不统一包装成 MQTT 协议错误。
  final Object error;

  /// 与本次异常关联的 Dart 堆栈。
  final StackTrace stackTrace;

  /// 是否因交付错误停止接收新事件并启动关闭，详见类型说明。
  final bool terminal;

  @override
  String toString() => mqttDebugString('MqttErrorEvent', {
        'terminal': terminal,
        'error': error,
        'stackTrace': stackTrace.toString(),
      });
}

/// 一个客户端绑定一个监听器，串行交付消息、连接状态和交付错误。
///
/// 传给 startConnecting 后不可替换；同一客户端手动重新连接时复用此实例。
/// SDK 会等待 onEvent 返回的 Future 后才交付下一条事件，慢回调可能导致队列溢出。
/// 回调中可 await 发布、订阅、断开或 close 的操作 Future，但不要 await 由后续事件
/// 触发的信号，例如在当前回调里等待下一条消息或业务响应，否则会阻塞后续事件。
///
/// 普通回调抛错转为 [MqttErrorEvent]；处理 MqttErrorEvent 再抛错则交给 Zone。
/// 事件在客户端所属 Dart isolate 处理，不能将 onEvent 当作 Paho 原生线程回调。
final class MqttEventListener {
  const MqttEventListener({required this.onEvent});

  /// 串行处理事件；异步处理完成前不会进入下一次回调。
  final FutureOr<void> Function(MqttEvent) onEvent;
}

final class MqttClient {
  MqttClient._(this._native, this.options);
  final NativeClient _native;
  final MqttOptions options;
  MqttEventListener? _listener;
  Future<void> _delivery = Future.value();
  bool _terminal = false;
  int _queued = 0, _queuedBytes = 0;
  String get pahoVersion => _native.pahoVersion;
  static Future<MqttClient> create(MqttOptions options) async =>
      MqttClient._(await NativeClient.create(options._toNative()), options);
  Future<void> startConnecting(MqttEventListener listener) async {
    if (_terminal || (_listener != null && !identical(_listener, listener)))
      throw StateError('Client listener already bound or delivery ended');
    if (_listener == null) {
      _listener = listener;
      _native.events.listen((e) {
        final event = switch (e.type) {
          2 => MqttMessage._(e),
          3 => MqttDisconnected._(e),
          4 => MqttConnected._(e, options),
          5 => MqttReconnecting._(e),
          6 => MqttReconnected._(e, options),
          7 => MqttConnectFailed._(e),
          8 => MqttReconnectFailed._(e),
          _ => MqttErrorEvent._(
              StateError('Unknown native event'), StackTrace.current,
              terminal: true)
        };
        _emit(event, bytes: e.estimatedBytes);
      },
          onError: (Object e, StackTrace s) =>
              _emit(MqttErrorEvent._(e, s, terminal: true)));
    }
    await _native.control(1);
  }

  void _emit(MqttEvent e, {int bytes = 0}) {
    if (_terminal) return;
    if (e is MqttErrorEvent && e.terminal) _terminal = true;

    if (_queued >= options.queueLimits.maxReceivedMessages ||
        bytes > options.queueLimits.maxBytes - _queuedBytes) {
      e = MqttErrorEvent._(
          StateError('Listener queue exhausted'), StackTrace.current,
          terminal: true);
      _terminal = true;
      bytes = 0;
    }
    if (_terminal) unawaited(_native.close());
    _queuedBytes += bytes;
    _queued++;
    _delivery = _delivery.then((_) async {
      _queued--;
      _queuedBytes -= bytes;
      try {
        await _listener!.onEvent(e);
      } catch (error, stack) {
        if (e is MqttErrorEvent) {
          _terminal = true;
          Zone.current.handleUncaughtError(error, stack);
        } else {
          try {
            await _listener!
                .onEvent(MqttErrorEvent._(error, stack, terminal: false));
          } catch (e, s) {
            _terminal = true;
            Zone.current.handleUncaughtError(e, s);
          }
        }
      }
    });
  }

  /// Completes after local send; there is no broker acknowledgement.
  /// Completion does not confirm delivery to or processing by a subscriber.
  Future<void> publishQos0(String topic, Uint8List payload,
      {bool retained = false,
      MqttPublishProperties properties = const MqttPublishProperties()}) async {
    await _native.publish(topic, payload, 0, retained, properties._toNative());
  }

  /// Completes after a successful PUBACK from the broker.
  /// Completion does not confirm delivery to or processing by a subscriber.
  Future<MqttQos1PublishResult> publishQos1(String topic, Uint8List payload,
      {bool retained = false,
      MqttPublishProperties properties = const MqttPublishProperties()}) async {
    return MqttQos1PublishResult._(await _native.publish(
        topic, payload, 1, retained, properties._toNative()));
  }

  /// Completes after a successful PUBCOMP from the broker.
  /// Completion does not confirm delivery to or processing by a subscriber.
  Future<MqttQos2PublishResult> publishQos2(String topic, Uint8List payload,
      {bool retained = false,
      MqttPublishProperties properties = const MqttPublishProperties()}) async {
    return MqttQos2PublishResult._(await _native.publish(
        topic, payload, 2, retained, properties._toNative()));
  }

  Future<MqttSubscribeResult> subscribe(MqttSubscription subscription,
          {MqttSubscribeProperties properties =
              const MqttSubscribeProperties()}) =>
      subscribeMany([subscription], properties: properties);
  Future<MqttSubscribeResult> subscribeMany(
      List<MqttSubscription> subscriptions,
      {MqttSubscribeProperties properties =
          const MqttSubscribeProperties()}) async {
    final inputs = List<MqttSubscription>.of(subscriptions);
    final e = await _native.subscribe(
        inputs.map((s) => s._toNative()).toList(), properties._toNative());
    return MqttSubscribeResult._(
        List.unmodifiable(List.generate(
            inputs.length,
            (i) => MqttSubscriptionResult._(
                inputs[i].topicFilter, inputs[i].qos, e.payload[i]))),
        MqttAcknowledgementProperties._(e.properties));
  }

  Future<MqttUnsubscribeResult> unsubscribe(String topicFilter,
          {MqttUnsubscribeProperties properties =
              const MqttUnsubscribeProperties()}) =>
      unsubscribeMany([topicFilter], properties: properties);
  Future<MqttUnsubscribeResult> unsubscribeMany(List<String> topicFilters,
      {MqttUnsubscribeProperties properties =
          const MqttUnsubscribeProperties()}) async {
    final inputs = List<String>.of(topicFilters);
    final e =
        await _native.unsubscribe(inputs, _users(properties.userProperties));
    return MqttUnsubscribeResult._(
        List.unmodifiable(List.generate(inputs.length,
            (i) => MqttUnsubscriptionResult._(inputs[i], e.payload[i]))),
        MqttAcknowledgementProperties._(e.properties));
  }

  Future<void> disconnect(
      {int drainTimeoutMs = 1000,
      MqttDisconnectProperties properties =
          const MqttDisconnectProperties()}) async {
    await _native.disconnect(0, drainTimeoutMs, properties._toNative());
  }

  Future<void> disconnectWithWillMessage(
      {int drainTimeoutMs = 1000,
      MqttDisconnectProperties properties =
          const MqttDisconnectProperties()}) async {
    await _native.disconnect(1, drainTimeoutMs, properties._toNative());
  }

  Future<void> disconnectWithUnspecifiedError(
      {int drainTimeoutMs = 1000,
      MqttDisconnectProperties properties =
          const MqttDisconnectProperties()}) async {
    await _native.disconnect(2, drainTimeoutMs, properties._toNative());
  }

  Future<void> disconnectWithImplementationError(
      {String? reason,
      int drainTimeoutMs = 1000,
      MqttDisconnectProperties properties =
          const MqttDisconnectProperties()}) async {
    await _native.disconnect(3, drainTimeoutMs, properties._toNative(),
        reason: reason);
  }

  Future<void> close() => _native.close();
}
