/// Shared error snapshots and native decoding for both MQTT protocols.
import 'debug.dart';
import 'dart:convert';
import 'dart:ffi';

final class NativeError extends Struct {
  @Int32()
  external int category;
  @Int32()
  external int reason;
  @Int32()
  external int stage;
  @Int32()
  external int code;
  @Int32()
  external int operation;
  @Int32()
  external int systemCode;
  @Int32()
  external int dnsCode;
  @Int32()
  external int tlsCode;
  @Int32()
  external int verifyCode;
  @Int32()
  external int platformCode;
  @Uint32()
  external int flags;
  @Uint32()
  external int reserved;
  @Uint64()
  external int attemptId;
  @Uint64()
  external int timestampMs;
  @Uint64()
  external int elapsedMs;
  @Array(256)
  external Array<Uint8> message;
  @Array(2048)
  external Array<Uint8> details;
  @Array(64)
  external Array<Uint8> platformDomain;
}

/// 错误发生阶段；连接与普通操作共享此枚举。
enum MqttErrorStage {
  /// 未取得可靠的失败阶段。
  unknown,

  /// 参数、状态校验或启动受理阶段。
  admission,

  /// 域名解析阶段。
  dns,

  /// TCP 建连阶段。
  tcp,

  /// TLS 上下文与证书配置阶段。
  tlsConfig,

  /// TLS 握手和证书校验阶段。
  tlsHandshake,

  /// 等待或处理 Broker CONNACK 阶段。
  connack,

  /// 其他 MQTT 操作执行阶段。
  operation
}

/// 与原生操作对应的类型化标识；不要将枚举序号用于业务持久化协议。
enum MqttOperation {
  /// 创建客户端与底层资源。
  create,

  /// 启动连接，或该客户端后续连接尝试；公开入口为 startConnecting。
  connect,

  /// 单项订阅；单项 SUBACK 拒绝会使用此操作标识。
  subscribe,

  /// 底层单项退订标识；公开单项 API 委托给 unsubscribeMany。
  unsubscribe,

  /// 发布消息。
  publish,

  /// 主动断开连接。
  disconnect,

  /// 关闭并释放客户端。
  close,

  /// 批量订阅；公开单项 subscribe 的传输错误也可能携带此标识。
  subscribeMany,

  /// 批量退订；公开单项 unsubscribe 同样使用此标识。
  unsubscribeMany,

  /// 无法识别或不对应某个 MQTT 操作，例如事件交付错误。
  unknown
}

/// 同类错误的具体原因；不会出现其他错误类型的原因。
enum MqttStateReason {
  /// 客户端正在关闭或已关闭。
  closed,

  /// 状态不允许操作，或原生库不兼容。
  invalidState,

  /// 操作需要已建立的 MQTT 连接。
  notConnected,
}

/// 同类错误的具体原因；不会出现其他错误类型的原因。
enum MqttNetworkReason {
  /// 有网络错误证据，但无法进一步分类。
  unknown,

  /// TCP 连接被拒绝。
  connectionRefused,

  /// 连接尝试超时。
  timeout,

  /// 主机或网络不可达。
  unreachable,

  /// 连接被重置或写入已断开的连接。
  connectionReset,

  /// 对端关闭连接。
  peerClosed,
}

/// 同类错误的具体原因；不会出现其他错误类型的原因。
enum MqttCertificateReason {
  /// 证书链无法建立到可信根。
  untrusted,

  /// 证书已过期。
  expired,

  /// 证书身份与服务器主机名不匹配。
  hostnameMismatch,

  /// 验证器拒绝证书，且没有更具体原因。
  rejected,

  /// 证书尚未生效。
  notYetValid,
}

/// 同类错误的具体原因；不会出现其他错误类型的原因。
enum MqttResourceReason {
  /// 队列、在途请求或数据容量达到限制。
  limit,

  /// 内存分配失败。
  noMemory,
}

