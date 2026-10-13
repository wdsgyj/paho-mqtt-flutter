# Flutter 实施与核对记录

核对日期：2026-10-13。范围：Flutter 两版 API、共享 C/Paho 和 Flutter 必需的 Android/iOS 引导及产物。
Kotlin/Swift 业务 API 当前不支持，降级为未来可选能力（MQTT-065 · P2，未排期）；旧实现与
ABI v1 已移除。当前 Todo 的 P0/P1 按 Flutter 与共享 C 层验收，不以其他语言 SDK 为前提。
C 中间层保留后续绑定复用能力；Flutter 已实现但尚未完整验证的条目仍保持“部分”。

验收口径更新（2026-10-12）：按用户确认，以 Android/iOS 模拟器作为移动端运行验收环境，
不要求真机测试，也不将“未跑真机”列为阻塞项。协议/压力/故障注入等独立待办仍保留。

## 已落地的入口

- [mqtt311.dart](../src/flutter/lib/mqtt311.dart)、[mqtt5.dart](../src/flutter/lib/mqtt5.dart)、[公共类型](../src/flutter/lib/common.dart)。
- [Flutter 使用及限制](flutter.md)，包括四种断开、事件、持久化、ACK 和 TTL 边界。
- [C ABI v2](../src/native/include/mqtt_api_v2.h)、[共享核心](../src/native/core/mqtt_api.c)、[5.0 适配](../src/native/core/mqtt_v2_core.inc)。
- [Paho overlay](../scripts/overlay.go)、[可重放补丁](../src/patches/paho-mqtt5-sdk.patch)、[应用说明](paho-v5-sdk.md)。

标记 S/P 为此前的 sanitizer/补丁重放证据；最新产物的运行结果见文末。本轮文档整理未重跑运行测试。

状态：**已核对**表示表中列出的 Flutter 能力已有实现与相应测试；**部分**表示仍存在原验收
条件未覆盖；**暂缓**为 P2 或未开放的能力。不能把此记录解释为全部 P0/P1 已关闭。

## 验证入口

| 标记 | 用例/脚本（复现命令见构建说明） | 证据与用途 |
|---|---|---|
| W | `src/flutter/test/mqtt_v2_test.dart` | 可控 TCP fixture：真实 CONNECT/ACK/DISCONNECT 编解码、限制、恢复重传、持久化隔离；10 组 |
| B | `go -C scripts run . test --suite runtime` | C ABI v2 与 Flutter；Mosquitto TLS、QoS 0/1/2、二进制属性、持久会话、过期保留消息、遗嘱 |
| S | 此前的 `src/build/flutter-v2-asan` 构建 | 2026-10-12 历史 ASan/UBSan 证据（该目录已清理）；旧 ABI 移除后未重跑，不代表当前产物的 sanitizer 验收 |
| I | `go -C scripts run . ios-app --run` + iOS integration_test | 实际 Flutter iOS 插件 + 静态 XCFramework，未模拟 bootstrap |
| E | 同一报文 fixture + Android integration_test | Android 16/API 36 ARM64 模拟器，真实 Flutter/JNI/FFI 和 .so，10 组业务用例通过 |
| A | 历史 Release/AOT 构建（该命令已移除） | Release/AOT、JNI/R8、APK 内仅一份 MQTT .so 且 SHA-256 匹配 |
| X | 历史 Release/AOT 构建（该命令已移除） | iOS 无签名 Release/AOT 静态链接；插件直接链接 XCFramework |
| R | `go -C scripts run . test --suite all` | 原有错误、重连、批量订阅/退订专项；不把主测试中的环境性 skip 计为通过 |
| P | Git 基线 + 基础补丁 + `scripts/overlay.go`、`scripts/overlay_edits.go` | 2026-10-12 干净基线重放快照一致；Go 迁移后另行检查输出一致性 |

## 逐项记录

