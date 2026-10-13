# MQTT 3.1.1 / 5.0 API 与实现设计

核对日期：2026-10-13。本文描述当前实现的架构与约束；完整用法见
[Flutter 说明](flutter.md)，验收条件与证据分别见
[Todo](mqtt-api-v5-todo.md) 和 [实施记录](mqtt-api-v5-flutter-progress.md)。

## 支持范围

当前仅支持 Flutter Android/iOS。独立 Kotlin/Swift API 当前不支持，未来是否提供另行
评估（MQTT-065 · P2，未排期），不阻塞 Flutter 验收。C 中间层保留后续语言绑定可复用的
协议操作、属性/结果、错误、通知、内存所有权和生命周期能力；不恢复旧 SDK 或 ABI v1。
Flutter 的 Kotlin/JNI、Swift 平台加载入口继续维护，它们不提供独立 MQTT 业务 API。

| Dart 入口 | 职责 |
|---|---|
| `mqtt311.dart` | MQTT 3.1.1 客户端与协议模型 |
| `mqtt5.dart` | MQTT 5.0 客户端与协议模型 |
| `common.dart` | QoS、凭据、TLS、队列、持久化、User Property 和错误类型 |

两个协议入口沿用 MqttClient、MqttOptions 等名称，同时使用时通过 import alias 区分。
协议在创建时固定，不允许运行中切换，也不静默从 5.0 降级到 3.1.1。

## 调用路径与所有权

```text
Flutter MethodChannel → 平台加载入口 → mqtt_get_api(2) 函数表地址
Dart client → Dart FFI → 共享 C runtime → Paho MQTTAsync → Broker
Paho 回调 → C 事件队列 → native port 唤醒 → Dart 复制事件 → 串行监听器
```

MethodChannel 只发现函数表，MQTT 命令和消息不经此通道传输。Android 插件打包一份
libmqtt_sdk.so；iOS 插件直接静态链接 CMqttSdk.xcframework。两版 Dart API 共用原生
注册表、调度线程和通知线程；Paho 仍有自己的网络/回调线程。

C 提交路径复制输入并返回受理状态，完成由事件报告。Paho 回调不执行 Dart 业务代码，
通知线程只唤醒接收方，不在核心锁内执行高层回调。事件持有 SDK 自有的属性/错误快照，
Dart 复制后释放事件，不向业务暴露 Paho 指针。close 完成后释放 client；释放操作等待
正在执行的通知退出。数字句柄由注册表校验，失效句柄不得访问已释放对象。

## C ABI

- `mqtt_get_api(2)` 返回 [mqtt_api_v2](../src/native/include/mqtt_api_v2.h)，提供创建、发布、订阅/退订、四种断开和事件详情。
- `core` 指向 [mqtt_core_api](../src/native/include/mqtt_api.h)，内部版本为 2，提供版本查询、连接/关闭受理、事件读取/释放、client 释放、通知注册、Dart port 桥接和错误描述。
- core 的 submit 仅接受 CONNECT/CLOSE，其他操作必须经具名接口，不能绕过 MQTT 5 断开原因限制。
- `mqtt_get_api(1)` 返回 NULL。Dart 同时校验外层及 core 的版本、大小和 capability；绑定、头文件及预编译库须一起更新。
- C 属性使用 SDK 自有带长度的结构，属性编号只在内部编解码使用。Dart 对外按报文提供具名字段，不公开原始属性容器或编号查询接口。

保留 C 接入能力不等于承诺外部语言 SDK 或永久稳定的旧 ABI。破坏布局的修改必须更新
相应版本和校验，不依赖强转、旧字段偏移或已删除的业务桥接。

## 生命周期与交付

`create(options)` 创建资源，不建立连接。`startConnecting(listener)` 先绑定唯一监听器，
Future 只确认启动受理；Connected/ConnectFailed 等事件报告连接结果，事件可以早于
Future 完成。手动再次启动复用同一监听器，自动恢复沿用 Paho 重连机制。

每个 client 的业务事件串行交付；操作结果的处理独立于业务监听器，所以回调中可以
await publish、subscribe 或 close。不要在回调里等待下一条业务事件才能完成的响应。
监听器抛错保留原异常和堆栈，通过 MqttErrorEvent 报告；该错误事件的处理再次抛错时，
交给 Zone，不递归发送错误事件。队列溢出等终止错误会停止交付并启动资源关闭。

未连接时不接受新的业务发布。在线受理后遇到断网的操作可能等待恢复；取消或超时等待
不证明报文未发送。具名 disconnect 要求已连接，在连接尝试或重试等待期间失败且不
取消重试。终止这些状态使用 close；close 不保证发送特定 DISCONNECT 或触发遗嘱。

