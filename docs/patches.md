# Paho 基线、补丁与构建输入

当前基线：Paho C 1.3.16，提交 `4a939ddb01eea581a32fd6f0adcfee51b91d2601`。
Go 工具从 YAML 的 `paths.paho_source`（或 `--paho-source`）读取 Paho 路径并传入 CMake，
可通过 `PAHO_SOURCE_DIR` 指定其他源码目录。

## 基础补丁

SDK 的输入源码需要按顺序包含以下三个补丁。`go -C scripts run . download` 会为
新下载的 Paho 自动应用并校验这些补丁；已有用户源码不会自动修改。
手动准备的新 checkout 在 **Paho 根目录**执行以下命令，已应用的不要重复执行：

```sh
git apply --check ../paho-mqtt-c-notes/src/patches/paho-connected-session.patch
git apply ../paho-mqtt-c-notes/src/patches/paho-connected-session.patch
git apply --check ../paho-mqtt-c-notes/src/patches/paho-platform-trust.patch
git apply ../paho-mqtt-c-notes/src/patches/paho-platform-trust.patch
git apply --check ../paho-mqtt-c-notes/src/patches/paho-diagnostics.patch
git apply ../paho-mqtt-c-notes/src/patches/paho-diagnostics.patch
```

如目录名不同需调整路径。判断补丁是否已应用，可用 `git apply --reverse --check`，
不要添加实际 reverse 操作。升级 Paho 时应审查冲突与回调路径，不能直接忽略失败。

| 补丁 | 职责 |
|---|---|
| `paho-connected-session.patch` | 增加 `MQTTAsync_setConnectedWithSession`，在每次成功 CONNACK 交付实际 Session Present，保留原有回调 |
| `paho-platform-trust.patch` | TLS target 通过 `MQTT_SDK_PLATFORM_TRUST` 接入 SDK 平台验证器，不修改 Paho 公共配置结构 |
| `paho-diagnostics.patch` | 通过 `MQTT_SDK_DIAGNOSTICS` 保留 DNS/TCP/TLS 失败现场，连接失败按 client 生命周期交付，避免自动重试复用已完成请求上下文 |

共享核心要求 `MQTTASYNC_HAS_CONNECTED_WITH_SESSION`。平台信任与诊断钩子仅在定义
相应宏的 SDK 构建中启用；无宏的独立 Paho 构建不启用这些接入点。SDK 的 async target
及 socket common object target 都需要诊断宏，详见 [CMake](../src/native/CMakeLists.txt)。

## MQTT 5 隔离 overlay

上述输入准备完成后，CMake 调用 [Go overlay](../scripts/overlay.go)，
复制源码到当前构建目录的 `paho-sdk-source` 并执行带匹配校验的修改。该过程不改写
输入 checkout。`paho-mqtt5-sdk.patch` 是可审查/重放快照，实际构建以脚本为准；
不要再把这个快照应用到输入源码，否则 overlay 的基线匹配会失败。

MQTT 5 钩子依赖 SDK C runtime，不作为独立上游 Paho 库分发。职责和重放方式见
[MQTT 5 适配说明](paho-v5-sdk.md)。Flutter 绑定与原生库使用 ABI 2、core 版本 2；
不提供 Kotlin/Swift 旧 SDK 或 ABI 1 兼容入口。

## 验证入口

以下命令在仓库根目录执行，先按 [构建说明](build.md) 准备对应 host 库：

```sh
go -C scripts run . test --suite reconnect
go -C scripts run . test --suite errors
go -C scripts run . test --suite runtime
```

重连用例验证首次失败后恢复、手动/自动恢复、Session Present 及 Broker 丢会话后的
表现；故障和 MQTT 5 用例补充 ACK/CONNACK、原因属性及报文限制。具体证据与未覆盖条件见
[实施记录](mqtt-api-v5-flutter-progress.md)，TLS 规则见 [信任策略](tls-trust.md)。
