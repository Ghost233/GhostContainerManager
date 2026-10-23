# Flutter 桌面应用与 Apple container 通信路径调研（issue #7）

- 调研日期：2026-10-23
- 调研问题：Flutter 桌面应用如何与 Apple container（https://github.com/apple/container）通信？比较 (1) Swift 原生桥接（Flutter MethodChannel → `ContainerAPIClient` → XPC → `container-apiserver`）、(2) CLI（`container` 命令）进程包装两条路径，并核验参考项目 orchard（https://github.com/andrew-waters/orchard）的实际分工。
- 标注约定（沿用 docs/research/compose-plugin-integration.md）：**事实**＝一手来源（上游仓库源码 / README / 官方文档）直接写明；**推断**＝本文作者基于事实对本项目（Flutter + Apple container）的推导，需在设计任务中确认。
- 上游版本基准：apple/container `main` 分支源码（Package.swift 显示依赖 containerization `exact 0.53.0`，对应 1.6.x 之后的主干）；orchard 固定 apple/container **1.6.0**、containerization 0.52.1。涉及具体签名/行为处均已注明出处文件，实现时应按锁定版本复核。

## 结论摘要

1. **推荐主路径：Swift 原生桥接**。`ContainerAPIClient` 是 apple/container 仓库里公开可链接的 SwiftPM library product，覆盖容器全操作、镜像、网络、Mount（上游称 volume）、system ping/diskUsage、日志与 stats，经 XPC 直连 `container-apiserver`，返回强类型 Codable 模型——与 orchard 的主路径一致。
2. **CLI 包装作为必要补充**：`container system start/stop`（apiserver 未启动时没有 XPC 可连）、内核安装、builder 生命周期等必须走 CLI；CLI 的 `--format json` 覆盖列表/状态类命令，结构化解析成本低。
3. **CLI 的流式输出不适合程序化消费**：`container logs -f` 是裸文本行流，`container stats` 默认用 ANSI 交替屏幕清屏重绘；流式日志与 stats 均应走 XPC（FileHandle + 单次快照轮询）。
4. **签名/沙箱**：orchard 只声明 apple-events entitlement、未启用 App Sandbox（Developer ID 签名 + 公证分发）；若本项目启用沙盒，需 `com.apple.security.temporary-exception.mach-lookup.global-name` 例外才能解析全局 Mach 服务。**推断**：与 orchard 一致不启用沙盒是阻力最小的路径。
5. **CLI 陷阱**：`container system start` 在未指定 `--enable/--disable-kernel-install` 时会 `readLine` 交互询问安装内核，GUI 包装必须显式传 flag，否则抛 "failed to read user input"。

---

## 1. 背景：Apple container 的进程架构

**事实**：apple/container 的 CLI 把实际工作委托给注册在 launchd 用户会话中的 `container-apiserver`（Mach 服务名 `com.apple.container.apiserver`，launchd plist 的 `limitLoadToSessionType` 为 `[.Aqua, .Background, .System]`）。镜像服务是独立 XPC 服务 `com.apple.container.core.container-core-images`。

- 来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/System/SystemStart.swift （写 apiserver.plist、`ServiceManager.register`）
- 来源：https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/ContainerClient.swift （`XPCClient(service: "com.apple.container.apiserver")`）
- 来源：https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/ClientImage.swift

因此「与 Apple container 通信」实质上就是「与 apiserver 的 XPC 接口通信」；CLI 与 `ContainerAPIClient` 是同一份 XPC 协议的两种客户端。这决定了下面两条路径的本质区别只在客户端形态。

## 2. 路径一：Swift 原生桥接（MethodChannel → ContainerAPIClient → XPC）

### 2.1 ContainerAPIClient 是公开可链接的库

**事实**：apple/container 的 Package.swift 声明公开 library product：

```swift
.library(name: "ContainerAPIClient", targets: ["ContainerAPIClient"])
```

`platforms: [.macOS("15")]`，swift-tools 6.2；依赖含 containerization（`exact 0.53.0`）等十余个 SwiftPM 包。源码位于 `Sources/Services/ContainerAPIService/Client/`。

- 来源：https://github.com/apple/container/blob/main/Package.swift

