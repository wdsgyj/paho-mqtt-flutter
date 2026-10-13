# Flutter ABI v2 的 Paho 适配

依赖基线仍为 Paho C 1.3.16 / `4a939ddb01eea581a32fd6f0adcfee51b91d2601`，
通过 `download` 自动准备源码，或按 [基础补丁说明](patches.md) 手动应用
connected-session、platform-trust、diagnostics。
`go -C scripts run . overlay` 将该源码复制到每个构建目录的 `paho-sdk-source`，执行有基线
匹配检查的增量修改。不会写入相邻 Paho checkout，不要把新的补丁重复应用到该 checkout。

`paho-mqtt5-sdk.patch` 是脚本生成的可审查快照，SDK 编译以脚本为准：

- 在 CONNACK 释放前观察成功/拒绝属性；更新会话过期和当次 inflight 限制。
- 自动重连按共享核心的 Clean Start 策略生成报文。
- 在 publish 入队前关联 token，复制实际 PUBREC/PUBACK/PUBCOMP；修复成功 ACK
  回调回显请求属性，以及 PUBREC 属性副本释放。
- 已在途的 MQTT 5 消息恢复时执行当次 Broker Receive Maximum。
- 修复未连接 DISCONNECT 改写 shouldBeConnected 的副作用，应用合法的断开会话过期值。
- 限制 Paho messageQueue 的条数/字节，溢出诊断并停止自动重连。
- 读取 Remaining Length 后、分配正文前执行入站大小限制；最终编码发送点执行完整
  出站报文大小限制（包括 ACK/PING 和恢复消息）。CONNECT 不使用上一连接的服务端限制。

这些 hook 仅供 SDK 链接；不是上游 Paho 通用构建补丁。当前由 Flutter 两版协议 API
共用，使用 ABI 2 / core 版本 2；ABI 1 已删除。升级 Paho 必须重新核对字符串匹配、
状态机和报文测试。

重放检查：从 Git 基线在临时目录解包，依次应用三个既有补丁，再运行 overlay 脚本，
比较 overlay 输出源码与应用 `src/patches/paho-mqtt5-sdk.patch` 后的源码。
`go -C scripts test ./...` 包含此一致性检查（需要本机 Paho 输入）。原生 build-info 记录
源码/Go 工具的联合摘要、Paho 提交与工作树差异以及最终二进制/符号的校验值。