| Todo | Flutter 状态 | 修改/已验证内容 | 仍需核对或范围限制 |
|---|---|---|---|
| MQTT-001 | 已核对 | 两版入口同名类，通过别名同时使用；W/I/A/X | 独立语言 API 归入未来 MQTT-065，不阻塞本项 |
| MQTT-002 | 已核对 | 共用 QoS、TLS、凭据、队列和错误类型；删除旧 Dart 入口/客户端，错误模型与解码独立；Flutter 测试和 iOS 测试模板迁到 mqtt311 / ABI v2 | 独立语言 API 当前不支持，不阻塞本项 |
| MQTT-003 | 已核对 | ABI v2 配置/属性/函数表，版本和大小校验，Dart FFI 与真 iOS bootstrap；W/S/I/A/X | 旧 JNI/Swift 业务序列化已删除，仅保留 Flutter 引导 |
| MQTT-004 | 部分 | 自有属性结构，二进制/空值/重复属性深拷贝；C 用例验证销毁 client 后事件仍有效；B/S | 全分配失败注入、各路径 OOM 验证未完成 |
| MQTT-005 | 已核对 | create 固定 4/5，5.0 独立回调、cleansession/cleanstart；W/B | 不静默降级 |
| MQTT-006 | 已核对 | PUBACK 0x10 和实际接收属性；W 检查不回显请求属性 | — |
| MQTT-007 | 部分 | 成功 PUBREC/PUBCOMP 顺序快照，失败 PUBREC，入队前 token 关联；W | QoS 2 各重连阶段、Packet ID 复用和重复 ACK 矩阵待补 |
| MQTT-008 | 已核对 | publishQos0/1/2 按方法区分；3.1.1 均返回 void，5.0 QoS 1/2 返回具名确认字段；QoS 0 无伪造 ACK，协议错误保留上下文；W/B/S | MQTT 完成不代表业务 ACK |
| MQTT-009 | 已核对 | 请求/响应、二进制关联、过期、内容/格式、用户属性、接收订阅标识符；W/B | 接收独有字段没有发送入口 |
| MQTT-010 | 已核对 | 单项拒绝归一化，重复 filter、顺序、混合 SUBACK；W/R | — |
| MQTT-011 | 已核对 | No Local/RAP/Retain Handling 线上字节，整包订阅标识符；W | 标识符不同需分包 |
| MQTT-012 | 已核对 | 5.0 逐项 UNSUBACK 和 0x11；3.1.1 整次完成；W/B/R | — |
| MQTT-013 | 部分 | 协议错误有报文/原始原因/类型化属性及 ACK 列表；本地错误保留 info 域；W/R | 未知原因及所有拒绝分支矩阵待补 |
| MQTT-014 | 已核对 | 首次和自动恢复完整 CONNACK；W | 回调上下文使用 client 生命周期 |
| MQTT-015 | 已核对 | 拒绝 CONNACK 原因/说明/Server Reference，首次失败自动重试；W/R | 不为 DNS/TLS 伪造 CONNACK |
| MQTT-016 | 已核对 | 原始属性与有效 settings 分开，缺省重置；W 检查 Response Information、keepalive、Receive Maximum、expiry | — |
| MQTT-017 | 部分 | 三种策略已映射，firstConnection 首次失败/成功/自动恢复线上验证；W | always/never 与手动重连/重建全矩阵待补 |
| MQTT-018 | 部分 | CONNACK 覆盖同步到 Paho 本地 sessionExpiry，settings 测试通过；W | 覆盖为 0 后的实际状态清理专项待补 |
| MQTT-019 | 部分 | 0→非零拒绝、合法断开 expiry 传入 Paho；W | 发送失败竞态及本地清理的完整专项待补 |
| MQTT-020 | 部分 | 真实 Broker 持久会话恢复、原订阅及离线消息；B | 有限会话到期、0xFFFFFFFF、进程重建全矩阵待补 |
| MQTT-021 | 已核对 | 监听器先绑定、启动受理与结果事件分离；W/B/R | 共用 Paho 重连循环 |
| MQTT-022 | 部分 | 新 CONNACK 限制在恢复前生效，3→1 在途重发逐条验证；W | QoS 2 配额释放和多轮升降压测待补 |
| MQTT-023 | 已核对 | 未开放自定义客户端 Receive Maximum，C 也拒绝注入该属性 | 自定义接收配额状态机仍未实现；使用协议默认值 |
| MQTT-024 | 部分 | 精确业务报文预检、最终编码发送点限制所有报文；W 验证超大业务/断开拒绝 | 底层各 ACK/PING 超限分支专项待补 |
| MQTT-025 | 已核对 | 只发送超大 Remaining Length、不发送正文即被拒绝，资源错误且停止自动重连；W | 不宣称所有畸形包都有精确协议原因 |
| MQTT-026 | 部分 | 限制发布 QoS/retain，允许更高的订阅请求 QoS；W | Broker 遗嘱能力拒绝矩阵待补 |
| MQTT-027 | 部分 | 通配符/共享/订阅标识符能力、共享 No Local 和 filter 语法校验；W | 各共享订阅语法边界待补专项 |
| MQTT-028 | 部分 | 按报文白名单、重复限制、范围、UTF-8、二进制和 Payload Format 校验 | 原始 ABI 注入/畸形 UTF-8 的完整负例矩阵待补 |
| MQTT-029 | 已核对 | 不开放 AUTH/Topic Alias，C 属性白名单拒绝；声明接收别名上限为默认 0 | P2 保留 |
| MQTT-030 | 部分 | 超大包来源保留，部分协议失败保留上下文；W | 通用畸形包/fuzz 和 Paho 解析失败精确诊断待补 |
| MQTT-031 | 已核对 | 四个具名 API，C 固定码/固定说明，core submit 仅允许 CONNECT/CLOSE，禁止业务旁路；W/S | 3.1.1 仅正常断开 |
| MQTT-032 | 已核对 | 可选/空 reason 默认，非空及空白原样，NUL/UTF-8/长度校验；W | 不裁剪用户原因 |
| MQTT-033 | 已核对 | 受控断开属性、禁止注入第二个 reason、大小及 expiry 校验；W | 失败不隐式删去说明 |
| MQTT-034 | 部分 | 默认 1000、范围校验、0 映射；W；语义写入文档 | drain 到期时各在途阶段的实测待补 |
| MQTT-035 | 部分 | 区分 online 与 retry，离线断开不取消重试，受理时及执行前校验；W | 高并发网络断开/重复断开竞态压测待补 |
| MQTT-036 | 部分 | close 结束未完成 publish，生命周期/事件所有权；W/S | 全操作取消/超时/关闭交错矩阵待补 |
| MQTT-037 | 已核对 | 服务端 0x9C、说明、重定向地址、重复用户属性，回调外快照；W | 保留 Paho 实际可解析信息，不承诺畸形原始字节 |
| MQTT-038 | 部分 | local/server/transport，修复服务端 DISCONNECT 不触发 connectionLost 的通知缺口；W | 状态队列满/分配失败与事件去重压测待补 |
| MQTT-039 | 部分 | close/drain/遗嘱边界文档，真实 Broker 0x04 遗嘱；B | 0x80/0x83 与 Will Delay/Session Expiry 组合待补 |
| MQTT-040 | 部分 | 不提供虚假手动 ACK；明确本地重投和业务消费边界 | 原生回调返回 0 后 ACK 抓包专项待补 |
| MQTT-041 | 部分 | SDK/Paho messageQueue/Dart 监听器条数/字节限制与终止策略 | QoS 0 洪峰、QoS 2 入站状态及恢复队列的全链路内存压力验证待补 |
| MQTT-042 | 部分 | 各队列配置独立、Paho buffered/inflight 映射，不删除最旧消息 | 极限容量和所有层级交叉压力测试待补 |
| MQTT-043 | 已核对 | 离线新 publish 拒绝；已受理在途重连恢复，close 有结局；W | 不提供业务 outbox 或撤回承诺 |
| MQTT-044 | 部分 | 协议/URI/clientId 无损编码隔离，文件锁，重复打开/不同 Broker/跨协议/重开验证；W | 跨进程崩溃和文件系统别名专项待补 |
| MQTT-045 | 部分 | restore/discard 映射 restoreMessages、支持 persistQos0；discard 不等于全在途清理，旧 Future 不恢复 | 跨进程 QoS 0/1/2、discard 与 Clean Start 组合待补（见会话说明） |
| MQTT-046 | 已核对 | duplicate 明确为 Paho 标志，不承诺原始 DUP 无损或业务去重 | 文档验收 |
| MQTT-047 | 部分 | 两版二进制遗嘱，5.0 属性映射、真实 Broker 遗嘱；W/B | 零字节/空 payload 与 Will Delay 组合待补 |
| MQTT-048 | 已核对 | 公共凭据、文本 UTF-8 工厂、显式二进制密码/长度/存在标志；W | 诊断不包含密码 |
| MQTT-049 | 部分 | keepalive 0，CONNACK 覆盖和重连恢复原值；W | 长时间无 PING 抓包专项待补 |
| MQTT-050 | 已核对 | TCP/TLS 主机真实 Broker，WS/WSS 明确拒绝；B | 模拟器 TLS 场景仍需按具体用例核对 |
| MQTT-051 | 部分 | 消息过期属性和真实 Broker 保留消息过期；B，文档区分本地 deadline/ACK | 未实现完整本地排队/恢复的墙钟 TTL 扣减保证 |
| MQTT-052 | 已核对 | 请求/响应示例及约束，二进制关联字段实测；W/B/Flutter README | SDK 不隐式授权/分配回复地址/业务 ACK |
| MQTT-053 | 已核对 | 可控报文 fixture，混合/拒绝/非零成功/恢复/超限，断言实际线上字节；W/I | 更多 fuzz 用例可继续复用该工具 |
| MQTT-054 | 部分 | C v2 深拷贝、销毁后快照、失效句柄；B；S 为历史补充 | 全分配失败注入、线程竞态/压力验证待补 |
| MQTT-055 | 部分 | Flutter 主机真实 Broker，两端模拟器各 10 组实际插件测试通过；B/I/E/R | 更完整的模拟器 TLS/协议矩阵按具体用例补充；Kotlin/Swift 当前不支持，不在本项验收范围 |
| MQTT-056 | 已核对 | 固定基线隔离 overlay、快照补丁、干净重放一致；P | overlay 为 SDK 专用，不用于独立上游 Paho 链接 |
| MQTT-057 | 已核对 | Android/iOS 原生库、APK/无签名 AOT，两端模拟器运行，源码/overlay/二进制哈希；A/X/I/E | 本轮 Flutter 范围通过；真机非验收条件，Kotlin/Swift 当前不支持，不在本项验收范围 |
| MQTT-058 | 部分 | 本表、原 Todo、Flutter 使用说明、设计/补丁/主 README 更新 | 全部 P0/P1 未关闭，不声明初版全面验收完成 |
| MQTT-059 | 暂缓 | Topic Alias 管理未开放 | P2 |
| MQTT-060 | 暂缓 | 增强认证/重新认证未开放 | P2 |
| MQTT-061 | 暂缓 | 异步凭据刷新未开放 | P2 |
| MQTT-062 | 暂缓 | 多服务器、代理、自动重定向未开放 | P2 |
| MQTT-063 | 暂缓 | 空 Client ID 分配模式未开放 | P2 |
| MQTT-064 | 暂缓 | 业务 ACK/helper/deadline/outbox 未实现 | P2 |
| MQTT-065 | 未来考虑 | 独立 Kotlin/Swift API 当前不支持；C 中间层保留后续绑定能力 | P2，未排期，不阻塞 Flutter 验收 |