**事实**：orchard 经 SwiftPM 直接依赖该库（Package.resolved 固定 apple/container 1.6.0，commit `ca4884f8…`），证明第三方 GUI 应用链接该库是已验证做法。

- 来源：https://github.com/andrew-waters/orchard/blob/main/Orchard.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

**推断**：Flutter macOS 工程的原生侧（macos/ Runner，Xcode 工程）可以用 SwiftPM 包依赖方式引入 `ContainerAPIClient`，桥接代码写在 Runner 或一个本地 Flutter plugin（Swift）里，经 `FlutterMethodChannel`/`FlutterEventChannel` 对 Dart 暴露。 orchard 是 Xcode 工程直链；Flutter 插件同样支持 SwiftPM 依赖，无机制障碍。实现时按 docs/engineering.md 要求核验实际版本与权限。

### 2.2 能力清单（按管理域）

以下均为 `Sources/Services/ContainerAPIService/Client/` 下公开类型的**事实**（来源目录：https://github.com/apple/container/tree/main/Sources/Services/ContainerAPIService/Client ）：

| 管理域 | 类型 / 方法 | XPC 路由（XPC+.swift） |
| --- | --- | --- |
| 容器全操作 | `ContainerClient`（public struct，连 `com.apple.container.apiserver`）：`create` / `list(filters:)` / `get` / `bootstrap(stdio:)` / `kill` / `stop` / `delete` / `createProcess`（exec 语义）/ `export` / `clean` / `resize` / `dial`（vsock）/ `copyIn` / `copyOut` / `diskUsage` | containerCreate/List/Bootstrap/CreateProcess/StartProcess/Wait/Delete/Stop/Kill/State/Resize/Export/Clean/CopyIn/CopyOut/Dial |
| 日志 | `ContainerClient.logs(id:)` 返回 `[FileHandle]`（fhs[0]=stdio、fhs[1]=boot） | containerLogs、containerEvent |
| stats | `ContainerClient.stats(id:)` 返回 `ContainerStats` **单次快照**（字段：cpuUsageUsec、memoryUsageBytes、memoryLimitBytes、networkRxBytes/networkTxBytes、blockReadBytes/blockWriteBytes、numProcesses）；流式由调用方轮询 | containerStats |
| 镜像 | `ClientImage`（连 `com.apple.container.core.container-core-images`）：`list` / `get` / `pull`（带 `progressUpdate` 进度回调）/ `push` / `tag` / `delete` / `save` / `load` / `platforms` / `fetch` / `unpack` / `calculateDiskUsage` / `cleanUpOrphanedBlobs` | 镜像走独立服务，不经 apiserver 路由表 |
| 网络 | `NetworkClient`：`create` / `list` / `get` / `delete` / `builtin` | networkCreate/Delete/List |
| Mount（上游称 volume） | `ClientVolume`；路由 volumeCreate/Delete/List/Inspect、volumeDiskUsage | volume* |
| system | `ClientHealthCheck.ping()` 返回 `SystemHealth`（appRoot/installRoot/logRoot/apiServerVersion/commit/build/appName）；`ClientDiskUsage`；`ClientKernel`（路由 installKernel/getDefaultKernel） | ping、systemDiskUsage、installKernel、getDefaultKernel |

- 来源（路由全集）：https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/XPC%2B.swift

**事实**：`ClientHealthCheck.loadContainerSystemConfig()` 的注释明确 "container system start MUST have previously been run"——即 apiserver 未启动时所有 XPC 调用不可用，必须先经 CLI 启动系统（见第 4 节）。

**事实（能力缺口）**：XPC 路由表**没有** system start/stop、system property、DNS 域管理、builder、内核推荐安装这些面；orchard 为补 `commit` 语义（1.6.0 CLI 也无此路由）自行实现 export → 打 OCI 包 → `ClientImage.load` + `unpack`。

- 来源：https://github.com/andrew-waters/orchard/blob/main/Orchard/Services/ContainerBackend.swift

### 2.3 日志与 stats 的消费方式

**事实**：`logs(id:)` 经 XPC 传回文件描述符（FileHandle 数组），不是订阅式事件流；apple/container 自己的 `container logs -f` 实现就是对这些 fd 挂 `readabilityHandler` 包一层 AsyncStream。

- 来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerLogs.swift

