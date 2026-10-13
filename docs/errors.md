# Flutter 错误与连接失败事件

错误由共享 C 层采集，Dart 复制为 `MqttErrorInfo` sealed 类型，不按日志文案分类。
普通操作失败通过 `MqttException.info` 抛出；MQTT 5 协议拒绝另保留原因码及具体报文属性。
`startConnecting(listener)` 只确认启动受理，连接结果通过 Connected/ConnectFailed 等事件交付。
完整事件区别、监听器异常和关闭规则见 [Flutter 说明](flutter.md)。

| 类型 | 专属信息 |
|---|---|
| `MqttArgumentError` | 参数错误 |
| `MqttStateError` | closed / invalidState / notConnected |
| `MqttDnsError` | dnsCode、systemCode |
| `MqttNetworkError` | 网络原因、systemCode |
| `MqttTlsConfigurationError`、`MqttTlsHandshakeError` | TLS diagnostics |
| `MqttCertificateError` | 证书原因、TLS diagnostics |
| `MqttBrokerError` | Broker 拒绝，原始 code |
| `MqttResourceError` | limit / noMemory |
| `MqttCancelledError` | cancelled / operationIncomplete |
| `MqttInternalError` | 明确报告的内部错误 |
| `MqttUnknownError` | 未知分类/原因和原始诊断 |

所有错误共享 `context: MqttErrorContext`；`MqttErrorInfo` 同时提供同名便捷访问器，
不复制数据：`stage`、`code`、`operation`、`operationType`（由原始 operation 映射）、
`timestampMs`、`message`、`details`、`truncated`、`attempt`。

- `attempt: MqttErrorAttempt?` 包含连接尝试元数据；
  连接尝试错误包含 `id`（从 1 开始）、`elapsedMs`（单调时钟毫秒）、`willRetry`。
  普通操作/启动受理错误不属于具体尝试时为 null，不使用编号 0 作为业务哨兵。
- `timestampMs` 是 Unix epoch 毫秒，受系统时钟调整影响；`stage` 是失败阶段。
- `MqttTlsDiagnostics` 仅出现在 TLS/证书错误（以及 Unknown 的原始保留数据）中。
  `tlsCode` 是 SSL_get_error 类别，`verifyCode` 是 OpenSSL X509 验证结果，
  `systemCode` 是握手现场 errno。`platform: MqttPlatformError?` 保存系统信任验证的 code/domain 证据，可与 OpenSSL 证据同时存在。
- 诊断值缺失时仍允许 null，这表示**没有采集到证据**，不用于区分错误类型。
  presence flags 保留有效的零值。证书失败类型及其 `reason` 本身始终确定且非空。
- 未识别的分类、原因或不合法的分类/原因组合映射为 `Unknown`，保留原始整数和诊断；
  未知 stage/operation 映射为对应 unknown。不会按文案猜测或因未来编号越界崩溃。

```dart
switch (exception.info) {
  case MqttDnsError(:final dnsCode): print(dnsCode);
  case MqttNetworkError(:final reason): print(reason);
  case MqttCertificateError(:final reason, :final diagnostics):
    print('$reason: ${diagnostics.verifyCode}');
  case MqttTlsConfigurationError(:final details): print(details);
  default: print(exception.info.message);
}
```

示例只展示常用分支；业务也可以列出全部类型，使用编译器的穷举检查。
无需先检查 category，再试探一系列不相关的 nullable 字段。

C 的 `mqtt_error` 是固定大小的内部快照；Dart 解码后不保留事件指针。
message（256 字节）、details（2048 字节）、platformDomain（64 字节）按 UTF-8 复制。
日志可能包含证书路径；不主动收集 payload、密码或私钥。公开错误模型提供调试用 toString()。
插件加载和 ABI 引导失败可能是平台异常；业务监听器抛出的异常保留原始对象和堆栈。

## 底层采集与生命周期

实现位于 `native/errors/mqtt_diagnostics.c` 和 `native/include/mqtt_error.h`。Paho 的可选
`MQTT_SDK_DIAGNOSTICS` 补丁在实际执行连接和继续握手时建立线程局部采集范围，并在
每次新尝试开始时清空该客户端记录。Paho 锁保证同一客户端记录串行访问；线程局部指针
离开调用后清空，多个客户端不会共享全局“最后一次错误”。

Socket 层在 getaddrinfo / errno / SO_ERROR 被覆盖前记录；TLS 在消费 OpenSSL 错误队列
之前保留验证结果，再通过 ssl_error_cb 复制错误文本；Apple 平台在释放 CFError 前复制
信任验证失败的 code、domain、description。失败钩子复制快照并产生连接事件。CONNECT 命令在 Paho 受理后立即完成；
不把此命令作为 Paho onSuccess/onFailure 的 context，后续结果仅通过 client 级钩子通知。失败事件继续使用有界状态队列，溢出通过 sequence / droppedEvents 可观察；请求
完成事件仍使用预分配存储。

非连接操作失败也由 C 层统一分类；有 Paho message 时保留，但不附带其他连接尝试的旧错误。
SDK 不提供 publish / subscribe / unsubscribe 的业务操作超时。同步 DNS 解析及 Paho
定时检查意味着 connectTimeoutSeconds 也不是严格的墙钟截止时间。

## 验证

从仓库根目录执行：

```sh
go -C scripts run . test --suite errors
go -C scripts run . test --suite trust --ios-runtime com.apple.CoreSimulator.SimRuntime.iOS-18-5
```

覆盖真实 DNS、网络、TLS、证书、CONNACK 拒绝、连接超时及自动重试，Dart 类型映射覆盖
未知值、缺失诊断和有效零值。系统信任验证使用临时 iOS 模拟器，结束后清理。
实际运行结果与验证范围见 [实施记录](mqtt-api-v5-flutter-progress.md)。