## 尚未关闭的重点

当前实现可用于继续评审和集成；仍需按原验收逐一完成压力/故障注入、完整会话与持久化
恢复、QoS 2 配额与重连矩阵、TTL 本地恢复行为、畸形报文诊断及尚未覆盖的模拟器运行场景。
这些 Flutter/C 协议与资源验证项目保留为 P0/P1；仅独立 Kotlin/Swift API 支持降级为未来 P2。


## 移除旧 SDK 后的验证（2026-10-13）

对象：移除独立 Kotlin/JNI/Swift SDK 后的 Flutter/C 实现；外层 ABI 2、core 版本 2。
此前验证结论如下；历史日志已清理，不作为分发产物保留。

| 检查 | 结果 |
|---|---|
| C host ctest | ABI、通知释放屏障、初始连接重试 3/3 通过 |
| TLS C runtime + Flutter | C 3.1.1/5.0 与 TLS 拒绝通过；Flutter 25 通过，3 个独立 fixture 用例跳过 |
| 独立 fixture | 错误/类型映射、重连、批量订阅退订分别通过，补齐上述跳过项 |
| Dart 静态检查 | format 完成，analyze 无问题；20 项内部访问被编译器拒绝 |
| Android Release/AOT | R8 打包通过，APK 中唯一 .so 与分发库 SHA-256 一致 |
| iOS Release/AOT | 插件直接链接 XCFramework，无签名 device 构建通过 |
| Android API 36 ARM64 模拟器 | 10 组报文用例通过，实际插件/JNI/FFI |
| iOS 18.5 ARM64 模拟器 | 10 组报文用例通过；静态引导、QoS 0/1/2、后台 isolate 另行通过 |

