# MQTT 3.1.1 / 5.0 API 实施与核对 Todo

创建日期：2026-10-12；范围核对：2026-10-13。依据：[API 与实现设计](mqtt-api-v5-design.md) 及 Paho C 1.3.16 MQTTAsync 路径审查。已落实的底层修正见 [补丁说明](patches.md)，各条目的当前状态与剩余条件见实施记录。

状态：2026-10-12 已按要求先实施 Flutter、共享 C/Paho 与必要的平台引导。逐项实现、测试和剩余条件见 [Flutter 实施记录](mqtt-api-v5-flutter-progress.md)。Kotlin/Swift 业务 API 当前不支持，旧实现已于 2026-10-13 移除，未来可选支持统一记录为 MQTT-065。

移动端运行验收以 **Android 和 iOS 模拟器**为准（2026-10-12 用户确认）；真机测试不是完成条件。模拟器尚未覆盖的协议、生命周期或构建场景仍按具体场景登记，不能笼统记为“等待真机”。

以下 MQTT-001..058 复选框按 Flutter 与共享 C 层的当前范围验收；不再以 Kotlin/Swift 支持作为完成条件。范围调整不自动勾选任何条目，Flutter 尚未满足的协议、资源与故障验证仍按原 P0/P1 核对。

范围更新（2026-10-13）：独立 Kotlin/Swift API、业务桥接、SDK 打包和语言专项测试降级为 P2、未排期，不阻塞 Flutter 发布。C 中间层保留未来接入能力；Flutter 必需的平台引导仍属当前维护范围，不恢复旧 ABI/SDK 兼容。

## 使用约定

- 编号固定，后续新增项追加编号，不重排已存在编号。
- P0：协议正确性、生命周期或诊断完整性的发布前必做项；P1：初版 API、集成与交付必做项；P2：后续能力，本次初版不要求实现。
- 按“修改 + 对应验收通过 + 记录证据”完成后再勾选。不能只因接口声明存在就勾选。
- 有“验证后修补”字样的项目，先用测试确定具体缺口；若现有代码已满足要求，记录证据后可完成，不为完成 Todo 强行修改。
- 在末尾核对记录表登记日期、修改文件/提交、测试命令与结果、未解决限制。被替代或取消的项目保留编号，注明原因，不冒充已实现。
- Paho 路径以构建配置 `paths.paho_source`（或 `--paho-source`）为准；落地时记录基线及补丁。行号会变化，优先按函数定位。

## 已确认的设计约束

- 两版通过 package/module 区分，类名保留 MqttClient、MqttOptions 等。旧 API 不要求兼容，可直接修正不合理设计。
- 复用同一 C 核心和 Paho/OpenSSL；不复制生命周期、调度、线程等实现。
- MQTT 5 客户端主动断开只暴露四个具名方法（3.1.1 仅正常断开）；原因码由共享 C 核心填充，不开放任意整数原因或原始 DISCONNECT。
- 0x00、0x04、0x80 的 Reason String 由内部固定；0x83 的 reason 为可选参数，省略/null/空字符串时使用 `Implementation specific error`，非空原样保留并校验。
- 服务端 DISCONNECT 尽可能保留底层实际提供的信息，发送侧的四种限制不影响接收侧。
- MQTT ACK 不代表业务 ACK；SDK 不隐式创建回复 Topic、授权、回应业务请求或重试业务操作。

## A. Flutter API、ABI 与公共模型

- [ ] **MQTT-001 · P1：建立两版 package/module 入口。**
  修改位置：Dart exports 与 Flutter 包配置。验收：Flutter 可分别使用 3.1.1 和 5.0；同一程序同时导入时通过别名/模块限定区分，不链接重复原生库。

- [ ] **MQTT-002 · P1：统一公共类型并去除旧兼容负担。**
  修改位置：Flutter 类型定义及错误层。验收：两版共享一份 MqttQos、公共网络/TLS 类型；协议属性及 Broker 错误各自明确；隐藏属性编号查询、通用属性存储、原生构造参数和内部 Map，属性按报文提供具名字段；异常属性及批量结果类型明确；sealed 类型边界合法；旧整数 QoS、旧入口、示例和测试同步迁移。

