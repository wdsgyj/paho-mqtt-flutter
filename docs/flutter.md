# Flutter MQTT 3.1.1 / 5.0

两版分别导入，公共类型位于 `common.dart`，共用一份 ABI v2 原生库：

```dart
import 'package:paho_mqtt_ffi/mqtt311.dart' as mqtt311;
import 'package:paho_mqtt_ffi/mqtt5.dart' as mqtt5;
```

原生库统一位于仓库根目录 `dist`：Android 直接打包
`dist/android/arm64-v8a/release/libmqtt_sdk.so`；iOS 经 `ios/Frameworks/` 内的符号链接使用
`dist/ios/release/CMqttSdk.xcframework`。本地依赖需保留完整仓库布局，单独复制 Flutter 包
不包含原生产物。应用只依赖此 Flutter 包，无需注册额外
JNI Gradle 工程或 Swift SDK pod。Dart 与原生库需匹配 ABI 2 / core 版本 2，拒绝旧布局。

独立 Kotlin / Swift API 当前不支持，列为未来可选能力（P2，未排期）；C 中间层保留
后续绑定的复用能力。产品插件仅支持 Android 和 iOS；macOS ARM64 动态库只用于 host
测试，不提供 Flutter macOS 产品插件。构建、目录及测试命令见[构建与测试](build.md)。

## 调试打印

配置、属性、消息、结果、连接事件和错误诊断模型均提供 `toString()`，输出类型名和具名字段，
嵌套对象也可直接读取。原因码保留十六进制显示；null 与空值可以区分。

```dart
print(client.options);
print(event);
print(result.puback);
```

密码、私钥口令和认证数据显示 `<redacted>`；Broker URI 去掉用户信息、查询参数和 fragment。
Payload、Correlation Data 等二进制字段仅显示字节长度；字符串最多预览 256 字符，列表最多
预览 8 项，超出时标明总长度。完整内容仍通过字段读取，打印不会修改模型。
User Property、topic 和错误文本作为调试信息保留，不自动判断其中是否包含业务敏感内容。
`toString()` 仅用于调试，不作为序列化格式或程序判断依据。

## 事件类型与监听注意事项

两版的具体事件类型名称一致，按下表处理：

| 事件 | 触发时机与区别 |
|---|---|
| `MqttMessage` | 收到 Broker 的 PUBLISH；QoS、RETAIN、DUP 描述接收这一跳，不代表业务处理完成 |
| `MqttConnected` | 当前客户端实例首次连接成功；即使此前自动重试过多次，首次成功仍是此类型 |
| `MqttReconnected` | 当前实例曾成功连接过，之后再次连接成功；自动和手动恢复都可能产生 |
| `MqttReconnecting` | 再次连接尝试开始，尚未成功；首次失败后的自动重试也会产生 |
| `MqttConnectFailed` | 一次尝试失败，且本实例从未成功连接过；首次成功前的每次失败都属于此类型 |
| `MqttReconnectFailed` | 一次尝试失败，但本实例曾成功连接过 |
| `MqttDisconnected` | 连接断开；不代表客户端已关闭释放，结束使用仍需等待 close() |
| `MqttErrorEvent` | 事件交付或业务监听器异常；普通操作失败通过其 Future 抛出，连接失败有专门事件 |

典型事件序列（启动受理成功后）：

```text
首次直接成功：Connected
首次失败后自动成功：ConnectFailed → Reconnecting → Connected
曾连接成功，掉线后恢复：Disconnected → Reconnecting → Reconnected
恢复失败后再成功：Disconnected → Reconnecting → ReconnectFailed → Reconnecting → Reconnected
```

这些序列展示连接事件；期间可能穿插消息，应用 close() 或终止错误也可能结束流程。
`automatic` 描述本次尝试来源，`willRetry` 描述事件产生时后续重试计划；两者不能互换。
`sessionPresent` 描述 Broker 是否恢复会话，与是否首次成功无关。重连成功但会话未恢复时，
应用按需重新订阅，SDK 不自动补订阅。5.0 每次成功后的 properties/settings 都取自本次连接。

连接历史字段是事件产生时的快照，统计范围是当前客户端实例。以下例子展示四个计数的区别
（两次恢复都由网络断开触发）：

| 事件 | connectionCount | reconnectCount | retryAttempt | totalRetryAttempts |
|---|---:|---:|---:|---:|
| 首次直接 Connected | 1 | 0 | 0 | 0 |
| 网络 Disconnected | 1 | 0 | 0 | 0 |
| 第一次 Reconnecting，随后失败 | 1 | 0 | 1 | 1 |
| 第二次 Reconnecting | 1 | 0 | 2 | 2 |
| Reconnected | 2 | 1 | 2 | 2 |
| 再次网络 Disconnected | 2 | 1 | 0 | 2 |
| 新一轮 Reconnecting | 2 | 1 | 1 | 3 |
| Reconnected | 3 | 2 | 1 | 3 |