两端原生构建记录的源码 SHA-256 为
`4744b21ae5cd6c7a94c91579de58238ce97e5f5a6651d5920f6674b327d79667`。
后续源码变化应以重新生成的 build-info 和测试证据为准，不能只沿用此表。

2026-10-12 的 ASan/UBSan、平台信任矩阵及补丁重放记录属于此前实现的验证，未纳入上述
最新产物全量复验。当前清理保留了对应测试入口；压力、故障注入和完整恢复矩阵仍未全部
完成。复现命令集中在 [构建与测试说明](build.md)，避免多处维护不同命令。


## dist 目录迁移与自动清理验证（2026-10-13）

发布库统一到 `dist/android`、`dist/ios`，测试库、程序与 APK/app 统一到 `dist/test`。
仅保留 TLS 构建；Android Gradle 直接引用产物，iOS 通过 XCFramework 文件级目录链接
接入 CocoaPods。构建成功并校验最终产物后清理本次中间目录；失败保留排查现场。
历史非 TLS、独立 Kotlin/Swift、重复宿主构建目录已删除。

本次在新目录上重建并验证，结论如下（历史日志已清理）：

- macOS TLS 库与 C 检查程序可迁移运行；C 检查 3/3 通过。
- TLS C runtime 与 Flutter 25 项通过；错误、重连、批量订阅专项分别通过。
- Android / iOS Release 打包通过，Android 包内 .so 校验一致。
- Android API 36 / iOS 18.5 ARM64 模拟器各 10 组协议用例通过。
- iOS 静态引导、QoS 与后台 isolate 测试通过；host CA 目录加载测试通过。
- 构建目录边界、符号链接保护和发布失败保留旧产物检查通过。
- 成功后原生中间目录、Flutter 测试宿主及 host 测试缓存已实际清理。