- [ ] **MQTT-003 · P0：制定并实现统一 C ABI v2。**
  修改位置：`src/native/include/mqtt_api.h`、`mqtt_api_v2.h`、C 核心、Flutter bootstrap 与 Dart FFI。验收：配置、命令、属性和结果的布局一致；C 数据与事件能力保持可供其他语言绑定复用；版本/大小/capability 检查拒绝不匹配的绑定和原生库，不误读内存。

- [ ] **MQTT-004 · P0：实现属性的 SDK 自有表示及内存所有权。**
  修改位置：ABI v2、C 命令/事件复制与释放、Flutter 解码。验收：不暴露 Paho 指针；保留二进制长度、null 与空值、User Property 顺序与重复键；回调结束后快照仍有效；分配失败、取消、close 无泄漏或悬空指针；属性字节计入容量。

- [ ] **MQTT-005 · P1：按协议固定创建和连接路径。**
  修改位置：`mqtt_api.c` 创建/连接/响应/断开选项初始化。验收：创建阶段即指定协议和正确初始化器，5.0 使用 onSuccess5/onFailure5，3.1.1 使用相应回调；不混用 cleansession/cleanstart；不静默降级协议。

## B. 发布、订阅与确认结果

- [ ] **MQTT-006 · P0：修正发布成功 ACK 原因码与属性来源。**
  修改位置：Paho `MQTTAsync_cycle()` 成功发布回调分支及适配补丁。基线问题：未赋入实际 ackrc，properties 取自发送命令；overlay 已修正，按下述条件验收。验收：PUBACK=0x10 原样传出，ACK 属性来自接收报文，不能回显请求属性；失败确认仍完整。

- [ ] **MQTT-007 · P0：捕获 QoS 2 中间 PUBREC 及最终确认。**
  修改位置：Paho ACK 处理、C 操作上下文、发布结果。验收：成功/失败 PUBREC、PUBCOMP 的原因与属性按实际顺序记录；按 Packet Identifier 和操作生命周期关联；重复、重连、标识符复用、提前失败均不会串单或永久累积记录。

- [ ] **MQTT-008 · P1：实现两版 publish 结果与错误语义。**
  修改位置：C 结果事件、Flutter 发布 API。验收：按 QoS 拆为 publishQos0/1/2，不再传 qos；3.1.1 均返回 void，5.0 QoS 0 返回 void、QoS 1 返回带 puback 的结果、QoS 2 返回带 pubrec/pubcomp 的结果；移除通用 MqttPublishResult 和 completion。QoS 0 是本地发送完成，无伪造 ACK；QoS 1/2 对应实际完成阶段；失败类确认抛带协议上下文的错误；成功非零原因不误判失败；文档不称其为业务完成。

- [ ] **MQTT-009 · P1：补齐发送和接收消息属性。**
  修改位置：`mqtt_api.c` send/message 回调、Flutter 消息类型。验收：Response Topic、二进制 Correlation Data、消息过期、内容类型/格式和重复 User Property 双向传递；接收独有 Subscription Identifier 列表不能用于客户端发布。

- [ ] **MQTT-010 · P0：归一化单项/批量 SUBACK 路径。**
  修改位置：Paho 回调适配和 Flutter 订阅结果。验收：单项拒绝虽进入 onFailure/onFailure5，也归一化为条目结果；多项数组、单项 reasonCode 分别正确读取，不读无效指针；保持输入顺序及重复 filter；0x87 等失败不得被旧 `!=0x80` 判断当作成功。

- [ ] **MQTT-011 · P1：实现 MQTT 5 订阅选项与报文属性。**
  修改位置：MqttSubscription、MqttSubscribeProperties、responseOptions 映射。验收：No Local、Retain As Published、Retain Handling、整包 Subscription Identifier 正确编码；批量 subscribeOptionsList 长度匹配；不同标识符须分开请求。

- [ ] **MQTT-012 · P1：实现退订结果并保留两版差异。**
  修改位置：C UNSUBACK 适配、Flutter unsubscribe API。验收：5.0 单项从 reasonCode 读取、多项从数组读取，保留整包属性和逐项结果；No subscription existed 属于成功类结果；3.1.1 只报告整次完成，不伪造逐项原因。

