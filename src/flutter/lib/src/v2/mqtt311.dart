import '../debug.dart';
import 'dart:async';
import 'dart:typed_data';
import '../../common.dart';
import 'native.dart';

final class MqttWillOptions {
  const MqttWillOptions(
      {required this.topic,
      required this.payload,
      this.qos = MqttQos.atMostOnce,
      this.retained = false});
  final String topic;
  final Uint8List payload;
  final MqttQos qos;
  final bool retained;

  @override
  String toString() => mqttDebugString('MqttWillOptions', {
        'topic': topic,
        'payload': payload,
        'qos': qos,
        'retained': retained,
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
      this.cleanSession = true,
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
  final bool automaticReconnect, cleanSession;
  final MqttWillOptions? will;
  NativeOptions _toNative() => NativeOptions(
      protocol: 4,
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
      cleanSession: cleanSession,
      willTopic: will?.topic,
      willPayload: will?.payload,
      willQos: will?.qos.index ?? 0,
      willRetained: will?.retained ?? false);

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
        'cleanSession': cleanSession,
      });
}

final class MqttSubscription {
  const MqttSubscription(this.topicFilter, {this.qos = MqttQos.atLeastOnce});
  final String topicFilter;
  final MqttQos qos;

  @override
  String toString() => mqttDebugString('MqttSubscription', {
        'topicFilter': topicFilter,
        'qos': qos,
      });
}

final class MqttSubscriptionResult {
  MqttSubscriptionResult._(
      this.topicFilter, this.requestedQos, this.rawReturnCode);
  final String topicFilter;
  final MqttQos requestedQos;
  final int rawReturnCode;
  bool get accepted => rawReturnCode >= 0 && rawReturnCode <= 2;
  MqttQos? get grantedQos => accepted ? MqttQos.values[rawReturnCode] : null;

  @override
  String toString() => mqttDebugString('MqttSubscriptionResult', {
        'topicFilter': topicFilter,
        'requestedQos': requestedQos,
        'accepted': accepted,
        'grantedQos': grantedQos,
        'rawReturnCode': rawReturnCode,
      });
}

final class MqttSubscribeResult {
  MqttSubscribeResult._(this.entries);
  final List<MqttSubscriptionResult> entries;
  void requireAllAccepted() {
    for (final e in entries) {
      if (!e.accepted) throw MqttProtocolException._(e.rawReturnCode, this);
    }
  }

  @override
  String toString() => mqttDebugString('MqttSubscribeResult', {
        'entries': entries,
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
final class MqttMessage extends MqttEvent {
  MqttMessage._(NativeEvent e)
      : topic = e.topic!,
        payload = e.payload,
        qos = MqttQos.values[e.value],
        retained = e.flags & 1 != 0,
        duplicate = e.flags & 2 != 0,
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

  @override
  String toString() => mqttDebugString('MqttMessage', {
        'topic': topic,
        'payload': payload,
        'qos': qos,
        'retained': retained,
        'duplicate': duplicate,
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
  /// 成功本身不清零；网络断开时清零，下一次重试从 1 开始。
  /// 3.1.1 主动断开时也清零。
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
        super._(e);

  /// 本次成功 CONNACK 的 Session Present：Broker 是否恢复了已有会话。
  /// 与此客户端实例是否首次连接无关；false 时应用按需重新订阅。
  final bool sessionPresent;
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
      : error = e.error ?? StateError('Connection failed'),
        willRetry = e.willRetry,
        super._(e);

  /// 本次尝试的错误诊断；不是 startConnecting 启动受理阶段的异常。
  final Object error;

  /// 事件产生时 SDK 是否计划继续自动重试；关闭客户端可取消该计划。
  final bool willRetry;
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
      });
}

/// 连接已断开，包括本地主动断开或网络连接丢失。
///
/// 与连接尝试失败事件不同，本事件报告断开状态，不描述一次建连尝试的结果。
/// [willRetry] 表示事件产生时是否安排自动恢复；断开不代表客户端对象已关闭释放，
/// 需要结束生命周期时仍须调用并等待 close()。不要依赖 close() 一定产生本事件。
///
/// [intentional] 为 true 表示本地主动断开，不表示 Broker 已确认 DISCONNECT；
/// MQTT 3.1.1 的 DISCONNECT 没有响应 ACK，也没有服务端 DISCONNECT 报文。
/// [error] 仅在取得额外诊断时有值，null 不保证是正常断开。
final class MqttDisconnected extends MqttConnectionEvent {
  MqttDisconnected._(NativeEvent e)
      : intentional = e.source == 1,
        willRetry = e.willRetry,
        error = e.error,
        super._(e);

  /// 是否由本地主动断开；不表示服务端已确认。
  final bool intentional;

  /// 事件产生时是否计划自动恢复连接。
  final bool willRetry;

  /// 可取得的额外断开诊断；null 不保证正常断开。
  final Object? error;

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
      {bool retained = false}) async {
    await _native.publish(topic, payload, 0, retained, const []);
  }

  /// Completes after a successful PUBACK from the broker.
  /// Completion does not confirm delivery to or processing by a subscriber.
  Future<void> publishQos1(String topic, Uint8List payload,
      {bool retained = false}) async {
    await _native.publish(topic, payload, 1, retained, const []);
  }

  /// Completes after a successful PUBCOMP from the broker.
  /// Completion does not confirm delivery to or processing by a subscriber.
  Future<void> publishQos2(String topic, Uint8List payload,
      {bool retained = false}) async {
    await _native.publish(topic, payload, 2, retained, const []);
  }

  Future<MqttSubscribeResult> subscribe(MqttSubscription subscription) =>
      subscribeMany([subscription]);
  Future<MqttSubscribeResult> subscribeMany(
      List<MqttSubscription> subscriptions) async {
    final inputs = List<MqttSubscription>.of(subscriptions);
    final e = await _native.subscribe(
        inputs
            .map((s) =>
                NativeSubscription(s.topicFilter, s.qos.index, false, false, 0))
            .toList(),
        const []);
    return MqttSubscribeResult._(List.unmodifiable(List.generate(
        inputs.length,
        (i) => MqttSubscriptionResult._(
            inputs[i].topicFilter, inputs[i].qos, e.payload[i]))));
  }

  Future<void> unsubscribe(String topicFilter) =>
      unsubscribeMany([topicFilter]);
  Future<void> unsubscribeMany(List<String> topicFilters) async {
    await _native.unsubscribe(topicFilters, const []);
  }

  /// Waits for outbound exchanges up to Paho's drain interval; not a broker ACK.
  Future<void> disconnect({int drainTimeoutMs = 1000}) async {
    await _native.disconnect(0, drainTimeoutMs, const []);
  }

  /// Releases the client. Paho may send a normal DISCONNECT; does not guarantee a Will.
  Future<void> close() => _native.close();
}

/// MQTT 3.1.1 SUBACK refusal, retaining the complete subscription result.
final class MqttProtocolException implements Exception {
  const MqttProtocolException._(this.reasonCode, this.result);
  int get packetType => 9;
  final int reasonCode;
  final MqttSubscribeResult result;

  @override
  String toString() => mqttDebugString('MqttProtocolException', {
        'packetType': packetType,
        'reasonCode': reasonCode,
        'result': result,
      });
}