**推断**：桥接层把 FileHandle 的字节块经 `FlutterEventChannel` 推给 Dart 即可实现日志流；stats 在 Swift 侧按 2s/10s 轮询 `stats(id:)` 快照（ orchard StatsService 即此模式，可见时 2s、不可见时 10s，双快照差值算速率），或把快照逐次发给 Dart 由 Dart 轮询。

### 2.4 签名与沙箱约束

**事实**：orchard 的 `Orchard.entitlements` 只声明 `com.apple.security.automation.apple-events`（用于驱动 Terminal/iTerm），**没有** App Sandbox、也没有 mach-lookup 例外；README 记载 release 经 Developer ID 签名 + 公证分发，要求 macOS 26、Xcode 26/Swift 6.2。

- 来源：https://github.com/andrew-waters/orchard/blob/main/Orchard/Orchard.entitlements
- 来源：https://github.com/andrew-waters/orchard/blob/main/README.md

**事实**：Apple 官方 Entitlement Key Reference：启用 App Sandbox 后，解析全局 Mach 服务默认失败，需 `com.apple.security.temporary-exception.mach-lookup.global-name`（按服务名列入数组）；文件访问另有 `absolute-path/home-relative-path` 例外（`~/Library/Application Support/com.apple.container/` 在内核配置直读等场景会用到）。

- 来源：https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html

**推断**：本项目分发形态是 DMG + Developer ID 公证（非 App Store），沙盒不是硬性要求。与 orchard 一致**不启用 App Sandbox** 则无需任何临时例外；若未来要启用沙盒，至少需为 `com.apple.container.apiserver` 与 `com.apple.container.core.container-core-images` 申请 mach-lookup 例外，并核验 `sandbox-exec` 下 apiserver 对 fd 传递的兼容性。此项列入实现桥接时的核验清单（docs/engineering.md 要求核验系统权限）。

### 2.5 工程量评估（推断）

| 项 | 评估 |
| --- | --- |
| 依赖接入 | 低：Runner/插件加 SwiftPM 依赖，固定 apple/container 版本（参照 orchard 1.6.0） |
| 类型桥接 | 中：API 模型均 Codable，Swift 侧 `JSONEncoder` → Dart 侧 `dart:convert` 解码；清单（list/get）一次成形 |
| 命令通道 | 低-中：一个 MethodChannel 按域分方法；orchard 的 `ContainerBackend` protocol（约 20 个方法）可直接作为接口设计蓝本 |
| 流式通道 | 中：logs FileHandle→EventChannel；pull 进度回调→EventChannel；stats 轮询快照 |
| 版本适配 | 低-中：锁定上游版本；orchard 用 ping 解码失败特征（"failed to decode" + "health check"）检测版本不匹配，可借鉴 |
| 构建链 | 中：Swift 6.2/Xcode 26 工具链要求与 CI `macos-26` runner 一致；pubspec 已固定 Flutter 3.47.7/Dart 3.13.5 |

## 3. 路径二：CLI（`container` 命令）进程包装

### 3.1 结构化输出

**事实**：`ListFormat` 定义在 `Sources/ContainerResource/Output/ListFormat.swift`：

```swift
public enum ListFormat: String, CaseIterable, Sendable { case json; case table; case yaml; case toml }
```

放在 `ContainerResource` target 是为让数据模型不依赖 ArgumentParser（`ListFormat+ExpressibleByArgument.swift` 注释）。所有带 `@Option var format: ListFormat` 的命令均支持 `--format json/yaml/toml/table`，已核验包括：

- `container ls`（ContainerList.swift，payload 为容器资源 Codable）
- `container image ls`（ImageList.swift，payload 为 ImageResource；`-q` 仅 table 模式有效）
- `container system status`（SystemStatus.swift，StatusPayload Codable：status/client/server/host/paths/resources；apiserver 未注册或 ping 失败时 exit code 1）
- `container stats --format json --no-stream`（见 3.2）
- `container system dns ls --format=json`、`container system property list --format=json`（orchard 源码实际调用，见其 DNSService/SystemService）

- 来源：https://github.com/apple/container/blob/main/Sources/ContainerResource/Output/ListFormat.swift
- 来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerList.swift
- 来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/Image/ImageList.swift
- 来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/System/SystemStatus.swift

