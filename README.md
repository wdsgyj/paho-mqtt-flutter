# Flutter MQTT SDK 与实现说明

当前支持 Flutter MQTT 3.1.1 / 5.0，运行平台为 Android 和 iOS；共用 Paho C、OpenSSL
和一套异步 C 中间层。发布产物在 `dist/android`、`dist/ios`，`dist/test` 仅保留 macOS ARM64 host 测试动态库。C 测试程序与移动测试 App 现用现构建，
成功后清理。原生库仅构建 TLS 版本（同时支持
普通 TCP），iOS 静态库保留符号，Android 保存 strip 版和完整符号版。独立 Kotlin/Swift
API 当前不支持，列为未来可选能力（P2，未排期）。

| 要查的内容 | 文档 |
|---|---|
| Dart API、事件、发布结果与使用限制 | [Flutter 使用说明](docs/flutter.md) |
| 架构、C ABI 与行为约束 | [API 与实现设计](docs/mqtt-api-v5-design.md) |
| download 源码下载、doctor 检查、配置与构建测试 | [构建与测试](docs/build.md) |
| 错误类型及诊断 | [错误说明](docs/errors.md) |
| 系统/自定义 CA 与调试校验开关 | [TLS 信任策略](docs/tls-trust.md) |
| Broker 会话、本地持久化和业务确认的区别 | [会话与持久化](docs/session-persistence-analysis.md) |
| Paho 基线、补丁顺序与 overlay | [补丁说明](docs/patches.md) |
| 逐项验收条件 | [Todo](docs/mqtt-api-v5-todo.md) |
| 已有验证证据和剩余缺口 | [实施与核对记录](docs/mqtt-api-v5-flutter-progress.md) |

文档按当前实现维护：API 用法以 Flutter 说明和源码为准；尚未满足的验收条件留在 Todo
和实施记录中。构建成功或部分测试通过不代表全部 P0/P1 已验收。修改 API、支持范围或
构建路径时，应同步更新对应说明、命令和链接，删除被替代的用法；旧测试结果不能代表新产物。