/// 同类错误的具体原因；不会出现其他错误类型的原因。
enum MqttCancellationReason {
  /// 操作被取消，例如 close 终止待完成请求。
  cancelled,

  /// 操作在完成前中断，无法确认 Broker 是否已处理。
  operationIncomplete,
}

/// 不可变的错误现场快照。
final class MqttErrorAttempt {
  const MqttErrorAttempt._(this.id, this.elapsedMs, this.willRetry);

  /// 该客户端连接尝试编号，从 1 开始。
  final int id;

  /// 本次尝试的单调时钟耗时，单位毫秒。
  final int elapsedMs;

  /// 失败时是否计划自动重试；不是能恢复的保证，disconnect/close 可停止重试。
  final bool willRetry;

  @override
  String toString() => mqttDebugString('MqttErrorAttempt', {
        'id': id,
        'elapsedMs': elapsedMs,
        'willRetry': willRetry,
      });
}

/// 不可变的错误现场快照。
final class MqttPlatformError {
  const MqttPlatformError._(this.code, this.domain);

  /// 系统信任验证原始错误码，例如 SecTrust 的 CFError code。
  final int code;

  /// 系统错误所属 domain；与 code 一起解释，可能为空字符串。
  final String domain;

  @override
  String toString() => mqttDebugString('MqttPlatformError', {
        'code': code,
        'domain': domain,
      });
}

/// 不可变的错误现场快照。
final class MqttTlsDiagnostics {
  const MqttTlsDiagnostics._(
      this.systemCode, this.tlsCode, this.verifyCode, this.platform);

  /// 握手现场的 errno；未采集时为空，取值因操作系统而异。
  final int? systemCode;

  /// SSL_get_error 类别，不是 OpenSSL 打包错误码；未采集时为空。
  final int? tlsCode;

  /// OpenSSL X509 验证结果；未采集时为空，有效的 0 会保留。
  final int? verifyCode;

  /// 系统信任验证证据；未使用或未采集时为空，可与 OpenSSL 证据同时存在。
  final MqttPlatformError? platform;

  @override
  String toString() => mqttDebugString('MqttTlsDiagnostics', {
        'systemCode': systemCode,
        'tlsCode': tlsCode,
        'verifyCode': verifyCode,
        'platform': platform,
      });
}

/// 仅供未知错误保留未识别的数据。
final class MqttRawDiagnostics {
  const MqttRawDiagnostics._(
      this.category, this.reason, this.systemCode, this.dnsCode, this.tls);

  /// 无法映射的原生分类编号。
  final int category;

  /// 无法映射的原生原因编号。
  final int reason;

  /// 原始 errno，未采集时为空。
  final int? systemCode;

  /// 原始 getaddrinfo 返回码，未采集时为空。
  final int? dnsCode;

  /// 保留未知错误中的 TLS 和平台证据。
  final MqttTlsDiagnostics tls;

  @override
  String toString() => mqttDebugString('MqttRawDiagnostics', {
        'category': category,
        'reason': reason,
        'systemCode': systemCode,
        'dnsCode': dnsCode,
        'tls': tls,
      });
}

/// 不可变的错误现场快照。
final class MqttErrorContext {
  const MqttErrorContext._(
      this.stage,
      this.code,
      this.operation,
      this.timestampMs,
      this.message,
      this.details,
      this.truncated,
      this.attempt);

  /// 失败阶段；未知时为 unknown。
  final MqttErrorStage stage;

  /// 原始 SDK/Paho/Broker 错误码；SDK 使用 -1000..-1005。
  final int code;

  /// 原始操作编号；业务优先使用 operationType。
  final int operation;

  /// 错误发生时的 Unix epoch 毫秒时间，可能受系统时钟调整影响。
  final int timestampMs;

  /// 可读说明，可能本地化；不要解析文本决定业务分支。
  final String message;

  /// 原始诊断文本，可能为空、截断或含本机证书路径。
  final String details;

  /// 原生诊断文本是否因固定容量而截断。
  final bool truncated;