**推断**：列表/状态类只读场景用 CLI + `--format json` 的解析成本低（标准 JSON，退出码语义明确）；但创建/启动等写操作要拼很长的 argv（apple/container 自带的 CLI 参数解析器 Parser.swift 约 47KB，足见参数面之宽），类型安全与错误语义（人类可读错误文本）都不如 XPC。

### 3.2 日志与 stats 的流式消费

**事实**：`container logs [--boot] [-f/--follow] [-n]` 输出裸文本行（fd 直转 stdout），无 JSON 结构；`container stats` 默认 table 流式模式用 ANSI 交替屏幕转义序列（`\u{001B}[?1049h` 等）清屏重绘，不适合程序化消费；`--format json` 或 `--no-stream` 时走静态路径：对每个 running 容器取两次 `client.stats(id:)` 快照（间隔 2s 算 CPU delta）后一次性输出结构化 JSON。即 **CLI 自己也没有 stats 推送流，同样是轮询**。

- 来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerLogs.swift
- 来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerStats.swift

**推断**：GUI 若用 CLI 消费日志，只能按行解析裸文本（需自行分流 stdout/stderr、处理进程取消，orchard 的 `CommandRunner.runStreaming` 用 readabilityHandler + 取消时 terminate 可作参考）；stats 则须反复 spawn `container stats --format json --no-stream`（每容器每 2s 一次进程开销），明显劣于 XPC 单次快照轮询。

### 3.3 已知陷阱

**事实**：`container system start` 在未显式指定 `--enable-kernel-install` / `--disable-kernel-install` 时会 print 提示并 `readLine` 交互询问是否安装推荐内核；stdin 为 EOF 时 `readLine` 返回 nil 并抛 `internalError("failed to read user input")`。GUI 包装必须显式传 flag 或提供 stdin。orchard 裸跑 `["system","start"]` 不传 flag（推断其依赖用户已装内核，首启未装内核时会在该处失败）。

- 来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/System/SystemStart.swift

**事实**（orchard 的工程经验，值得直接吸收）：

- `CommandRunner.runWithSudo` 经 `/usr/bin/osascript -e 'do shell script "…" with administrator privileges'` 提权（逐 token 单引号转义）——DNS 域 create/delete 需要 root 时用；
- 进程 stdout/stderr 用 DispatchGroup 并发抽干，防 64KB 管道缓冲死锁。

- 来源：https://github.com/andrew-waters/orchard/blob/main/Orchard/Services/CommandRunner.swift

## 4. orchard 的分工核验（源码证据）

**事实**：orchard README「Architecture」段自述：主路径是 `ContainerAPIClient` Swift 库经 XPC 通信，"Every operation the API exposes goes over XPC; the remaining CLI-backed operations are the exceptions"。例外清单及原因：

| CLI 例外 | 原因（README 原文要点） |
| --- | --- |
| system start/stop/restart | daemon 注册进 launchd，未运行前没有 XPC 可连 |
| builder 生命周期 | API 没有 builder 面，CLI 在客户端侧编排 |
| system properties | 存在本地 defaults，不经 API |
| DNS domain create/delete | 需要 root，CLI 以管理员权限运行 |
| kernel 选择 | 安装推荐内核是 provisioning，API 无单一调用暴露 |

- 来源：https://github.com/andrew-waters/orchard/blob/main/README.md

**事实（Services 层源码布局与装配）**：orchard 为 Xcode 工程（非 SPM 包），服务在 `Orchard/Services/`，由 `AppServices.swift`（@MainActor）装配：

- 注入 `LiveContainerBackend`（XPC）的服务：ContainerListService、ImageService、NetworkService、StatsService、ComposeService；
- 注入 `SystemCommandRunner`（CLI）的服务：SystemService、BuilderService、DNSService、ImageBuildService、ClusterService。

- 来源：https://github.com/andrew-waters/orchard/tree/main/Orchard/Services （ContainerBackend.swift、AppServices.swift、CommandRunner.swift、CLIParsers.swift、BuilderService.swift、DNSService.swift、ImageService.swift、NetworkService.swift、ContainerListService.swift、ComposeService.swift）

