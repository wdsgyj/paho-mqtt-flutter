# 构建与测试

所有命令在仓库根目录运行。Go 1.23+ 模块位于 `scripts`，通过 `go -C scripts run .`
执行，不依赖 Python。原生库构建需要 CMake、Ninja、Perl、make、Paho/OpenSSL 源码和
Flutter SDK；Android 另需 NDK，iOS 需要 Xcode。移动 App 测试另需 Android SDK/JDK
或 CocoaPods，Broker 回归使用 Mosquitto。

## 目录与保留规则

```text
README.md    项目入口
build/       独立临时工作目录，成功后清理
dist/        原生库及其符号、host 测试环境
docs/        详细文档
scripts/     Go 模块、构建与测试工具
  config/    YAML 本机配置与模板
src/
  native/    C 中间层、CMakeLists.txt、jni/、tests/
  flutter/   Dart API、平台引导、test/、integration/（临时 App 夹具）
  patches/   Paho 补丁
  deps/      download 下载的源码（忽略提交，供后续构建复用）
```

移动测试 App 现用现构建，不发布到 `dist`，也不保存 App 的符号归档或 Release/Debug
副本。测试 App 统一使用 Flutter Debug 模式，iOS 面向 ARM64 模拟器；C 中间层及
Paho/OpenSSL 始终使用 **Release `-Os -g -DNDEBUG`**。`-g` 保留优化后的 debug info，
不改为 `-O0`。

原生构建校验并发布到 `dist` 后清理工作目录；App 命令完成构建、校验及可选运行后
删除整个临时目录。构建与测试输出直接写入终端，不创建 `dist/test/reports` 或归档日志；
测试 Broker 等临时日志只写入本次 `build` 工作目录，成功后一起删除。验证结论记录在
文档中。失败保留现场供排查。全局 SDK、Pub/Gradle 缓存和依赖源码不清理。
直接调用 CMake/Gradle 不触发 Go 工具清理。不要同时覆盖同一个原生产物；App 构建
也会检查使用的原生库是否被另一构建替换。host 回归请串行运行。

Flutter 包通过相对符号链接引用预编译库，使用本地依赖时须保留完整仓库布局，不能
只复制 `src/flutter`。

## 配置与自动发现

[配置模板](../scripts/config/build.example.yaml) 可填写已有源码和固定版本的 NDK 路径；没有源码时先运行 `download`：

```sh
cp scripts/config/build.example.yaml scripts/config/build.yaml
```

默认配置为 `scripts/config/build.yaml`（忽略提交），也可使用 `--config FILE`。
YAML 相对路径以配置文件所在目录为基准；命令行相对路径以命令工作目录为基准
（`go -C scripts` 时为 `scripts`）。支持 `~/`。

| 输入 | 默认查找顺序 |
|---|---|
| Go、make、CMake、Ninja、Perl、Git、Flutter、CocoaPods、Mosquitto 等工具 | `PATH` → YAML `tools.<名称>` |
| Java | `JAVA_HOME` → YAML `paths.java_home` |
| Android SDK | 当前用户的 `~/Library/Android/sdk` → YAML `paths.android_sdk` |
| Xcode | `/Applications/Xcode.app/Contents/Developer` → YAML `paths.developer_dir` |
| Dart 可执行文件 | Flutter 命令所在 SDK 的 `bin/cache/dart-sdk/bin/dart` → YAML `tools.dart` |
| Dart C 头文件 | 同一 Flutter SDK 的 `bin/cache/dart-sdk/include` → YAML `paths.dart_sdk_include` |
| Paho、OpenSSL 源码和 NDK | YAML `paths.paho_source/openssl_source/ndk` |

Flutter 路径支持符号链接；Dart 默认跟随该 Flutter SDK，不使用 PATH 中另一套 Dart。
工具能从 PATH 找到就不必写入 YAML。NDK 版本须明确指定；源码可手动配置，也可通过 `download` 获取固定 tag。
**显式命令行选项优先于自动发现和 YAML**，例如 `--java-home` 可以覆盖 `JAVA_HOME`。
如果环境变量指向无效 JDK，会报错，而不会悄悄改用另一套 Java。

只校验本次命令需要的输入：host/iOS 原生构建不需要 NDK，App 命令不需要 Paho 或
OpenSSL 源码。未找到必需输入、格式错误、未知/重复 YAML 键都会在创建工作目录前
报错。缺少默认配置文件时，只要自动发现和命令行已补齐所需输入，仍可执行；显式指定
的配置文件不存在则报错。工具选择仅作用于子进程，不改动系统或 Flutter 全局配置。

```sh
go -C scripts run . native --platform host --openssl-source /path/to/openssl
go -C scripts run . android-app --java-home /path/to/jdk
go -C scripts run . native --help
```

CMake 入口为 [src/native/CMakeLists.txt](../src/native/CMakeLists.txt)。直接调用 CMake
时需自行传入 `PAHO_SOURCE_DIR` 等依赖，不会读取 YAML。

## 下载依赖源码（download）