  /// 连接尝试现场；不属于具体连接尝试时为空。
  final MqttErrorAttempt? attempt;

  /// 原始操作编号的类型化映射；未知编号为 unknown。
  MqttOperation get operationType => operation >= 0 && operation < 9
      ? MqttOperation.values[operation]
      : MqttOperation.unknown;

  @override
  String toString() => mqttDebugString('MqttErrorContext', {
        'stage': stage,
        'code': code,
        'operationType': operationType,
        'operation': operation,
        'timestampMs': timestampMs,
        'message': message,
        'details': details,
        'truncated': truncated,
        'attempt': attempt,
      });
}

/// 类型化错误快照。业务通过类型匹配读取专属字段，不解析 message/details。
/// 连接失败见连接事件，操作失败见异常 info；两条路径使用相同类型。
sealed class MqttErrorInfo {
  const MqttErrorInfo._(this.context);

  /// 所有错误共有的诊断上下文。
  final MqttErrorContext context;

  /// 失败阶段；未知时为 unknown。
  MqttErrorStage get stage => context.stage;

  /// 原始 SDK/Paho/Broker 错误码；SDK 使用 -1000..-1005。
  int get code => context.code;

  /// 原始操作编号；业务优先使用 operationType。
  int get operation => context.operation;

  /// 错误发生时的 Unix epoch 毫秒时间，可能受系统时钟调整影响。
  int get timestampMs => context.timestampMs;

  /// 可读说明，可能本地化；不要解析文本决定业务分支。
  String get message => context.message;

  /// 原始诊断文本，可能为空、截断或含本机证书路径。
  String get details => context.details;

  /// 原生诊断文本是否因固定容量而截断。
  bool get truncated => context.truncated;

  /// 连接尝试现场；不属于具体连接尝试时为空。
  MqttErrorAttempt? get attempt => context.attempt;