connectionCount/reconnectCount 统计成功；retryAttempt/totalRetryAttempts 统计发起的重试，
包括成功重试及后续手动启动。首次成功前的自动重试同样计入重试次数。新实例所有计数重置。
5.0 主动断开和服务端 DISCONNECT 也会将 retryAttempt 清零，下一次重试从 1 开始；
totalRetryAttempts 始终跨周期累计。

sequence 是连接状态事件序号，从 1 开始；droppedEvents 是原生层累计未保留的状态事件数，
均不统计消息或操作结果。timestampMs 是事件产生时间，attemptStartedAtMs 是本次尝试起点，
disconnectedAtMs 是最近一次断开时间，单位均为 Unix epoch 毫秒。恢复成功后仍保留断开时间。
downtimeMs 使用单调时钟，表示本轮建立/恢复连接截至事件产生时的耗时，包含退避等待；
它不是单次握手耗时，也不是整个生命周期的离线总时长。

5.0 的失败事件只在收到拒绝 CONNACK 时有 reasonCode/properties；网络及 TLS 失败从 error
读取诊断。断开事件通过 source 区分 local/server/transport，只有 serverDisconnect 有值时
才能读取服务端实际发来的 DISCONNECT；3.1.1 没有这种服务端报文。

监听器串行执行，SDK 等待 onEvent 的 Future 完成后再交付下一条。可以在回调中 await
发布、订阅或 close 等操作，但不要等待由下一条事件才能触发的业务响应，否则会阻塞交付。
回调成功或抛错不控制 MQTT ACK，也不是业务确认。慢回调可能使有界队列溢出。

普通回调异常会转为 terminal=false 的 MqttErrorEvent；交付溢出等终止错误使用 terminal=true，
停止接收新的交付事件并启动关闭。处理 MqttErrorEvent 时再次抛错不会递归生成事件，而交给
Zone 未捕获异常处理器；应用仍应完成 close() 清理。不要依赖 close() 一定交付 Disconnected。

## 连接和请求/响应属性

```dart
final client = await mqtt5.MqttClient.create(const mqtt5.MqttOptions(
  serverUri: 'ssl://broker.example:8883',
  clientId: 'device-a',
  session: mqtt5.MqttSessionOptions(
    cleanStart: mqtt5.MqttCleanStartPolicy.firstConnection,
    expiryIntervalSeconds: 3600,
  ),
  connectProperties: mqtt5.MqttConnectProperties(
    requestResponseInformation: true,
  ),
));
final ready = Completer<mqtt5.MqttConnectionEstablished>();
final listener = mqtt5.MqttEventListener(onEvent: (event) {
  if (event is mqtt5.MqttConnectionEstablished && !ready.isCompleted) {
    ready.complete(event);
  }
  if (event is mqtt5.MqttConnectionFailure) {
    // 包含 error、willRetry，以及收到 CONNACK 时的原因码和属性。
    // 由应用决定等待后续重试还是终止；关闭前处理 ready 的等待者。
  }
});
await client.startConnecting(listener); // 仅表示启动受理。
final connection = await ready.future;
final hint = connection.properties.responseInformation;
// hint 是 Broker 提供的信息。应用按 Broker 约定确定并订阅回复 topic，
// 等待 SUBACK 接受后，才发送携带 responseTopic / correlationData 的请求。
```

示例使用 `dart:async` 的 Completer；消息 Payload / Correlation Data 使用
`dart:typed_data` 的 Uint8List。监听器先绑定再启动，连接结果和自动重连结果均通过事件
交付。手动重新连接复用同一监听器实例；重建客户端会重新执行 firstConnection 策略。
`properties`（`MqttConnackProperties`）保留 CONNACK 实际返回的属性，未出现的可选字段为
null；`settings`（`MqttNegotiatedSettings`）结合该响应、客户端配置和协议默认值，提供
本次成功连接的有效参数。两者分别用于核对原始响应和读取有效参数。

例如客户端设置 Keep Alive 为 60 秒，Broker 未返回 Server Keep Alive：

```dart
print(connection.properties.serverKeepAliveSeconds); // null：Broker 没有覆盖。
print(connection.settings.keepAliveSeconds);         // 60：沿用客户端配置。
```

| settings 字段 | CONNACK 省略对应属性时的来源 |
|---|---|
| `keepAliveSeconds` | 客户端 Keep Alive 配置 |
| `sessionExpiryIntervalSeconds` | 客户端 Session Expiry Interval 配置 |
| `serverReceiveMaximum` | 协议默认 65535，仅约束发往 Broker 的在途 QoS 1/2 发布 |
| `serverMaximumPacketSizeBytes` | MQTT 完整报文理论上限 268435460 字节 |
| `serverMaximumQos` | QoS 2 |
| 四个 `server…Available` 字段 | true |