- [ ] **MQTT-013 · P0：实现协议原因码与本地错误的分域。**
  修改位置：`mqtt_error.h`、`mqtt_diagnostics.c`、Flutter 异常。验收：保留原始数值、报文类型和属性；未知值不丢失；Paho 错误、errno 和 MQTT 原因码不混淆；Reason String 只用于诊断；requireAllAccepted/requireAllSucceeded 抛出的异常保留完整结果。

## C. CONNACK、会话和重连

- [ ] **MQTT-014 · P0：每次成功 CONNACK 都捕获完整属性。**
  修改位置：Paho `MQTTAsync_receiveThread()`、connected-session 补丁、C 连接事件。验收：首次/手动/自动重连均收到当前 sessionPresent 和属性，不能依赖成功后清空的 onSuccess5；不重复通知；context 属于 client 生命周期。

- [ ] **MQTT-015 · P0：保留失败 CONNACK 属性并协调诊断事件。**
  修改位置：Paho CONNACK/nextOrClose、diagnostics 补丁。验收：拒绝原因、Reason String、Server Reference、User Property 在报文释放前复制；首次和后续失败均只产生一次完整事件；DNS/TLS 失败不伪造 CONNACK。

- [ ] **MQTT-016 · P1：区分 CONNACK 原始属性与有效参数。**
  修改位置：MqttConnackProperties、MqttNegotiatedSettings。验收：缺省值与显式值可区分；按当前 CONNECT/CONNACK 计算 settings；参数有方向性命名；重连不继承上一连接缺失的属性，包括 Response Information。

- [ ] **MQTT-017 · P0：实现 Clean Start 三种策略。**
  修改位置：C 会话策略、Paho 受控扩展；现有 updateConnectOptions 只能改认证。验收：always/never/firstConnection 在首次失败重试、首次成功、自动重连、手动重连和对象重建后均按设计编码；不直接从高层访问 Paho 私有结构。

- [ ] **MQTT-018 · P0：同步 Broker 覆盖的 Session Expiry。**
  修改位置：Paho CONNACK、本地 sessionExpiry 状态、SDK settings。验收：服务端覆盖为 0/非零后，本地状态保留或清理与有效配置一致，不只是修改事件显示值。

- [ ] **MQTT-019 · P0：同步主动 DISCONNECT 修改的 Session Expiry。**
  修改位置：C 断开校验、Paho 关闭/会话状态路径。验收：本次有效值为 0 时不能改成非零；合法修改正确影响本次关闭的本地状态；校验/发送失败不把未生效值当作已确认结果；下次 CONNECT 使用明确的新连接配置。

- [ ] **MQTT-020 · P0：验证会话恢复、过期及本地在途状态。**
  修改位置：会话、持久化、自动重连测试，按结果修补。验收：有限过期、不过期 0xFFFFFFFF、Session Present=false、Broker 丢会话、进程重建均有结果；过期或会话丢失时不误续旧交换，订阅是否存在不靠客户端配置猜测。

- [ ] **MQTT-021 · P1：保留受理与连接成功分离的生命周期。**
  修改位置：Flutter create/startConnecting/listener 和 C 命令生命周期。验收：监听器先绑定，连接事件可早于启动返回；连接失败在事件中交付；初次失败和恢复重试计数一致；不引入额外的重连循环。

## D. 服务器能力、流控和属性校验

- [ ] **MQTT-022 · P0：验证并修正 Broker Receive Maximum 执行。**
  修改位置：Paho CONNACK、maxInflightMessages、恢复重发。验收：每次连接根据新限制重置有效额度，测试先小后大再变小；新限制在发送/恢复前生效；QoS 2 配额正确，不能只有 UI 显示更新。

- [ ] **MQTT-023 · P0：验证客户端 Receive Maximum 的实际接收约束。**
  修改位置：CONNECT 属性、Paho 入站 QoS 状态机。验收：声明值与实际处理一致，对超限有协议层处理；明确不限制 QoS 0 或业务待消费数量；未实现前不开放误导性配置。

- [ ] **MQTT-024 · P0：执行服务端 Maximum Packet Size。**
  修改位置：SDK/Paho 所有出站报文编码路径。验收：限制完整报文字节，包含固定头、属性和变长长度；发布、订阅、退订、断开及底层 ACK 等各路径有处理；超过限制不直接发出。