本次修改构建、加载路径和清理流程，不扩大协议验收范围；此前尚未覆盖的故障、
压力与恢复矩阵仍保留。复现命令见 [构建与测试说明](build.md)。

## Go 构建工具、目录与符号验证（2026-10-13，历史验证）

本节记录旧 App 归档流程的验证结果；移动 App 及其归档现已删除，当前流程见文末和[构建说明](build.md)。

当前仓库根目录为 `src`、`scripts`、`docs`、`build`、`dist` 五类目录；详细文档
集中在 `docs`，入口 README 位于根目录。Python 构建、测试 fixture 和 Paho overlay 已替换为 Go 实现（YAML 配置解析使用 `go.yaml.in/yaml/v3`），
入口为 `go -C scripts run .`，不再依赖 Python。构建分为 `native`、`android-app`、
`ios-app`，App 命令只消费已校验的原生 Release 产物。

C 中间层、Paho、OpenSSL 始终使用 `-Os -g -DNDEBUG`；App Debug 只表示 Kotlin/Java、
Swift/Objective-C 与 Flutter 可调试，并不切换 C 编译模式。Release 与符号从同一次
构建提取，并由同一份 build-info 校验。详细目录、符号语义和命令见 [构建说明](build.md)。

本次验证结论如下（历史日志已清理）：

| 验证 | 结果 |
|---|---|
| Go 工具 | `go -C scripts test ./...`、`go -C scripts vet ./...` 通过；覆盖清理边界、发布失败保留旧产物、优化参数和构建中原生库变化检测 |
| Paho overlay | Go 输出与已审查的 MQTT 5 补丁逐文件一致；相邻 checkout 未改写 |
| 三端原生目标 | Android、iOS device/simulator、macOS host 均完成优化构建，包含从源码构建的静态 OpenSSL |
| host 原生检查 | C ABI、通知生命周期、初始连接重试 3/3 通过；产物移出构建目录仍可运行 |
| host 回归 | TLS C + Flutter 25 项通过；错误、重连、批量订阅专项均通过；CA 目录加载检查通过 |
| Android App | Release APK、Debug APK 构建通过；Debug ARM64 模拟器 10 组协议测试通过；两种 App 的 MQTT .so 与 Release 原生库完全一致 |
| iOS App | 未签名 device Release 和 ARM64 simulator Debug 构建通过；Debug 10 组协议测试、平台引导/QoS/后台 isolate 通过 |
| iOS 信任矩阵 | Go 创建的临时 iOS 18.5 模拟器通过矩阵测试，结束后已关闭并删除 |
| 符号 | Android `.debug` 与 `.so` Build ID 一致，实际解析到 `mqtt_api.c` 行号；macOS dSYM UUID 匹配；iOS App dSYM UUID 匹配且包含中间层、Paho、OpenSSL 的优化 DWARF |
| App Release 符号 | Android R8 mapping、两端 Dart split-debug-info 及匹配原生符号均已归档 |
| Dart | format、analyze 通过，20 项内部 API 访问检查通过 |
| 清理 | 每个成功构建保存并校验最终产物后删除自己的工作目录；旧目录和旧产物已清理 |

