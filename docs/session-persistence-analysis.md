# 会话、本地持久化与业务确认

核对日期：2026-10-13。范围为本 SDK 使用的 Paho C 1.3.16 MQTTAsync 路径及 SDK overlay；
不以同步 MQTTClient 的行为推断 Flutter。当前配置入口见 [Flutter 说明](flutter.md)。

## 三种不同的状态

| 状态 | 保存在哪里 | 生命周期与用途 |
|---|---|---|
| Broker 会话 | Broker | 订阅、待投递消息及协议状态；受 Clean Session/Clean Start、Session Expiry 等控制 |
| Paho 本地持久化 | 客户端磁盘 | 保存 MQTT 在途交换、部分命令和接收队列；恢复协议状态，不是业务完成记录 |
| 业务 outbox/确认记录 | 应用自己的存储 | 由业务消息 ID、幂等与确认协议决定何时重试和删除；SDK 未实现该模块 |

Broker 保留消息按 Topic 保存，不属于某个 client 的会话，可以超过该会话生命周期；
MQTT 5 Message Expiry Interval、覆盖或删除保留消息等仍会影响它是否继续存在。

QoS 1 允许重复；QoS 2 的一次交付语义依赖一致的 MQTT 会话，不保证数据库写入或其他
业务副作用只执行一次。发布成功说明客户端与 Broker 的对应交换完成，不证明订阅端已
消费或完成业务。Response Topic/Correlation Data 需要应用显式回复才能构成业务确认。

## 当前 Flutter 配置

默认不启用磁盘持久化。提供 `MqttPersistenceOptions` 后，C 层使用
`MQTTCLIENT_PERSISTENCE_DEFAULT`，按协议版本、完整 Broker URI 和 clientId 隔离目录，
通过文件锁拒绝同一存储身份重复打开。URI 的不同写法属于不同身份，目录需私有且可写。

Broker 会话恢复需另行配置：

- MQTT 3.1.1 使用 `cleanSession: false`；默认 true。
- MQTT 5 使用合适的 Clean Start 策略和非零 Session Expiry；默认 always/0。
- firstConnection 只在当前 client 首次成功前清理；重建 client 后该计数重置。若需要
  尝试恢复先前实例的 Broker 会话，不能把 firstConnection 当作跨进程“第一次”。
- 无论采用什么配置，都应读取实际 Session Present。SDK 不自动重订阅，应用在会话
  未恢复时重新建立需要的订阅。

`onCreate: restore/discard` 当前直接映射 Paho `restoreMessages`。在
`MQTTAsync_createWithOptions` 中，`MQTTPersistence_initialize` 先恢复在途状态，随后
`restoreMessages=false` 调用 `MQTTAsync_unpersistCommandsAndMessages` 丢弃命令/接收队列。
因此 **discard 不等于清空全部磁盘状态或所有在途 QoS 交换**。与 Clean Start/会话清理的
组合及跨进程结果仍需 MQTT-045 验收，不能仅凭枚举名称承诺“全量重置”。

磁盘恢复不会重建旧进程的 Future、监听器或业务请求关联。close 用于结束资源，不等于
删除全部持久化文件；干净会话或有效期为 0 等条件可能触发 Paho 状态清理。

## Paho 保存与删除的协议记录

| 交换 | 主要持久化内容 | 正常交换中的移除时机 |
|---|---|---|
| 出站 QoS 1 | PUBLISH | 收到并处理 PUBACK |
| 出站 QoS 2 | PUBLISH，以及 PUBREC 后的 PUBREL 阶段 | 收到并处理 PUBCOMP；PUBREC 不是最终完成 |
| 入站 QoS 2 | 收到的 PUBLISH 状态 | 处理 PUBREL 并推进 PUBCOMP |
| 命令/应用接收队列 | 受 Paho 创建选项控制的队列项 | 命令完成、成功交付或明确清理 |

上述为正常路径，清理会话和失败原因码也会改变保留状态。应用 messageArrived 返回 0
表示本地再次交付，不是延迟 MQTT ACK；协议已确认的消息可能尚未被高层消费，断开后
不能保证由 Broker 再发一次。当前 SDK 不接受新的离线业务发布，在线受理后断网的操作
可能等待重连恢复。

## Broker 会话丢失

`sessionPresent=false` 表示本次没有恢复旧 Broker 会话，可能来自过期、服务端清理、
Broker 重启或其他同 Client ID 的干净会话连接。本地仍有文件不代表旧会话仍能续接。

当前 `MQTTAsync_completeConnection` 在 cleanSession/cleanStart 生效，或 3.1.1 及以上
协议的 Session Present 为 0 时调用 `MQTTAsync_cleanSession`。本 SDK 没有提供“Broker
丢会话后将旧 PUBREL 回退为新 PUBLISH”的可配置策略；不能假定未完成消息会自动转为
新的业务发布。需要保留业务发送意图时，由应用存储业务 ID 和待处理内容，并按业务确认
决定重试；重新发布可能产生重复，消费端仍需幂等。

## 持久化与过期的边界

默认文件后端不等于带 fsync 保证的事务日志。打开/恢复失败可报告 persistence error；
Paho 基线的 `MQTTPacket_send`（PUBREL）和 `MQTTPacket_sends`（QoS>0 PUBLISH）先写
持久化，再以 socket write 结果覆盖返回值。当前 overlay 未修正这类写失败传播路径，
不能把 publish 成功当作默认文件持久化可靠落盘的证明。

Message Expiry Interval 控制 MQTT 消息的协议有效期；Session Expiry 控制 Broker 会话，
二者都不是业务 ACK 等待超时。SDK 未提供本地排队、断网重发和磁盘恢复期间完整的墙钟
TTL 扣减保证，需要端到端截止时间的应用应另行定义业务 deadline。

## 源码核对与剩余验证

在相邻 Paho 源码中按函数定位，避免依赖会随补丁变化的行号：

- `MQTTAsync.c`：`MQTTAsync_createWithOptions` 的持久化初始化和 restoreMessages。
- `MQTTAsyncUtils.c`：`MQTTAsync_completeConnection`、`MQTTAsync_cleanSession`、`MQTTAsync_closeSession`。
- `MQTTProtocolClient.c`：PUBACK/PUBREC/PUBREL/PUBCOMP 处理。
- `MQTTPacket.c`、`MQTTPersistenceDefault.c`：报文持久化与文件后端错误传播。
- [SDK C 适配](../src/native/core/mqtt_v2_core.inc)：存储身份隔离、文件锁、配置与有效期。

目前已验证普通会话恢复、存储身份隔离和部分在途恢复；完整 QoS 2、文件写失败、跨进程
崩溃及恢复/丢弃组合仍未全部验收。相关项为 MQTT-007、020、044、045、051、054，见
[Todo](mqtt-api-v5-todo.md) 与 [实施记录](mqtt-api-v5-flutter-progress.md)。