## 协议结果与连接属性

发布按 QoS 拆为 publishQos0/1/2。3.1.1 均返回 Future<void>；5.0 的 QoS 1/2 返回分别
包含 puback、pubrec/pubcomp 的结果，QoS 0 无 Broker ACK。成功类非零原因码保留原值；
失败确认抛出协议异常并保留已收到的确认。完成只代表客户端与 Broker 这一跳。

单项/批量订阅保留输入顺序、重复 filter 和逐项拒绝，业务可显式 requireAllAccepted。
5.0 退订保留逐项 UNSUBACK，3.1.1 只有整次完成。协议异常、本地错误与 errno 分域，
原因字符串只用于诊断，不能据此猜测错误类型。

MqttConnackProperties 保留本次实际 CONNACK 字段，未返回的可选字段为 null。
MqttNegotiatedSettings 结合客户端配置、响应和协议默认值，描述当前连接的有效设置；
自动重连也刷新快照。拒绝 CONNACK 保留原因及属性，DNS/TLS 失败不伪造 CONNACK。

MQTT 5 Clean Start 提供 always、firstConnection、never；firstConnection 在当前
client 首次成功后切换，重建实例重新计数。Broker 会话与本地持久化是独立概念，
Session Present=false 时应用应重建需要的订阅，SDK 不自动补订阅。

## 断开、限制与资源

MQTT 5 仅提供四个主动断开入口，原因由 C 层固定为 0x00/0x04/0x80/0x83。前三项说明
固定；0x83 可传 reason，省略/null/空字符串使用 `Implementation specific error`，
非空原样校验。服务端 DISCONNECT 不受发送侧四种原因限制，保留底层实际解析的数据。

四个方法及 3.1.1 正常断开均支持 drainTimeoutMs，默认 1000；它是 Paho 等待在途交换
的参数，不是对端 ACK 超时或严格墙钟期限。报文超限时明确失败，不删减固定说明。

共享 C/Paho 负责执行服务端 Receive Maximum、Maximum Packet Size、发布 QoS/retain
及订阅能力限制。入站在分配正文前检查报文大小；SDK/Paho 接收队列及 Dart 监听器队列
分别有界。Receive Maximum 不限制 QoS 0，也不代表业务消费背压或进程总内存上限。

属性受报文方向、白名单、重复次数、范围、UTF-8 和二进制长度约束。当前不开放 Topic
Alias 管理、AUTH、自定义接收 Receive Maximum、空 Client ID、WS/WSS、服务器列表和
自动重定向；有关功能列在 Todo 中，不通过原始属性旁路开放。

## 持久化、有效期与业务确认

两版共用二进制凭据、遗嘱、TLS、队列和持久化配置。磁盘存储按协议、完整 Broker URI、
clientId 隔离并加文件锁；restore/discard 作用于 Paho 创建时的消息恢复，不恢复旧
Future、监听器或业务关联。完整崩溃恢复和复杂 QoS 2 场景仍待专项验收。

Message Expiry Interval 是 MQTT 消息属性；没有完整的 SDK 本地排队/重发/恢复墙钟 TTL
保证。Response Topic/Correlation Data 只传输请求响应元数据，不隐式授权、分配回复
Topic、生成业务 ACK 或重试业务请求。详见 [会话与持久化](session-persistence-analysis.md)。

## Paho 适配与未完成验收

以 Paho C 1.3.16 的固定基线和三个基础补丁为输入，构建时生成隔离 overlay；
[补丁说明](patches.md) 记录输入要求和顺序，
[MQTT 5 适配](paho-v5-sdk.md) 记录 ACK/CONNACK、会话、重传配额和报文限制钩子。
有属性 ID 或编码函数不代表完整状态机已经实现，不能用同步 MQTTClient 的能力替代
MQTTAsync 路径验证。

现有测试覆盖正常路径及部分拒绝、断开、重连、限制与持久化场景；以下仍按 Todo 核对：

- QoS 2 各交换阶段重连、重复 ACK、Packet ID 复用和额度变化。
- 有限会话到期、服务端覆盖有效期后的清理及跨进程持久化恢复。
- 全路径分配失败、断开/关闭竞态、慢消费者和 QoS 0 洪峰。
- 畸形报文与精确诊断、ACK/PING 超限等底层分支。
- 本地 TTL 行为及尚未覆盖的模拟器 TLS 场景。

Android/iOS 模拟器是移动端运行验收环境，真机不是完成条件。独立 Kotlin/Swift SDK
不在当前验收范围；已有 Flutter/C 验证缺口也不会因此自动关闭。