**事实（XPC 主路径）**：`ContainerBackend` protocol 定义全 app 领域模型——listContainers/stopContainer/killContainer(signal)/deleteContainer(force)/bootstrapAndStart/runProcess(exec)/containerLogs(id)->[FileHandle]/exportContainer/stats(id)/createContainer(ContainerCreateSpec 含 volumes、ports、dns、cpus、memoryBytes、labels)/listImages/pullImage(带进度回调折叠为 ~10Hz 的 ImagePullMetrics)/deleteImage/inspectImage(重建 OCI index+manifest)/listNetworks/createNetwork/deleteNetwork/ping/diskUsage。`LiveContainerBackend` 直接用 `ContainerClient()`/`ClientImage`/`NetworkClient`/`ClientHealthCheck`/`ClientDiskUsage`；`supportedContainerVersion = "1.6.0"`；`isContainerServiceUnavailable` 匹配 "connection invalid"/"xpc connection" 等错误特征以区分「服务未启动」。

- 来源：https://github.com/andrew-waters/orchard/blob/main/Orchard/Services/ContainerBackend.swift

**事实（CLI 例外路径）**：

- `SystemService`：start/stop/restart 走 `runner.run(["system", verb])`（**非** sudo）；start 后轮询 `backend.ping()`（最多 10×0.5s）等 XPC 就绪；`checkSystemStatus` 用 XPC ping；内核配置直读 `~/Library/Application Support/com.apple.container/kernels/`，换内核走 CLI `system kernel set --recommended/--binary/--tar`；system properties 走 `system property list --format=json`。
- `BuilderService`：每 5s 轮询 `builder status --format json`；start/stop/delete 走 CLI。
- `DNSService`：注释 "backed by the `container system dns` CLI (create/delete require sudo)"；`dns ls --format=json` 读取，create/delete 用 osascript 提权；`/etc/resolver/containerization.<domain>` 全局可读无需 sudo；CLI 不能再写 daemon dns.domain（上游 issue #116），默认域存 app settings。
- `ImageBuildService`：注释说明 CLI 掌握了难点（启动/重启 BuildKit builder、dial、解包结果），故 shell 调用 `container build --progress plain` 并逐行流式进日志视图（transcript 上限 4000 行）。

- 来源：https://github.com/andrew-waters/orchard/blob/main/Orchard/Services/SystemService.swift 等（同上目录）

**核验结论（推断）**：issue 所述「orchard 主路径 XPC；system start/stop、builder、system properties、DNS 需 root、kernel 安装走 CLI」与源码**逐条吻合**，唯一修正是：DNS 只有 create/delete 需 root（osascript 提权），`ls` 不需要；system start/stop 不需要 root。compose 功能另经独立包 `andrew-waters/compose` 链接（见 docs/research/compose-plugin-integration.md），不在本工单范围。

## 5. v1 各管理域路径推荐

| 管理域 | 推荐路径 | 理由 |
| --- | --- | --- |
| 容器全操作（create/start/stop/kill/delete/exec/inspect/导入导出） | **XPC**（ContainerAPIClient） | 路由全覆盖、强类型模型、错误语义结构化；orchard 先例成熟。**推断** |
| 容器日志流 | **XPC**（`logs(id:)` FileHandle → EventChannel） | CLI 日志是裸文本行流，解析脆弱；XPC 拿 fd 与 CLI 内部实现同构。**推断**（基于事实 2.3/3.2） |
| 容器 stats | **XPC**（`stats(id:)` 快照 + Swift 侧 2s/10s 轮询） | CLI 流式是 ANSI 清屏重绘不可用；CLI 静态模式也是轮询且每轮 spawn 进程。**推断** |
| 镜像（list/pull/push/tag/delete/inspect） | **XPC**（ClientImage） | pull 自带进度回调（EventChannel 推送）；inspect 需重建 manifest，orchard 有现成算法可参照。**推断** |
| system 状态 | **XPC**（`ClientHealthCheck.ping` → SystemHealth）为主 | ping 同时给出 apiserver 版本与路径信息；ping 失败按 orchard 的错误特征区分「未启动/版本不匹配」。可用 `container system status --format json` 做诊断兜底。**推断** |
| system 启停 | **CLI**（`container system start/stop/restart`） | apiserver 未启动时没有 XPC 可连，**只能**走 CLI；start 必须显式传 `--enable-kernel-install` 或 `--disable-kernel-install` 避免交互式 readLine 卡死；启动后轮询 ping 确认就绪。**事实**（必要部分） |
| Mount（上游 volume）只读（list/inspect） | **XPC**（ClientVolume + volumeList/Inspect 路由） | 只读列表经 XPC 一次成形；v1 不做 create/delete 故无需 CLI。**推断** |
| 网络只读（list/get） | **XPC**（NetworkClient.list/get） | 同上；v1 不做 create/delete。**推断** |