- [ ] **MQTT-025 · P0：执行客户端声明的入站最大报文大小。**
  修改位置：Paho 报文读取和缓冲分配、CONNECT 属性。验收：读取剩余长度后、分配大报文主体前限制；异常长度不会造成无界分配；不能只在 message 回调中检查。

- [ ] **MQTT-026 · P0：执行 Maximum QoS 和 Retain Available。**
  修改位置：发布、遗嘱及连接能力校验。验收：发布不超过服务器支持范围、禁用保留时不发送保留发布；遗嘱配置按协议处理；不错误禁止 SUBSCRIBE 请求高于服务器发布上限的 QoS。

- [ ] **MQTT-027 · P0：执行订阅能力和合法组合限制。**
  修改位置：订阅输入校验及能力快照。验收：通配符、共享订阅、订阅标识符按服务端能力处理；共享订阅 No Local=1 被拒绝；Topic Filter 语法、标识符范围符合协议。

- [ ] **MQTT-028 · P0：补齐按报文及方向的属性校验。**
  修改位置：C ABI v2 转换、Flutter 构造/受理校验。验收：允许属性、重复次数、数值范围、UTF-8、二进制长度和 Payload Format 均受控；不可借 User Property 或原始属性注入其他协议字段；不把 MQTTProperties_add 当完整校验器。

- [ ] **MQTT-029 · P1：明确拒绝初版未实现的协议能力。**
  修改位置：公共属性类型、capability、连接参数。验收：不开放 Topic Alias 发送管理，不宣告非零接收别名上限；不开放 AUTH/Authentication Method/Data；拒绝而非静默忽略；与未来 P2 扩展区分。

- [ ] **MQTT-030 · P0：验证并改进畸形报文诊断。**
  修改位置：Paho MQTTPacket_Factory、diagnostics 补丁。验收：构造格式/协议错误并检查实际结果；能获取的错误来源保留，不统统误报普通网络错误；不能承诺所有错误都有精确 DISCONNECT，也不开放业务发送 0x81/0x82。

## E. 四个主动断开 API 与服务端断开

- [ ] **MQTT-031 · P0：实现四个具名入口及固定原因映射。**
  修改位置：Flutter client、C ABI v2、共享 C 核心。验收：disconnect→0x00，disconnectWithWillMessage→0x04，disconnectWithUnspecifiedError→0x80，disconnectWithImplementationError→0x83；前三项固定说明一致；没有任意原因码/原始报文的业务旁路；3.1.1 仅提供正常断开。

- [ ] **MQTT-032 · P0：实现 0x83 可选 reason 的默认与校验。**
  修改位置：Flutter 参数、C 核心复制和校验。验收：省略/null/空字符串产生 `Implementation specific error`，原因码仍为 0x83；非空及纯空白原样保留；非法 UTF-8/超过 65535 字节拒绝，不静默截断；固定说明不可覆盖。

- [ ] **MQTT-033 · P0：校验断开属性和完整报文大小。**
  修改位置：MqttDisconnectProperties、C 校验/编码。验收：只接受会话有效期和 User Property 等已设计输入，不能塞入另一份 Reason String；固定说明或 0x83 reason 导致整包超限时明确失败，不静默删除说明，不误发其他原因。

- [ ] **MQTT-034 · P1：开放并正确解释 drainTimeoutMs。**
  修改位置：四个方法、3.1.1 disconnect、Paho timeout 映射。验收：默认 1000、范围 0..INT_MAX；其作用是等待出站在途交换，非 ACK 超时/全部队列排空保证/实时截止时间；到期处理可验证。

- [ ] **MQTT-035 · P0：实现断开状态机并消除失败副作用。**
  修改位置：C 命令受理/执行、Paho MQTTAsync_disconnect1。验收：受理后拒绝新业务请求；重复断开不覆盖首次原因；未连接/连接中/重试等待时拒绝且不修改 shouldBeConnected；与网络断开竞态无状态污染；close 可终止任意存活状态。

- [ ] **MQTT-036 · P0：定义未完成请求的断开、重连及关闭结局。**
  修改位置：C pending/result 队列、Flutter Future。验收：每项完成、失败或按明确策略等待恢复；close 后无永久悬空等待；取消/超时不被解释为“未发送/未执行”；不得重用失效命令 context。