这些参数在每次成功连接、重连时重新计算；已交付的快照保持不变。server 前缀表示服务端的
限制或能力，不表示客户端接收限制、本地队列限制或剩余配额。名称中的 Negotiated 也包括
协议默认值和服务端单方面声明的能力。

发布方法按 QoS 区分，不再接受 `qos` 参数：

| 方法 | 成功完成时机 | MQTT 3.1.1 返回值 | MQTT 5.0 返回值 |
|---|---|---|---|
| `publishQos0` | 本地发送完成，无 Broker ACK | `Future<void>` | `Future<void>` |
| `publishQos1` | 收到成功 PUBACK | `Future<void>` | `Future<MqttQos1PublishResult>`，含 `puback` |
| `publishQos2` | 收到成功 PUBCOMP | `Future<void>` | `Future<MqttQos2PublishResult>`，含 `pubrec`、`pubcomp` |

每个方法都支持 `retained`；5.0 额外支持 `MqttPublishProperties properties`。
5.0 的确认字段保存实际原因码和属性，结果无需再检查 QoS、完成枚举或遍历 ACK 列表。
失败抛出异常；5.0 协议拒绝使用该版本的 `MqttProtocolException`，其 properties 为
sealed `MqttResponseProperties`（实际为对应报文的具体类型），acknowledgements 是
`List<MqttPublishAcknowledgement>`，保存已收到的确认。成功表示客户端与 Broker 之间的相应交换完成，
不表示对端设备收到或业务处理完成。Response Topic 和二进制 Correlation Data
只负责传输元数据，SDK 不分配回复 Topic、不负责授权、不自动应答或重试业务请求。

在应用已经确定并获得授权的回复 Topic 上，最小发送流程如下（收到回复的处理写在上述监听器中）：

```dart
const replyTopic = 'devices/device-a/replies'; // 由应用与 Broker 的约定确定。
final subscribed = await client.subscribe(mqtt5.MqttSubscription(replyTopic));
subscribed.requireAllAccepted();
final correlation = Uint8List.fromList([0, 1, 255]);
// 应用在这里先登记 correlation 对应的业务等待者，再发布，避免快速回复竞态。
await client.publishQos1('devices/device-b/requests', Uint8List.fromList([42]),
  properties: mqtt5.MqttPublishProperties(
    responseTopic: replyTopic,
    correlationData: correlation,
  ),
);
// 设备 B 的业务代码显式向 responseTopic 发布回复，并回传 correlationData。
```

接收属性只暴露具名字段，业务无需查询 MQTT 属性编号：

| 使用位置 | 属性类型 |
|---|---|
| `message.properties` | `MqttReceivedPublishProperties` |
| `connected.properties`、连接拒绝的 `properties` | `MqttConnackProperties` |
| `result.puback.properties`、`pubrec.properties`、`pubcomp.properties` | `MqttAcknowledgementProperties` |
| 订阅/退订结果的 `properties` | `MqttAcknowledgementProperties` |
| `disconnected.serverDisconnect?.properties` | `MqttReceivedDisconnectProperties` |

```dart
final result = await client.publishQos1('devices/b/data', Uint8List(0));
final reason = result.puback.properties.reasonString;
final users = result.puback.properties.userProperties;
```

不再提供 `MqttProperties`、`number(id)` 或接受原生事件/属性列表的公开构造函数。
收到的属性、事件和结果由 SDK 创建；应用通过公开类型读取或模式匹配。
PUBLISH 不暴露不适用的 Reason String。连接历史通过 `connectionCount`、
`timestampMs` 等具名字段读取，不暴露内部 Map。协议原因码、报文类型和底层错误证据
仍保留用于诊断；这些信息与内部存储编号不同。

`MqttProtocolException` 按协议分别定义：3.1.1 的订阅拒绝通过 `result` 保留完整订阅结果；
5.0 的 `properties` 始终表示报文属性，订阅/退订拒绝的完整批量结果分别放在
`subscribeResult` / `unsubscribeResult`，不再将结果对象混入 properties。

单项/批量订阅都返回条目结果；重复 filter 和输入顺序保留，混合接受/拒绝不自动丢失
成功条目。可调用 `requireAllAccepted()` / `requireAllSucceeded()`；异常保留完整结果。
3.1.1 退订只有整次完成，不伪造逐项原因。订阅标识符属于整个 SUBSCRIBE 报文。

## 断开与关闭