Release App 完成构建与符号验证；运行验收使用 Debug App 搭配同一 Release C 库，
不将模拟器 Debug 验收表述为 Release App 运行验收。本轮未扩大压力、故障注入与完整
恢复矩阵的已验收范围。

## native 目录收拢与 YAML 配置（2026-10-13，历史验证）

下述配置优先级已被当前的自动发现规则替代；移动 App 产物不再保留。

Go 模块已移至 `scripts/go.mod`（含 `go.sum`）；从根目录使用 `go -C scripts run .`。
CMake 入口与 C 测试分别迁至 `src/native/CMakeLists.txt`、`src/native/tests`，
Flutter App 夹具迁至 `src/flutter/integration`，移除独立 `src/tests`。
`src` 中 `native`、`flutter`、`patches` 为同级目录。

构建输入统一来自 `scripts/config/build.yaml`，模板为 `scripts/config/build.example.yaml`；本机配置
忽略提交。命令行参数优先，缺少所选目标必需的配置时，在创建工作目录前失败。
Paho 源码位置、NDK、OpenSSL、Dart 头文件及工具路径均可配置，具体字段见 [构建说明](build.md)。

本轮验证结论如下（历史日志已清理）：

- Go test/vet 通过；新增覆盖配置优先级、相对路径/空格、无环境变量兜底、缺失输入、
  未知/重复 YAML 键、目标独立校验，以及指定工具和 SDK 环境的子进程执行。
- 仅通过本机 YAML 配置完成 Android、iOS device/simulator、macOS host 原生构建；
  C/Paho/OpenSSL 仍为 `-Os`，C 检查 3/3 通过，库与符号匹配验证通过。
- Android/iOS wire Release App 构建通过；iOS runtime Debug simulator App 构建通过，
  匹配符号已保存。本轮未重新运行移动模拟器上的协议用例或 iOS 信任矩阵。
- host TLS C + Flutter 主回归 25 项通过、3 项环境性跳过；另行执行错误、重连、
  批量订阅专项和 CA 加载检查均通过。
- Dart format/analyze、20 项内部 API 访问检查、文档链接和目录布局检查均通过。
- 成功发布后自动清理各工作目录，验证结束时根目录 `build` 为空。

## 自动发现与临时 App 流程（2026-10-13，当前）

- README 已移至根目录；配置与模板位于 `scripts/config`。本机配置只包含 Paho、
  OpenSSL 和固定版本 NDK，工具优先从 PATH 查找，Java 优先读取 JAVA_HOME，
  Android SDK/Xcode 优先使用默认位置，Dart 和头文件跟随 Flutter SDK。
- 显式 CLI 参数优先，其次自动发现，最后 YAML 后备路径；源码与 NDK 使用 CLI/YAML。
- 移除测试 App 的 `--mode` 和发布归档逻辑，统一临时构建适合模拟器的 Flutter Debug
  App；所链接 C/Paho/OpenSSL 仍为 Release `-Os`。成功后删除 App 和临时符号。
- iOS 只发布未 strip 的 XCFramework，不重复保存静态符号归档；最终 App 负责生成
  dSYM 和 strip。Android 保存同次链接的 strip `.so` 和含完整 debug info 的 `.so`。
- 旧 `dist/test/android`、`dist/test/ios` 及 iOS 重复符号归档已删除。

本轮验证结论如下（历史日志已清理）：

- Go test/vet 通过，覆盖自动发现优先级、CLI 覆盖、配置回退、Flutter 符号链接和缺失输入。
- 三端原生构建通过；C 检查 3/3；Android ELF/Build ID、iOS 静态 DWARF 及产物清单校验通过。
- host C/TLS + Flutter 主回归 25 项通过、3 项环境性跳过；20 项内部 API 检查通过。
- Android ARM64 模拟器和 iOS 18.5 模拟器各 10 组协议测试通过；Android 的测试框架
  额外计入一个结果收集用例。APK 的库哈希、iOS 最终链接 DWARF/dSYM 检查通过。