- [ ] **MQTT-037 · P0：完整保留服务端 DISCONNECT 快照。**
  修改位置：MQTTAsync_setDisconnected、C 事件、Flutter MqttServerDisconnect。验收：保留实际原因码、说明、Server Reference、全部可取得的合法解析属性和重复 User Property；null/空值区分；回调返回后仍有效；不受主动发送四种限制。

- [ ] **MQTT-038 · P0：区分断开来源并协调事件去重。**
  修改位置：disconnected/connectionLost/diagnostics、连接历史。验收：local/server/transport 分开，本地原因不伪装成 serverDisconnect；一次逻辑断开只通知一次；连接序号/时间对应正确；重连不覆盖旧快照；容量/分配失败不静默丢诊断。

- [ ] **MQTT-039 · P1：明确 close、断开完成与遗嘱的边界。**
  修改位置：Flutter 文档、生命周期和 Broker 集成测试。验收：说明 Paho destroy 可能尝试正常断开；close 不保证触发遗嘱；DISCONNECT 完成不等于服务端收到；0x00 取消遗嘱，其余三种按协议和延迟处理；无遗嘱配置不产生遗嘱。

## F. 接收背压、队列与持久化

- [ ] **MQTT-040 · P0：验证接收回调、协议 ACK 和业务消费的时序。**
  修改位置：Paho QoS 入站路径、C message 回调、文档。验收：抓包验证返回 0 后 ACK 行为；明确只代表本地重投；SDK 不暴露虚假手动 ACK，不保证已确认但未消费消息会由 Broker 再次投递。

- [ ] **MQTT-041 · P0：约束 Paho 内部接收队列。**
  修改位置：Paho messageQueue、C 容量配置与溢出处理。验收：条数和总字节包含属性；慢消费者、超大消息、QoS 0 洪峰不无界增长；溢出策略明确且可观测；不能只限制 SDK 自身队列后宣称全链路有界。

- [ ] **MQTT-042 · P1：增加并协调 MqttQueueLimits。**
  修改位置：公共配置、MAX_PENDING/MAX_MESSAGES/MAX_BYTES 与 Paho create/connectOptions。验收：maxPendingOperations、maxBufferedPublishes、maxInflightPublishes、接收条数/字节边界独立清楚；SDK 已显式配置 buffered 默认 128；核对其与 pending/inflight 等各自边界；超限不自动删最旧消息。

- [ ] **MQTT-043 · P0：定义离线发送和已受理消息恢复行为。**
  修改位置：Paho sendWhileDisconnected/restoreMessages、C 发布受理。验收：初版不接受新的离线业务发布；在线受理后断网时的排队和重发有明确结果；不混同业务 outbox，也不承诺瞬时断网会撤销所有旧请求。

- [ ] **MQTT-044 · P0：隔离并保护本地持久化身份。**
  修改位置：持久化配置、路径生成、Paho create。验收：协议版本/Broker 身份/clientId 隔离；同一身份不并发打开；切换协议不静默读错或清空旧数据；内存与磁盘模式均覆盖。

- [ ] **MQTT-045 · P0：明确恢复和丢弃本地状态的策略。**
  修改位置：持久化 API、restoreMessages 与会话配置、恢复事件。当前 discard 映射 restoreMessages=false，只清理命令/接收队列，不保证清除已恢复的全部在途状态。验收：明确恢复/清理覆盖范围并验证与 Clean Start 的组合；进程重建不假装恢复旧 Future、监听器或 request_id；验证 QoS 0 持久化策略；close 不被写成“删除所有磁盘状态”。

- [ ] **MQTT-046 · P1：修正 duplicate 字段的文档保证。**
  修改位置：Flutter MqttMessage、示例与测试。验收：说明字段是 Paho 提供的重复标记，QoS 2 交付时可能归零；不称其为原始线上 DUP 无损副本，不作为业务去重 ID。

## G. 两版基础能力与消息有效期

- [ ] **MQTT-047 · P1：实现两版二进制遗嘱配置。**
  修改位置：MqttWillOptions、Paho will/willProperties 映射。验收：3.1.1 基础遗嘱、5.0 延迟/过期/格式/请求响应/用户属性正确；二进制及零长度 Payload 正确；重连配置稳定；0x04 与遗嘱联动验证。