| 5.0 方法 | 原因码 | Reason String |
|---|---|---|
| `disconnect()` | 0x00 | Normal disconnection |
| `disconnectWithWillMessage()` | 0x04 | Disconnect with Will Message |
| `disconnectWithUnspecifiedError()` | 0x80 | Unspecified error |
| `disconnectWithImplementationError(reason: ...)` | 0x83 | 传入值；省略/null/空字符串默认 Implementation specific error |

固定原因由 C 核心填充，没有任意原因码入口。0x83 的非空原因（含纯空白）原样保留，
非法字符串或超长内容拒绝。属性仅开放 Session Expiry 和 User Property；固定说明使
完整报文超出 Broker 限制时明确失败，不删减说明。未连接、连接中、重试等待时断开失败，
不会取消重试。已受理断开期间拒绝新增业务操作。

四个方法及 3.1.1 `disconnect` 都有 `drainTimeoutMs`，默认 1000，范围 0..INT_MAX。
这是 Paho 等待出站在途交换的间隔，不是对端 ACK 超时、精确实时截止时间或全部队列排空
保证。断开完成也不证明 Broker 已收到报文。需要终止任何状态时等待 `close()`；它使
未完成 Future 得到结局，且可重复等待。Paho destroy 可能尝试普通 DISCONNECT，因此
close 不保证触发遗嘱。0x00 取消遗嘱；其他原因受 Broker、Will Delay 和会话有效期影响。

`MqttDisconnected.source` 区分 local/server/transport。服务器 DISCONNECT 不受发送侧
四种原因限制，保留原始数值、Reason String、Server Reference 和可取得的属性快照。

## 队列、持久化和有效期

`MqttQueueLimits` 分别设置 pending、buffered publish、inflight、接收条数/字节上限。
SDK C 队列、Paho 本地接收队列和 Dart 监听器队列各自有界；不是整个进程 RSS 的硬上限。
Dart 队列按估算字节计入 topic、payload 和属性。监听器溢出交付终止错误并关闭客户端；
原生接收溢出终止重连，交付资源错误。初版不接受新的离线业务发布，在线受理后发生
断网的消息可能等待恢复，close 会使未完成操作结束。超时/取消等待不证明操作未发送。

Paho messageArrived 返回 0 表示本地重投，不是业务层延迟 MQTT ACK。已经获得协议 ACK
但尚未被应用消费的消息，不保证由 Broker 再次投递。duplicate 是 Paho 交付标志，
QoS 2 可能归零，不能作为原始线上 DUP 的无损副本或业务去重 ID。

```dart
persistence: mqtt5.MqttPersistenceOptions(
  directory: '/app-private/mqtt',
  onCreate: mqtt5.MqttPersistenceRestore.restore, // 或显式 discard
  persistQos0: false,
),
```

默认不使用磁盘；设置目录后，按协议、完整 Broker URI、clientId 隔离，通过文件锁排斥
重复打开。同一 Broker 的不同 URI 写法属于不同本地身份。路径须在应用私有可写目录，
磁盘模式拒绝含路径分隔符的 clientId。restore/discard 映射 Paho 创建时的 restoreMessages；
discard 清理命令/接收队列，不保证清除先前恢复的全部在途 QoS 状态。重建进程不会恢复
旧 Future、监听器或业务 request id。close 不等于删除磁盘数据。具体边界见
[会话与持久化](session-persistence-analysis.md)。
跨进程崩溃恢复和复杂重传验收仍见 Todo，不能用已测普通会话恢复代替。

Message Expiry Interval 是 MQTT 的消息有效期，不是本地队列 deadline，也不是 ACK
等待超时。已有 Broker 测试覆盖过期保留消息；Paho 本地排队、持久化和重发并未提供
完整的墙钟 TTL 扣减保证，不能把该字段当业务 outbox 截止时间。

## 支持边界与验证

移动端运行验收使用 Android 和 iOS 模拟器；真机测试不是完成条件。

开放 TCP (`tcp://`) / TLS (`ssl://`)，默认校验证书；Keep Alive 可为 0。
二进制密码区分未提供与空密码；遗嘱支持二进制及 5.0 属性。暂不开放 WS/WSS、增强认证、
Topic Alias 管理、空 Client ID 分配模式，以及尚未落实接收状态机的自定义 Receive Maximum。
最大入站报文在读正文前限制；出站完整报文按当前 Broker Maximum Packet Size 限制。
Broker Receive Maximum 在新发送和会话恢复重传时执行。

主机报文测试位于 `test/mqtt_v2_test.dart`，真实 Broker 用例位于
`test/mqtt_v2_broker_test.dart`。host 与模拟器复现命令见 [构建与测试](build.md)。
逐项完成情况和未覆盖的验收条件见 [实施记录](mqtt-api-v5-flutter-progress.md)。