- 本机 JAVA_HOME 指向 JDK 25，本次 Android 测试通过 `--java-home` 显式选择 Android
  Studio JBR；未修改环境或全局设置，也不将该结果视为 JDK 25 兼容性验证。
- 文档链接通过；构建及测试工作目录清空；dist 不含移动 App；本次启动的模拟器已关闭。

## 日志保留规则（2026-10-13）

历史报告目录已整体删除。构建与测试不创建 reports 目录，也不归档完整终端输出。
成功后清理本次工作目录及其中的临时日志；失败保留现场用于排查。文档仅记录验证
结论和适用范围，dist 只保留必需原生库、匹配符号和 host 测试环境。

## doctor 依赖检查

新增 `go -C scripts run . doctor`，默认检查全部构建及 host 测试工具；支持按目标或
原生平台筛选。复用自动发现、CLI/YAML 和原生/App 构建依赖定义，汇总缺失项并输出
实际使用的完整路径，不写入报告或构建目录。检查范围见[构建说明](build.md)。

文档和源码注释已核查本机专用绝对路径；示例使用相对路径或 `/path/to/...` 占位符，
保留自动发现依赖的标准系统默认位置。本机 YAML 配置与 IDE 自动生成状态不属于
共享文档或源码注释，不替换其中实际使用的路径。

## host 测试产物按需构建

`dist/test` 仅保留 `macos-arm64/release/libmqtt_sdk.dylib`，供直接 Flutter host 测试
加载。旧 C 可执行文件、CTest 配置、dSYM 和 build-info 已清理，后续不再发布这些文件。

`native --platform host` 构建并运行 CTest，只发布 strip 后的 dylib；发布前在内存中
校验副本 SHA-256，成功后清理临时目录。`test --suite runtime/errors/trust/all` 在临时
目录构建原生库和 C 测试，回归使用本次构建；`all` 只构建一次。成功后清理全部临时
程序、依赖及符号，不改写 dist 中的 dylib。单独 `reconnect/subscribe` 复用保留的 dylib。
`doctor --target test` 已补充临时原生构建的依赖检查。具体命令见[构建说明](build.md)。

本轮验证：Go test/vet、host 原生构建与 CTest 3/3 通过；临时构建的 `test --suite all`
通过主回归（25 项通过、3 项独立 fixture 跳过）、错误、重连、批量订阅和 CA 加载专项。
另行使用 dist 保留的 dylib 执行独立 subscribe 回归通过。测试结束后 dist 中动态库
哈希未改变，且为 dist/test 唯一文件；build 目录为空。未生成 reports。

## 依赖源码下载

新增 `download` 子命令，仅为缺少或无效路径的 Paho/OpenSSL 获取指定 tag 的浅克隆。
默认 Paho `v1.3.16`、OpenSSL `openssl-4.0.2`，下载至 `src/deps`；新 Paho 自动应用
基础补丁并验证 MQTT 5 overlay。终端显示 Git 进度和定时等待提示，完成后更新本机
YAML 的相对源码路径，保留其他配置和注释。详细用法见[构建说明](build.md)。

验证：实际下载两份官方 tag，Paho 补丁及 overlay 校验通过；以下载源码完成 host
构建和 CTest 3/3。Go test/vet 通过，覆盖精确 tag、配置创建/保留、并发修改保护、
已完成下载复用、无效 tag 和失败临时目录清理。doctor 已识别新路径。未生成 reports，
build 已清理，dist/test 仍仅保留 host dylib。

## macOS host dylib 导出收敛

host dylib 链接时只允许导出 `mqtt_get_api`，发布前执行 `strip -S -x`。构建在 CTest
之前以及 strip 之后校验导出列表，避免静态链接的 Paho/OpenSSL 暴露内部符号。
iOS 静态库仍保留完整符号。此次 host 产物由 9,374 个导出缩减为 1 个，文件由
5,356,912 字节降至 4,389,888 字节（约 18%）；大小以具体工具链和依赖版本为准。

验证：Go test/vet、C 检查 3/3 通过；直接加载裁剪后的发布 dylib，Flutter 24 项通过、
4 项专项环境跳过。完整 host 回归主套件 25 项通过、3 项跳过，另行执行错误、重连、
批量订阅及 CA 加载专项均通过。临时目录清空，dist/test 仍只保留 dylib，无 reports。