- [ ] **MQTT-048 · P1：实现公共凭据与二进制密码。**
  修改位置：MqttCredentials、Flutter 编码、Paho binarypwd。验收：文本工厂明确 UTF-8；二进制含零字节不截断；未提供与空密码的标志位正确；凭据复制和释放正确，诊断不泄露密码。

- [ ] **MQTT-049 · P1：允许 Keep Alive=0 并验证覆盖逻辑。**
  修改位置：原 keep_alive_seconds 校验、Paho Server Keep Alive、settings。验收：0..65535 可用；0 不发送周期 PING；5.0 服务端覆盖生效；重连未返回该属性时恢复客户端请求值，不沿用旧值。

- [ ] **MQTT-050 · P1：核对传输支持范围。**
  修改位置：URI 校验、Paho 构建选项、TLS/WS 接入、Flutter 文档。验收：TCP/TLS 实际测试；WS/WSS 要么连同构建/必要配置验收后开放，要么明确拒绝；不因 URI 可解析就宣称支持代理或 HTTP headers。

- [ ] **MQTT-051 · P0：验证消息 TTL 的排队、重发和恢复语义。**
  修改位置：Paho 消息属性/发送队列/持久化、API 文档。验收：区分协议过期时间、本地排队 deadline、ACK 超时；测试本地排队后首次发送、断线重发、磁盘恢复、Broker 离线排队和保留消息；按协议核对需保留/更新的有效期，不擅自重置；TTL=0 不解释成永久。

- [ ] **MQTT-052 · P1：编写请求/响应使用示例并验证事件时序。**
  修改位置：Flutter 示例、Response Information 文档、集成用例。验收：先订阅并检查结果、先登记业务请求再发布；响应可能早于 publish 完成；串行监听器不等待由后续事件才能完成的业务 ACK；Session 丢失或回复地址变化由应用处理；SDK 不自动拼 Topic、授权或填业务 ACK。

## H. 验证、补丁与发布

- [ ] **MQTT-053 · P0：建立可控的报文级测试工具。**
  修改位置：`src/native/tests`、`scripts`。验收：能发送特定 CONNACK/ACK/DISCONNECT 属性和原因、部分拒绝、异常报文，断言客户端实际上行字节；能区分现有 Paho 缺口与封装缺口，不只依赖真实 Broker 的默认成功路径。

- [ ] **MQTT-054 · P0：完成 C 核心及内存/并发验证。**
  修改位置：C 单元/集成检查。验收：本清单 P0 的定向用例通过；深拷贝、队列满、分配失败、close/重连竞态和失效句柄检查；运行适用的 AddressSanitizer/UndefinedBehaviorSanitizer 检查，记录限制。

- [ ] **MQTT-055 · P1：完成 Flutter 两版协议与真实 Broker 验证。**
  修改位置：Flutter Android/iOS 测试、Broker 启停脚本。验收：QoS 0/1/2、消息属性、订阅/退订、会话恢复、自动重连、遗嘱和断开互通；3.1.1 回归完成；EMQX 特例不作为标准协议预期。

- [ ] **MQTT-056 · P1：整理最小 Paho 补丁及重放检查。**
  修改位置：`src/patches`、补丁说明和 CMake 检查。验收：记录依赖基线、补丁应用顺序、作用范围与测试；干净基线上可重放；新旧 session/diagnostics/trust 补丁无重复职责或回调冲突。

- [ ] **MQTT-057 · P1：同步 Android/iOS 构建产物和绑定。**
  修改位置：构建脚本、Android .so、iOS XCFramework、Flutter 插件 Gradle/CocoaPods 与 bootstrap。验收：ABI v2 一致；同进程两版只加载一份 native；构建信息/源码及补丁哈希可追溯；Release/AOT、JNI/R8 与 iOS 链接检查完成，Android/iOS 模拟器运行及未覆盖场景如实登记；真机测试不作为完成条件。

- [ ] **MQTT-058 · P1：同步文档并逐项关闭核对。**
  修改位置：本清单、API 设计说明、`README.md`、`docs/build.md`、平台说明、错误/会话说明。验收：旧入口与旧保证清除；属性及功能标注为真实已交付状态；每个已勾选编号都有修改和测试证据，剩余 P0/P1 不被混入“已完成”。