```sh
# 缺少或无效的源码才会下载；默认使用当前已验证的 tag：
go -C scripts run . download
# 显式指定 tag：
go -C scripts run . download --paho-tag v1.3.16 --openssl-tag openssl-4.0.2
# 仅准备一个依赖：
go -C scripts run . download --dependency paho
```

默认从官方 GitHub 仓库获取 Paho `v1.3.16`、OpenSSL `openssl-4.0.2` 的浅克隆，只
拉取指定 tag，保存至 `src/deps/paho-<tag>`、`src/deps/openssl-<tag>`。需要 Git 和网络。
终端显示 Git 下载进度，并每 5 秒输出等待提示；单次 Git 操作超过 30 分钟会终止。

已有有效源码路径会直接复用，tag 参数只决定新下载的版本。若需要改用指定 tag，可
显式清空相应路径，例如 `download --dependency paho --paho-source '' --paho-tag TAG`。
路径有效性按源码关键文件判断，不会修改或自动为已有用户源码打补丁。
新下载的 Paho 会按顺序应用三个基础 SDK 补丁，再验证 MQTT 5 overlay 可用；不兼容的
Paho tag 会失败，不能用更换 tag 代替升级适配工作。

每个依赖准备成功后，写回 `scripts/config/build.yaml` 中对应的源码路径，使用相对于
配置文件的路径。配置文件不存在则创建；保留已有工具/SDK 设置与 YAML 注释。
`--config FILE` 会读取并更新该文件，不另行改写默认配置。其他命令不会隐式下载。

下载先在 `src/deps` 的临时目录完成，校验成功才移到最终目录；失败会删除不完整的
下载目录，不写入该依赖的配置。已成功准备的另一个依赖及配置会保留。已存在的同名
目录只在仓库、tag 和补丁检查通过时复用，不覆盖未知内容。下载期间若配置被外部修改，
会保留完成的源码并拒绝覆盖配置，可再次运行命令。完整源码保留用于后续构建，不复制
到 dist，也不生成 reports；`src/deps` 已加入 Git 忽略规则。

## 构建前检查（doctor）

```sh
# 检查所有构建、host 回归和 API 检查所需依赖：
go -C scripts run . doctor
# 只检查当前需要的构建目标：
go -C scripts run . doctor --target native --platform android
go -C scripts run . doctor --target native --platform host
go -C scripts run . doctor --target android-app
go -C scripts run . doctor --target ios-app
```

`--target` 支持 `all`（默认）、`native`、`android-app`、`ios-app`、`test`、`check-api`。
`native` 可用 `--platform all|android|ios|host` 缩小范围。`test` 检查全部 host 回归所需工具与临时原生构建源码；
iOS 模拟器信任测试需另外检查 `ios-app` 依赖，或直接使用默认 `all`。

doctor 复用构建的配置和自动发现规则，支持相同的 `--config`、`--java-home` 等覆盖参数。
一次输出所有缺失或无效的依赖及修复参数，失败退出码为 1；正常项输出实际选用的完整
路径，符号链接另显示解析后的路径，全部就绪时退出码为 0。

检查仅涉及当前平台、工具文件可执行性、源码/SDK 目录及必需文件是否存在。它不执行
构建，不验证工具版本兼容性、Paho 补丁内容、预编译 dist 产物或模拟器启动状态，不生成
reports 或工作目录。通过 doctor 表示输入路径已就绪，不替代实际构建与测试。

## 1. 构建 C 中间层、依赖库和 host 测试环境

```sh
go -C scripts run . native --platform all
# 也可单独构建：
go -C scripts run . native --platform android
go -C scripts run . native --platform ios
go -C scripts run . native --platform host
```

只构建启用 TLS 的原生库，同时支持普通 TCP。OpenSSL 从源码静态编译。
Android 为 arm64-v8a（默认 API 21），iOS 为 ARM64 device/simulator（默认 iOS 15），
host 为 macOS ARM64。Flutter 宿主最低系统版本另受 Flutter engine 限制。

```text
dist/android/arm64-v8a/
  release/libmqtt_sdk.so      strip 后的运行库
  symbols/libmqtt_sdk.so      同一次链接的完整库，带 debug info
  build-info.json
dist/ios/
  release/CMqttSdk.xcframework 未 strip，包含完整 DWARF
  build-info.json
dist/test/macos-arm64/
  release/libmqtt_sdk.dylib    dist/test 下唯一保留的文件
```

Android 两份 `.so` 都是 `-Os` Release，Build ID 一致；`symbols` 中是完整 ELF，
不是另一套 Debug 构建，也不是只含符号的 `.debug` 文件。运行库写入 GNU debuglink。
macOS host dylib 在链接阶段仅导出 `mqtt_get_api`，Paho/OpenSSL 等内部符号不对外暴露；
发布前用 `strip -S -x` 去除调试信息及本地符号，构建过程检查导出白名单。该规则只用于
macOS host 动态库，iOS 静态库继续保留完整符号。host 不保存测试可执行文件、
dSYM、CTest 文件或 build-info。发布时在内存中校验动态库副本哈希，替换整个 `dist/test`
目录以清除旧产物。