  /// 原始操作编号的类型化映射；未知编号为 unknown。
  MqttOperation get operationType => context.operationType;
  factory MqttErrorInfo._decode(NativeError e) {
    final c = MqttErrorContext._(
        e.stage >= 0 && e.stage < MqttErrorStage.values.length
            ? MqttErrorStage.values[e.stage]
            : MqttErrorStage.unknown,
        e.code,
        e.operation,
        e.timestampMs,
        _text(e.message, 256),
        _text(e.details, 2048),
        e.flags & 64 != 0,
        e.attemptId == 0
            ? null
            : MqttErrorAttempt._(e.attemptId, e.elapsedMs, e.flags & 32 != 0));
    final system = e.flags & 1 != 0 ? e.systemCode : null;
    final dns = e.flags & 2 != 0 ? e.dnsCode : null;
    final evidence = MqttTlsDiagnostics._(
        system,
        e.flags & 4 != 0 ? e.tlsCode : null,
        e.flags & 8 != 0 ? e.verifyCode : null,
        e.flags & 16 != 0
            ? MqttPlatformError._(e.platformCode, _text(e.platformDomain, 64))
            : null);
    return switch ((e.category, e.reason)) {
      (1, 1) => MqttArgumentError._(c),
      (2, 2) => MqttStateError._(c, MqttStateReason.closed),
      (2, 3) => MqttStateError._(c, MqttStateReason.invalidState),
      (2, 20) => MqttStateError._(c, MqttStateReason.notConnected),
      (3, 7) => MqttDnsError._(c, dns, system),
      (4, 0) => MqttNetworkError._(c, MqttNetworkReason.unknown, system),
      (4, 8) =>
        MqttNetworkError._(c, MqttNetworkReason.connectionRefused, system),
      (4, 9) => MqttNetworkError._(c, MqttNetworkReason.timeout, system),
      (4, 10) => MqttNetworkError._(c, MqttNetworkReason.unreachable, system),
      (4, 11) =>
        MqttNetworkError._(c, MqttNetworkReason.connectionReset, system),
      (4, 12) => MqttNetworkError._(c, MqttNetworkReason.peerClosed, system),
      (5, 13) => MqttTlsConfigurationError._(c, evidence),
      (5, 14) => MqttTlsHandshakeError._(c, evidence),
      (5, 15) =>
        MqttCertificateError._(c, MqttCertificateReason.untrusted, evidence),
      (5, 16) =>
        MqttCertificateError._(c, MqttCertificateReason.expired, evidence),
      (5, 17) => MqttCertificateError._(
          c, MqttCertificateReason.hostnameMismatch, evidence),
      (5, 18) =>
        MqttCertificateError._(c, MqttCertificateReason.rejected, evidence),
      (5, 22) =>
        MqttCertificateError._(c, MqttCertificateReason.notYetValid, evidence),
      (6, 19) => MqttBrokerError._(c),
      (7, 4) => MqttResourceError._(c, MqttResourceReason.limit),
      (7, 5) => MqttResourceError._(c, MqttResourceReason.noMemory),
      (8, 6) => MqttCancelledError._(c, MqttCancellationReason.cancelled),
      (8, 21) =>
        MqttCancelledError._(c, MqttCancellationReason.operationIncomplete),
      (9, 0) => MqttInternalError._(c),
      _ => MqttUnknownError._(
          c, MqttRawDiagnostics._(e.category, e.reason, system, dns, evidence)),
    };
  }
  static String _text(Array<Uint8> a, int length) {
    final bytes = <int>[];
    for (var i = 0; i < length && a[i] != 0; ++i) {
      bytes.add(a[i]);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// 参数不合法。
final class MqttArgumentError extends MqttErrorInfo {
  const MqttArgumentError._(super.context) : super._();

  @override
  String toString() => mqttDebugString('MqttArgumentError', {
        'context': context,
      });
}

/// 客户端状态不允许操作。
final class MqttStateError extends MqttErrorInfo {
  const MqttStateError._(super.context, this.reason) : super._();

  /// 仅限客户端状态错误的原因。
  final MqttStateReason reason;

  @override
  String toString() => mqttDebugString('MqttStateError', {
        'context': context,
        'reason': reason,
      });
}

/// 域名解析失败。
final class MqttDnsError extends MqttErrorInfo {
  const MqttDnsError._(super.context, this.dnsCode, this.systemCode)
      : super._();

  /// getaddrinfo 返回码；未采集时为空，取值因操作系统而异。
  final int? dnsCode;

  /// 解析现场的 errno，例如 EAI_SYSTEM；未采集时为空。
  final int? systemCode;

  @override
  String toString() => mqttDebugString('MqttDnsError', {
        'context': context,
        'dnsCode': dnsCode,
        'systemCode': systemCode,
      });
}

/// TCP 或网络传输失败。
final class MqttNetworkError extends MqttErrorInfo {
  const MqttNetworkError._(super.context, this.reason, this.systemCode)
      : super._();

  /// 仅限网络错误的原因。
  final MqttNetworkReason reason;

  /// 现场 errno 或 SO_ERROR；未采集时为空，取值因操作系统而异。
  final int? systemCode;

  @override
  String toString() => mqttDebugString('MqttNetworkError', {
        'context': context,
        'reason': reason,
        'systemCode': systemCode,
      });
}

/// TLS 配置失败，例如证书路径不存在或格式不正确。
final class MqttTlsConfigurationError extends MqttErrorInfo {
  const MqttTlsConfigurationError._(super.context, this.diagnostics)
      : super._();

  /// TLS 配置现场证据；只包含实际采集到的数据。
  final MqttTlsDiagnostics diagnostics;

  @override
  String toString() => mqttDebugString('MqttTlsConfigurationError', {
        'context': context,
        'diagnostics': diagnostics,
      });
}

/// TLS 握手失败。
final class MqttTlsHandshakeError extends MqttErrorInfo {
  const MqttTlsHandshakeError._(super.context, this.diagnostics) : super._();

  /// TLS 握手现场证据；只包含实际采集到的数据。
  final MqttTlsDiagnostics diagnostics;

  @override
  String toString() => mqttDebugString('MqttTlsHandshakeError', {
        'context': context,
        'diagnostics': diagnostics,
      });
}

/// 证书链、有效期或主机名验证失败。
final class MqttCertificateError extends MqttErrorInfo {
  const MqttCertificateError._(super.context, this.reason, this.diagnostics)
      : super._();

  /// 仅限证书验证失败的原因。
  final MqttCertificateReason reason;

  /// OpenSSL 与系统验证证据；缺失不影响错误类型判断。
  final MqttTlsDiagnostics diagnostics;

  @override
  String toString() => mqttDebugString('MqttCertificateError', {
        'context': context,
        'reason': reason,
        'diagnostics': diagnostics,
      });
}

/// Broker 通过 CONNACK 或 SUBACK 拒绝请求；拒绝码见 code。
final class MqttBrokerError extends MqttErrorInfo {
  const MqttBrokerError._(super.context) : super._();

  @override
  String toString() => mqttDebugString('MqttBrokerError', {
        'context': context,
      });
}

/// 资源不足。
final class MqttResourceError extends MqttErrorInfo {
  const MqttResourceError._(super.context, this.reason) : super._();

  /// 仅限容量和内存错误的原因。
  final MqttResourceReason reason;

  @override
  String toString() => mqttDebugString('MqttResourceError', {
        'context': context,
        'reason': reason,
      });
}

/// 操作被取消或中断。
final class MqttCancelledError extends MqttErrorInfo {
  const MqttCancelledError._(super.context, this.reason) : super._();

  /// 取消或未完成的具体原因。
  final MqttCancellationReason reason;

  @override
  String toString() => mqttDebugString('MqttCancelledError', {
        'context': context,
        'reason': reason,
      });
}

/// 底层明确报告的内部错误。
final class MqttInternalError extends MqttErrorInfo {
  const MqttInternalError._(super.context) : super._();

  @override
  String toString() => mqttDebugString('MqttInternalError', {
        'context': context,
      });
}

/// 没有足够证据分类，或原生库增加了绑定尚未识别的分类/原因。
final class MqttUnknownError extends MqttErrorInfo {
  const MqttUnknownError._(super.context, this.diagnostics) : super._();

  /// 无法识别的分类、原因与原始证据，用于日志和未来兼容。
  final MqttRawDiagnostics diagnostics;

  @override
  String toString() => mqttDebugString('MqttUnknownError', {
        'context': context,
        'diagnostics': diagnostics,
      });
}

/// MQTT 参数、状态、受理或异步操作失败的异常；完整详情见 info。
/// startConnecting 仅因启动受理失败抛出；实际连接失败由 MqttConnectFailed/MqttReconnectFailed 报告。
/// 初始化失败也可能是平台异常；此类型不包装所有业务回调异常。
final class MqttException implements Exception {
  /// 以已有结构化快照创建异常；不查询原生状态或重新采集错误。
  const MqttException(this.info);

  /// 完整的 C 层错误快照；不会在读取时查询全局可变状态。
  final MqttErrorInfo info;

  /// 原始 SDK/Paho/Broker 错误码。SDK 使用 -1000..-1005，其他值保留底层含义。
  int get code => info.code;

  /// 原始操作编号；无对应操作时可能为 -1，业务优先使用 operationType。
  int get operation => info.operation;
  factory MqttException._native(NativeError error) {
    final info = MqttErrorInfo._decode(error);
    return MqttException(info);
  }

  /// 用于诊断显示；程序分支使用 [info] 的枚举与错误码，不解析此字符串。
  @override
  String toString() => mqttDebugString('MqttException', {
        'info': info,
      });
}

// Internal ABI decoder; omitted from public package exports.
MqttException decodeNativeException(Pointer<NativeError> pointer) =>
    MqttException._native(pointer.ref);