**总体推断**：采用 orchard 同款混合架构——Flutter UI ⇄（MethodChannel/EventChannel）⇄ Swift 桥接层（链接 `ContainerAPIClient`，主路径 XPC；system 启停/内核走 CLI 进程包装）。v1 不需要 sudo 路径（DNS create/delete、builder 不在 v1 范围）。这与 docs/project-scope.md「Orchard 主路径 ContainerAPIClient+XPC，系统启停等部分操作使用 CLI」的记录一致，本调研将其细化到管理域粒度。

## 6. 风险与待确认项（留给设计/实现任务）

1. **版本锁定**：固定 apple/container 的具体版本（建议先对齐 orchard 验证过的 1.6.0）与 containerization 传递依赖；检测用户机器上 `container` 运行时版本不匹配的策略（orchard 的 ping 解码失败特征可借鉴，但是否可靠需实测）。
2. **沙盒决策**：不启用 App Sandbox（推荐，同 orchard）还是启用 + mach-lookup 例外；影响打包与公证配置。
3. **Flutter 插件形态**：桥接代码放 macos/ Runner 还是独立本地 plugin；SwiftPM 依赖在 Flutter macOS 工程中的接入与 CI（macos-26 runner、Xcode 26/Swift 6.2）核验。
4. **fd 传递边界**：XPC 返回的 FileHandle 在 Swift 桥接层消费（readabilityHandler）后经 EventChannel 推给 Dart，吞吐与背压需原型验证。
5. **内核首启流程**：`system start` 的 `--enable/--disable-kernel-install` 语义与首启 UX（下载内核进度如何呈现）需在 system 域规格中定义。
6. **运行时检测**：用户未安装 Apple container 时的发现路径（`container` 二进制位置、`CONTAINER_INSTALL_ROOT`、ping 失败特征）需实测确认。

## 7. 来源清单

apple/container（main 分支）：

- https://github.com/apple/container/blob/main/Package.swift （ContainerAPIClient 公开 library product、macOS 15、依赖锁定）
- https://github.com/apple/container/tree/main/Sources/Services/ContainerAPIService/Client （客户端源码目录）
- https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/ContainerClient.swift （容器操作、logs/stats、Mach 服务名）
- https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/ClientImage.swift （镜像操作、独立镜像 XPC 服务）
- https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/NetworkClient.swift （网络操作）
- https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/ClientHealthCheck.swift （ping/SystemHealth、system 须先启动）
- https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/XPC%2B.swift （XPCRoute 全集）
- https://github.com/apple/container/blob/main/Sources/ContainerResource/Output/ListFormat.swift （json/table/yaml/toml）
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerList.swift （`ls --format`）
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/Image/ImageList.swift （`image ls --format`）
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerLogs.swift （日志 fd + follow 实现）
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerStats.swift （stats 静态/流式两路径、ANSI 转义）
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/System/SystemStart.swift （launchd 注册、内核安装交互提示）
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/System/SystemStatus.swift （StatusPayload、exit code 1）

orchard（main 分支）：

- https://github.com/andrew-waters/orchard/blob/main/README.md （Architecture 段、系统要求、签名公证）
- https://github.com/andrew-waters/orchard/blob/main/Orchard/Orchard.entitlements （entitlements 实证）
- https://github.com/andrew-waters/orchard/tree/main/Orchard/Services （Services 层目录；ContainerBackend.swift / AppServices.swift / CommandRunner.swift / SystemService.swift / BuilderService.swift / DNSService.swift / ImageBuildService.swift / StatsService.swift）
- https://github.com/andrew-waters/orchard/blob/main/Orchard.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved （apple/container 1.6.0 锁定）

Apple 官方文档：

- https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html （mach-lookup.global-name 等沙箱临时例外）