iOS 静态库不做 strip，也不另存重复的符号归档。XCFramework 内的 `.a` 保留完整
DWARF；最终 App 链接时生成 dSYM，并由最终 App 构建执行 strip。构建时检查中间层、
Paho 和 OpenSSL 的代表性函数均保留 DWARF。静态归档没有最终 App 的加载地址和 UUID。

Android/iOS 的 `build-info.json` 记录文件 SHA-256、源码摘要、Paho 输入和优化配置。修改 C/ABI/补丁后
必须重建原生库。原生发布会整体替换对应目标目录，清除该目录内旧版冗余产物。

## 2. Android 临时测试 App

```sh
# 仅验证能否构建，成功后删除 App：
go -C scripts run . android-app
# 在已启动的 ARM64 模拟器上构建并执行测试，然后清理：
go -C scripts run . android-app --run --device emulator-5554
```

JNI C 引导代码与导出表位于 `src/native/jni`，由原生 CMake 编入 `libmqtt_sdk.so`；
Flutter Android 工程只编译 Kotlin 加载入口并打包预编译 `.so`，不编译 C 代码。

只消费已有 Android Release 原生库。默认 `--suite wire` 验证 MQTT 3.1.1/5.0；
`--suite smoke` 只构建接入检查 App。校验 APK 内只有一份 MQTT ARM64 `.so`，且其
SHA-256 与 `dist` 中 strip 后的 Release 库完全一致。App 使用测试签名，无 `--mode`
参数，不生成持久化 APK、R8 mapping 或 Dart AOT 符号。

## 3. iOS 临时测试 App

```sh
go -C scripts run . ios-app
go -C scripts run . ios-app --run --device "$MQTT_IOS_DEVICE"
go -C scripts run . ios-app --suite runtime --run --device "$MQTT_IOS_DEVICE"
```

只消费已有 XCFramework，构建 ARM64 simulator App；默认 `wire`，`runtime` 验证
真实平台引导、QoS 和后台 isolate。原生代码仍为 `-Os`。临时 App 链接后验证 dSYM
与 Mach-O UUID 匹配，并检查中间层/Paho/OpenSSL 的 DWARF；这些文件验证后一起删除。
`Runner.debug.dylib` 存在时使用其对应 dSYM。无需真机或签名证书。

## 回归与辅助命令

```sh
go -C scripts test ./...
go -C scripts vet ./...
go -C scripts run . check-api
go -C scripts run . test --suite all
# 可单独执行 runtime / errors / reconnect / subscribe / trust：
go -C scripts run . test --suite errors
```

涉及 C 测试的 `runtime/errors/trust/all` 会先在独立 `build` 子目录中编译所需 host
原生库、依赖和测试程序，运行 CTest；后续 C/Flutter 回归使用这次临时构建，成功后
全部删除，不向 dist 发布。`all` 一次构建后复用于各专项，因此比逐一运行更省时。
这些命令需要 Paho/OpenSSL/Dart 头文件及 host 构建工具，可用 `doctor --target test`
检查。单独的 `reconnect/subscribe` 以及直接 `flutter test` 使用 dist 中保留的 dylib，
需要先运行 `native --platform host`。失败保留临时现场，成功不保留测试程序或符号。

`runtime` 启动 TLS Mosquitto 并运行 C 和 Flutter 全套；错误、重连和批量订阅有独立
fixture，`all` 会补齐主套件中跳过的用例。`trust` 默认只检查 host CA 目录加载；
完整 iOS 信任矩阵使用临时模拟器，不修改 macOS 或已有模拟器的信任库：

```sh
go -C scripts run . test --suite trust \
  --ios-runtime com.apple.CoreSimulator.SimRuntime.iOS-18-5
```

Flutter 单独检查：

```sh
cd src/flutter
flutter analyze
dart format --output=none --set-exit-if-changed lib test integration
MQTT_TEST_LIBRARY="$PWD/../../dist/test/macos-arm64/release/libmqtt_sdk.dylib" \
  flutter test test/mqtt_v2_test.dart
```

host 测试统一通过 [native_bootstrap.dart](../src/flutter/test/support/native_bootstrap.dart)
加载动态库并安装自动清理的 MethodChannel mock；模拟器使用真实插件引导。

## 正式 App 的崩溃符号

Android 使用同一次构建的 `dist/android/arm64-v8a/symbols/libmqtt_sdk.so`，先确认
crash 的 Build ID 一致，再使用 NDK `llvm-symbolizer` 解析库内相对 PC：

```sh
/path/to/ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-symbolizer \
  --obj=dist/android/arm64-v8a/symbols/libmqtt_sdk.so 0xRELATIVE_PC
```

iOS 正式 App 应在自己的发布流程保存最终 App dSYM；先比较 crash 和 dSYM 的 UUID，
再使用 Xcode 符号化或 `atos`。本仓库临时测试 App 不归档：

```sh
xcrun atos -arch arm64 -o /path/to/App.dSYM/Contents/Resources/DWARF/App \
  -l 0xLOAD_ADDRESS 0xCRASH_PC
```

Dart AOT 符号、R8 mapping 同样由正式 App 的发布流程保存，与具体 App 版本对应。
