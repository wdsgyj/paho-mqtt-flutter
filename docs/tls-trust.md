# TLS CA 信任策略（Flutter）

两版 API 使用 `MqttOptions.tls` 的 `MqttTlsOptions.trustStore`，不需要新增初始化调用或传入平台对象。
`trustStore` 指验证**服务器**证书所用的 CA PEM 文件，可包含多个 CA；
`certificate` / `privateKey` 是客户端身份，用于双向 TLS，含义不同。

| 配置 | Android（Dart FFI） | iOS（Dart FFI） |
|---|---|---|
| `trustStore` 为有效文件路径 | 仅加载该 CA 文件，由 OpenSSL 验证 | 仅加载该 CA 文件，由 OpenSSL 验证 |
| `trustStore` 为 null | 读取系统根证书目录，由 OpenSSL 验证 | 由 Apple SecTrust 验证 |
| 路径为空、文件缺失、无有效 CA 或 CA 不匹配 | 连接失败，不回退到系统信任 | 连接失败，不回退到系统信任 |

默认两种模式均保留 `SSL_VERIFY_PEER` 和主机名/IP 检查。显式开启下述调试开关时除外。
信任失败在 TLS 握手中拒绝连接，MQTT CONNECT 和业务凭证不会先发送。
每个客户端的配置在创建时固定，重连继续使用同一策略；其他客户端可以同时使用
不同 CA 来源。需要改变策略时关闭旧 client，使用新配置创建。

## 使用示例

```dart
const options = MqttOptions(serverUri: 'ssl://broker.example:8883',
    clientId: 'flutter-client', tls: MqttTlsOptions());
final privateOptions = MqttOptions(serverUri: 'ssl://broker.example:8883',
    clientId: 'flutter-private', tls: MqttTlsOptions(trustStore: caFile.path));
```

以上路径仅示意；真实文件应由应用放入可读的私有目录。Flutter assets 的逻辑路径
不能直接作为文件系统路径使用，需要先写入文件。系统模式不需要复制证书到沙盒。

## 调试时跳过证书校验

`MqttTlsOptions.insecureSkipVerify` 默认 `false`。显式设为 `true` 时：

- 不验证服务端证书链、有效期、证书用途或主机名/IP，无条件信任对端证书。
- 忽略 `trustStore`，不读取系统 CA、不调用 SecTrust；缺失或无效的 CA 文件也不阻止连接。
- TLS 加密、握手签名验证与密钥协商仍执行；网络故障、协议/密码套件不兼容，以及
  需要客户端身份的服务端认证仍然可能使连接失败。
- 仅影响该 client，重连继续使用该设置；其他 client 默认仍严格验证。

```dart
const MqttOptions(serverUri: 'ssl://debug-broker:8883', clientId: 'debug-client',
                  tls: MqttTlsOptions(insecureSkipVerify: true));
```

该开关会失去对服务端身份的认证，无法防止中间人攻击，仅用于调试。它不是由 Debug /
Release 构建类型自动决定的，发布配置应保持默认 `false`。

## Android

顺序尝试：

1. `/apex/com.android.conscrypt/cacerts`
2. `/system/etc/security/cacerts`

使用**第一个能打开的目录**，不合并两个目录，以免旧目录中已被新系统移除的 CA
重新进入信任集合。第一个目录为空或没有可加载证书时失败，不继续扩大信任。
两者都不可访问时失败。

实现逐个解析 PEM 内容并加入全新的 `X509_STORE`，不依赖文件名的哈希算法；
重复证书可接受，非证书文件忽略。没有加载用户 CA 目录、`SSL_CERT_FILE` /
`SSL_CERT_DIR` 环境变量或构建机的 OpenSSL 默认路径。

这实现的是“使用系统根 CA 验证”，不会执行 Java Network Security Config 的
按域名策略、调试信任覆盖或用户 CA 规则，也不会自动加入用户安装的证书。
业务需要私有 CA 时显式传入 `trustStore`。应用原先依赖这些 Java TLS 规则的，
不能假定它们自动作用于本 SDK 的 OpenSSL 连接。

## iOS

OpenSSL 使用 `SSL_CTX_set_cert_verify_callback` 接入内部 C 验证器。它读取服务端
叶证书及中间链，并使用来自连接 URI 的主机名构造 `SecPolicyCreateSSL(true, host)`，
然后调用 `SecTrustEvaluateWithError`。

系统信任模式下使用 Apple 的系统信任判定，包括系统认可的本地信任设置；不会
寻找私有系统 CA 目录，也不会尝试导出全部系统根证书。只在返回成功时设置
`X509_V_OK` 并放行握手；失败、缺少主机名或平台 API 出错均拒绝。
OpenSSL 仍负责握手签名验证、密钥协商与加密，Paho 仍执行主机名检查。

验证直接在 native 握手线程执行，不进入主线程或 Dart isolate。
为避免在 Paho 握手期间等待额外网络请求，关闭 SecTrust 的网络抓取；broker 必须
发送所需中间证书链。它不承诺每次连接都在线查询吊销状态，平台已有的信任策略
和本地信息仍由 SecTrust 处理。

显式 CA 模式先创建全新的空 trust store，移除系统验证回调，只加载指定 PEM，
不会在 OpenSSL 验证失败后尝试 SecTrust。因此即使系统信任服务端证书，自定义 CA
不认可它时也会拒绝连接。

## 构建与兼容性

Paho 通过可选构建钩子接入平台验证，见
[补丁说明](patches.md)。平台实现全部在
[`native/tls/mqtt_tls.c`](../src/native/tls/mqtt_tls.c)，信任补丁不修改 Paho 公共配置结构。
独立构建 Paho、未定义 `MQTT_SDK_PLATFORM_TRUST` 时保持原行为。

TLS 构建要求 capability bit 7（`MQTT_CAP_PLATFORM_TRUST=128`）和 bit 8
（`MQTT_CAP_INSECURE_TLS=256`）。`mqtt_config.insecure_skip_verify` 默认 0，
只接受 0/1。Dart 绑定检查当前 ABI/core 版本，并拒绝
带 TLS 能力却缺少这两个 bit 的旧库，避免旧产物悄悄使用不同的信任策略。需要同时替换
绑定源码和预编译 `.so` / XCFramework。无 TLS 的开发构建不要求这两个 bit。

Android 仍只分发唯一 `libmqtt_sdk.so`；iOS 插件直接打包唯一的静态
XCFramework，并链接 Security / CoreFoundation。系统验证不走 MethodChannel。

## 验证

以下命令在仓库根目录执行；iOS 测试使用已构建的 XCFramework，依赖 Xcode、Flutter、
CocoaPods、Mosquitto 和 Homebrew OpenSSL。

```sh
# Android 目录加载算法，host 使用临时模拟目录，不修改系统证书。
go -C scripts run . test --suite trust
# 新建并清理临时 iOS 模拟器，在该模拟器中安装临时测试 CA。
go -C scripts run . test --suite trust --ios-runtime com.apple.CoreSimulator.SimRuntime.iOS-18-5
```

测试矩阵覆盖系统与独占自定义 CA、缺失/空/无效文件、主机名不匹配、过期、
证书用途、并发不同信任源及调试跳过校验。host 的平台是 macOS，目录算法测试不能
替代 Android 系统目录在模拟器中的行为验证。iOS 信任测试不修改 macOS 信任库。
测试证据和未覆盖条件见 [实施记录](mqtt-api-v5-flutter-progress.md)。