## I. 后续能力，仅记录，不阻塞初版

- [ ] **MQTT-059 · P2：Topic Alias 管理。**
  前置：MQTT-022..029。验收：双向独立映射、范围限制、重连清空、空 Topic 编码与解析、跨节点重连测试；完成前保持初版禁用。

- [ ] **MQTT-060 · P2：增强认证和重新认证。**
  前置：明确 MQTTAsync 的 AUTH 状态机扩展方案。验收：多轮认证、连接内重新认证、失败/超时、属性完整性及回调生命周期；不能用同步 MQTTClient 支持情况代替验证。

- [ ] **MQTT-061 · P2：异步凭据刷新。**
  修改位置：公共凭据提供器、重连策略、Paho updateConnectOptions 适配。验收：移动端异步刷新不阻塞 Paho 线程；取消/超时/关闭有结局；与增强认证区分。

- [ ] **MQTT-062 · P2：多服务器、代理及重定向策略。**
  修改位置：serverURIs、代理/WS 配置及策略。验收：故障切换时身份、TLS、会话和持久化边界明确；Server Reference 不被无条件自动跟随；每次实际连接地址可诊断。

- [ ] **MQTT-063 · P2：Broker 分配 Client ID 的完整模式。**
  修改位置：连接选项、Assigned Client Identifier、本地持久化身份。验收：空 Client ID 连接后采用实际分配值；自动重连和进程恢复复用策略明确，不只读取属性；与初版显式非空 Client ID 模式区分。

- [ ] **MQTT-064 · P2：业务请求/响应 helper 与本地 deadline/outbox。**
  修改位置：独立可选模块，不隐式改变基础 client。验收：订阅就绪、请求登记竞态、业务超时“不确定”语义、取消、重试、去重、持久化和截止时间明确；不复用 Packet Identifier 作业务 ID，不把 Broker ACK 当业务 ACK。

- [ ] **MQTT-065 · P2：未来评估独立 Kotlin / Swift API 支持（当前不支持，未排期）。**
  当前仅保留共享 C 中间层可复用的协议、属性、事件/通知、错误和生命周期能力，不新增语言 SDK 或恢复旧实现。未来明确启动后，再评审语言 API、JNI/Swift 适配、打包、文档与专项测试；沿用当时有效的 C ABI，不要求兼容已删除的 ABI v1/旧 SDK。本项不属于 Flutter 初版验收条件。

## 建议实施顺序和依赖

1. 先完成 MQTT-053 测试工具和 MQTT-001..005 的 API/ABI 基础；协议级复现用例可先于 API 实现。
2. MQTT-006..030：修补确认、连接、会话与限制，建立可靠的底层行为。
3. MQTT-031..051：落实四个断开入口、资源边界和共有能力；各项测试随修改完成。
4. MQTT-052..058：示例、跨端回归、可重放补丁和产物发布。P0 与 P1 都完成才宣称初版完成。
5. MQTT-059..065 按后续需求另行评估和排期。优先级表示必要性，不代表可忽略依赖独立发布。

## 完成与核对记录

当前清单：P0/P1 共 58 项，范围为 Flutter 与共享 C 层；P2 共 7 项（新增 MQTT-065）。Kotlin/Swift 不支持不构成当前未完成项；Flutter 自身的剩余验收条件见实施记录。

| Todo 编号 | 日期 | 修改文件/提交或无需修改的证据 | 验证命令与结果/日志位置 | 剩余限制 |
|---|---|---|---|---|
| MQTT-001..064 | 2026-10-12 | [Flutter 逐项记录](mqtt-api-v5-flutter-progress.md) | 主机报文、真实 Broker、ASan/UBSan、iOS 插件、Android/iOS AOT | 记录逐项区分已核对、部分和暂缓；历史记录以当时范围为准，当前按 Flutter 范围核对 |
| MQTT-001..058、065 | 2026-10-13 | 支持范围降级：当前仅 Flutter；Kotlin/Swift 归入未来 P2 | 文档范围核对，无代码变更 | 不自动关闭 Flutter 尚未通过验收的 P0/P1；未来语言 SDK 未排期 |
