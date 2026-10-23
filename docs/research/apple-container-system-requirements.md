# Apple container 系统要求与权限事实调研

- 工单：GitHub issue #11（wayfinder 调研）
- 调研日期：2026-10-23
- 调研基准：`apple/container` 仓库 main 分支及各 release tag 的 README/文档/源码、`apple/containerization`、`andrew-waters/orchard`、Apple 官方开发者文档、GitHub API 元数据；另含本机实测（macOS 27.0.1 arm64，container 1.5.0，Homebrew 安装）。
- 标注约定：**【事实】**＝一手来源直接证实（附 URL）；**【实测】**＝本机执行命令验证；**【推断】**＝基于事实的推论，非官方声明。

---

## 一、macOS 版本与 container 版本矩阵

### 1.1 现行系统要求（main 分支，1.6.0 同）

- 【事实】需要 Apple silicon Mac：README 原文 "You need a Mac with Apple silicon to run `container`."
- 【事实】仅支持 macOS 26：README 原文 "`container` is supported on macOS 26 … We do not support older versions of macOS and the `container` maintainers typically will not address issues that cannot be reproduced on macOS 26."
- 【事实】macOS 15 上可运行但有显著限制，官方不计划修复（docs/technical-overview.md）：
  - vmnet 只能提供容器间隔离的网络，同一网络上的容器无法互相通信；
  - 无 `container network` 命令，`--network` 选项报错；
  - 容器 IP 子网可能与 helper 不一致导致断网（macOS 15 默认 CIDR 192.168.64.1/24）。
- 【事实】构建层面：Package.swift 声明 `platforms: [.macOS("15")]`（Swift 包部署目标）；BUILDING.md 要求 macOS 15+（推荐 26）+ Xcode 26。

来源：
- https://raw.githubusercontent.com/apple/container/main/README.md
- https://raw.githubusercontent.com/apple/container/main/docs/technical-overview.md
- https://raw.githubusercontent.com/apple/container/main/Package.swift
- https://raw.githubusercontent.com/apple/container/main/BUILDING.md

### 1.2 系统要求措辞的演变（各 tag README 逐字核对）

| 版本 | 发布日期（UTC） | macOS 要求表述 |
|---|---|---|
| 0.1.0（WWDC25 首发） | 2025-06-09 | 依赖 **macOS 26 Beta 1**；可在 macOS 15 运行，但有显著网络限制，维护者不处理只能在 macOS 15 复现的 issue |
| 0.2.0 / 0.3.0 | 2025-06-27 / 2025-07-30 | 同上（macOS 26 beta） |
| 0.4.1 | 2025-08-28 | 改为「仅支持 macOS 26（latest beta），不支持更旧版本」，不再提 macOS 15 |
| 0.5.0（PR #702 去掉 beta 字样） | 2025-10-02 | 定稿为「仅支持 macOS 26」，措辞沿用至今 |
| 0.6.0 → 0.12.3 | 2025-10-27 → 2026-04-30 | 同 0.5.0 |
| 1.0.0 → 1.6.0 | 2026-06-09 → 2026-10-20 | 同 0.5.0（"supported on macOS 26 … do not support older versions"） |

- 【事实】0.4.0、0.12.2、1.4.0、0.44.0 为无 release 的游离 tag（1.4.1 发布说明明确「1.4.0 tag 被废弃，本 release 包含其内容」）。
- 【事实】0.12.1（2026-04-29）修复了 macOS 15 (Sequoia) 网络 API 兼容问题——即 macOS 15 可运行性在 0.x 末期仍有维护性修复，但官方支持目标始终是 macOS 26。

来源（逐 tag README 核对）：
- https://raw.githubusercontent.com/apple/container/0.1.0/README.md （0.2.0/0.3.0/0.4.1/0.5.0/0.6.0/0.7.0/0.8.0/0.9.0/0.10.0/0.11.0/0.12.0/0.12.3/1.0.0/1.1.0/1.2.0/1.3.0/1.5.0/1.6.0 同路径换 tag）
- 发布日期：https://api.github.com/repos/apple/container/releases?per_page=100

### 1.3 完整 release 时间线（GitHub published_at，UTC）

| 版本 | 日期 | 版本 | 日期 |
|---|---|---|---|
| 0.1.0 | 2025-06-09 | 0.12.0 | 2026-04-27 |
| 0.2.0 | 2025-06-27 | 0.12.1 | 2026-04-29 |
| 0.3.0 | 2025-07-30 | 0.12.3 | 2026-04-30 |
| 0.4.1 | 2025-08-28 | 1.0.0 | 2026-06-09 |
| 0.5.0 | 2025-10-02 | 1.1.0 | 2026-07-06 |
| 0.6.0 | 2025-10-27 | 1.2.0 | 2026-07-29 |
| 0.7.0 | 2025-12-03 | 1.2.1 | 2026-08-07 |
| 0.7.1 | 2025-12-08 | 1.2.2 | 2026-08-08 |
| 0.8.0 | 2026-01-22 | 1.3.0 | 2026-08-24 |
| 0.9.0 | 2026-02-03 | 1.3.1 | 2026-08-29 |
| 0.10.0 | 2026-02-26 | 1.4.1 | 2026-09-09 |
| 0.11.0 | 2026-03-31 | 1.5.0 | 2026-09-29 |
| | | **1.6.0（当前最新）** | **2026-10-20** |

来源：https://api.github.com/repos/apple/container/releases?per_page=100

### 1.4 与 v1 决策相关的版本能力节点

- 【事实】**1.6.0（2026-10-20）首次引入 `container commit`**（issue #1399 / PR #1762）：将运行中容器自动快照后提交为镜像；docs/command-reference.md 已收录。同版其他变化：容器 DNS 别名（issue #457，`--network default,alias=api.test`）；`container build`/`builder` 拆为 CLI 插件（PR #2298）；多 worker k8s 集群（PR #2276）；2 个安全公告。
- 【事实】0.8.0：引入 `container system version`（含 `--format json`）——程序化检测的最佳入口。
- 【事实】0.10.0：`update-container.sh` 开始随包分发。
- 【事实】1.0.0：`~/.config/container/config.toml` 取代 UserDefaults（breaking change）；新增 `container machine`/`container cp`。
- 【事实】1.2.0：k8s plugin、`container export`、`build --ssh`、`--read-only-path`/`--masked-path`。
- 【事实】1.4.1：`container clean`；`system status` 输出扩展为 host/client/paths/resources。
- 【事实】1.5.0：修复增删 DNS `--localhost` 规则导致运行中容器外网中断（apple/container#2256）；移除 `k8s start`。

来源：
- https://github.com/apple/container/releases/tag/1.6.0 （及各 tag release notes，https://api.github.com/repos/apple/container/releases）
- https://raw.githubusercontent.com/apple/container/main/docs/command-reference.md
- https://raw.githubusercontent.com/apple/container/main/docs/networking.md

### 1.5 官方兼容性承诺（README "Compatibility"）

- 【事实】release 版本号是**产品版本而非 semver**。
- 【事实】CLI 在**同一大版本内**一般向后兼容（experimental 功能如 k8s 除外）。
- 【事实】`container-apiserver` 的 XPC API 在**同一大版本内**保证前后兼容；其他非公开 XPC helper 不保证跨版本兼容。
- 【事实】应用数据只保证一个大版本内的前向兼容。

来源：https://raw.githubusercontent.com/apple/container/main/README.md

---

## 二、需要 root / 特殊权限的操作（逐项）

| 操作 | 权限要求 | 依据（来源见下） |
|---|---|---|
| 安装 / 卸载官方 pkg（写 `/usr/local`） | **需管理员密码** | README "Initial install"；Makefile `install` = `sudo installer -pkg … -target /` |
| `container system start` / `stop` / `restart` | **不需要 root** | apiserver 是 per-user launch agent；`launchctl bootstrap gui/<uid>` |
| 首次安装推荐内核 / `container system kernel set` | **不需要 root** | 经 XPC 由 apiserver 处理，内核存 per-user 目录；brew caveat 亦以普通用户执行 |
| 日常容器操作（run/build/pull/images/volume/registry/login 等） | **不需要 root** | command-reference 全文仅 dns create/delete 标注需管理员 |
| `container network create`（vmnet，仅 macOS 26+） | **不需要 root** | 文档无 sudo 标注；helper 仅携带 `com.apple.security.virtualization` entitlement |
| `container system dns create` / `dns delete` | **需要 sudo（管理员）** | command-reference 标注；机制见 2.2 |
| `container system dns ls`、编辑 `config.toml` 的 `[dns]` | 不需要 | 只读命令 / 用户级配置文件 |
| KDK（Kernel Development Kit） | **官方从未要求** | 两仓库 README/BUILDING/tutorial 及 commits/issues 搜索均 0 命中 |

### 2.1 `system start/stop` 不需要 root 的机制（源码级）

- 【事实】`container system start` 把 launchd plist 写到 `<appRoot>/apiserver/apiserver.plist`（label `com.apple.container.apiserver`，RunAtLoad=true，MachServices 注册 XPC 服务名，LimitLoadToSessionType=[Aqua, Background, System]），然后 `launchctl bootstrap gui/<uid> <plistPath>`；plist **不在** `/Library/LaunchDaemons`，也**不复制到** `~/Library/LaunchAgents`。appRoot 默认 `~/Library/Application Support/com.apple.container`。
- 【事实】`system stop` 先 ping apiserver、停止所有容器（SIGTERM，5s 优雅期、最长等 20s），再 `launchctl bootout`。
- 【实测】本机 `/Library/LaunchDaemons` 无 container 项；brew 场景仅有 `~/Library/LaunchAgents/sh.brew.container.plist`（brew services 的 keep-alive 包装，ProgramArguments 为 `container system start --disable-kernel-install`）。

来源：
- https://raw.githubusercontent.com/apple/container/main/Sources/ContainerCommands/System/SystemStart.swift
- https://raw.githubusercontent.com/apple/container/main/Sources/ContainerCommands/System/SystemStop.swift
- https://raw.githubusercontent.com/apple/container/main/Sources/ContainerPlugin/ServiceManager.swift
- https://raw.githubusercontent.com/apple/container/main/Sources/ContainerPlugin/ApplicationRoot.swift

### 2.2 DNS create/delete 需要 sudo 的机制（源码级）

- 【事实】`HostDNSResolver.swift` 的 defaultConfigPath = `/etc/resolver`（root 所有），写入 `containerization.<domain>`（内容含 `nameserver 127.0.0.1`、`port 2053`；`--localhost` 模式为 port 1053 + `options localhost:<ip>`），随后执行 `/usr/bin/killall -HUP mDNSResponder` 让系统 resolver 重载——mDNSResponder 以 root 运行，普通用户无权 signal。失败提示即 "cannot create domain (try sudo?)"。
- 【事实】`--localhost <ipv4>` 模式还通过 PacketFilter 写 pf 重定向规则（DNSCreate.swift）；host-integration.md 注明：创建 localhost 域会**禁用 Private Relay**，且 pf 规则在重启后消失。
- 【事实】`/etc/resolver/containerization.<domain>` 文件本身 world-readable，读取解析无需 sudo（orchard DNSService 即如此实现）。

来源：
- https://raw.githubusercontent.com/apple/container/main/Sources/Services/ContainerAPIService/Client/HostDNSResolver.swift
- https://raw.githubusercontent.com/apple/container/main/Sources/ContainerCommands/System/DNS/DNSCreate.swift
- https://raw.githubusercontent.com/apple/container/main/docs/host-integration.md
- https://raw.githubusercontent.com/apple/container/main/docs/tutorials/start-here.md

### 2.3 内核安装不需要 root；KDK 不是官方要求

- 【事实】container **不使用 macOS 系统内核**：每个容器是轻量 VM，自带 Linux 内核（containerization README："A Linux kernel is required for spawning lightweight virtual machines on macOS"）。默认内核为 Kata Containers 预编译内核，从其 GitHub releases 下载。
- 【事实】`container system kernel set --recommended` 经 XPC 让 apiserver 安装内核到 per-user 的 appRoot `kernels/` 目录，代码与文档均无 sudo 要求；`system start` 提供 `--enable-kernel-install` / `--disable-kernel-install`（默认交互询问）。
- 【事实】KDK 核查：apple/container 与 apple/containerization 的 main 与 0.1.0 全部 README/BUILDING/tutorial 无 KDK 提及；GitHub search API 对两仓库 commits 与 issues 搜 "KDK"/"kernel development kit" 均 0 命中。**「需安装 KDK」「macOS 26 起改用系统内核」均无官方依据。**

来源：
- https://raw.githubusercontent.com/apple/containerization/main/README.md
- https://raw.githubusercontent.com/apple/container/main/docs/container-system-config.md
- https://raw.githubusercontent.com/apple/container/main/docs/tutorials/start-here.md
- https://raw.githubusercontent.com/apple/container/main/Sources/ContainerCommands/System/Kernel/KernelSet.swift

### 2.4 其他权限相关事实

- 【事实】官方二进制中只有 `container-runtime-linux` 与 `container-network-vmnet` 两个 helper 带 entitlements 签名，内容均**只有** `com.apple.security.virtualization = true`；apiserver 与 CLI 本体不带 entitlements；**没有** `com.apple.vm.networking`。
- 【事实】registry 凭据走用户 Keychain（keychain ID `com.apple.container.registry`），无需特权。
- 【事实】`container system property set` 与 `system dns default` 子命令在 main 分支**已不存在**（只有 `property list` 与 `dns create/delete/ls`）；系统配置改走 `~/.config/container/config.toml`。
- 【事实】BUILDING.md 记录 macOS 26 的一个 bug：helper 位于 `~/Documents` 或 `~/Desktop` 下时网络创建失败（TCC 相关）——第三方打包时安装位置需避开 TCC 保护目录。
- 【推断】结合「普通用户可创建 vmnet 网络」的文档行为与 helper 仅带 virtualization entitlement 的事实，macOS 15+ 的 vmnet 能力对常规签名二进制开放，无需 Apple 特批的 vmnet entitlement。

来源：
- https://raw.githubusercontent.com/apple/container/main/Makefile
- https://raw.githubusercontent.com/apple/container/main/signing/container-runtime-linux.entitlements
- https://raw.githubusercontent.com/apple/container/main/signing/container-network-vmnet.entitlements
- https://raw.githubusercontent.com/apple/container/main/Sources/Services/ContainerAPIService/Client/Constants.swift
- https://raw.githubusercontent.com/apple/container/main/docs/command-reference.md
- https://raw.githubusercontent.com/apple/container/main/BUILDING.md

---

## 三、对第三方 macOS app 分发的影响

### 3.1 调 CLI / 直连 XPC 的可行性

- 【事实】`container-apiserver` 的 XPC 服务端**唯一授权检查是 EUID 比对**（XPCServer.swift `handleMessage`：从 client audit token 取 EUID，与服务进程 `geteuid()` 不等则返回 "unauthorized request - uid mismatch"）。**没有 entitlement 检查、没有签名/TeamID 检查**。客户端侧即 `xpc_connection_create_mach_service(service, queue, 0)` 直连。
- 【事实】客户端库以 Swift 包产品形式公开：Package.swift 含 `.library(name: "ContainerAPIClient", …)`（另有 ContainerXPC、ContainerCommands 等 20+ library 产品）。
- 【推断】同一用户（同 EUID）下的任何**非沙盒**第三方进程都可以连接 apiserver 的 XPC 接口；root 进程反而连不上用户态 apiserver。直接依赖其 XPC 协议需承担大版本间变动风险（官方只承诺同一大版本内兼容），orchard 的对策是锁定支持版本（`supportedContainerVersion = "1.6.0"`）。
- 【推断，高置信】签名（Developer ID + Hardened Runtime）+ 公证的 Flutter macOS app 调 `container` CLI 完全可行；直连 XPC 需要一个原生（Swift）桥接层链接 ContainerAPIClient 包。orchard 是两条路径并存的现成先例。

来源：
- https://raw.githubusercontent.com/apple/container/main/Sources/ContainerXPC/XPCServer.swift
- https://raw.githubusercontent.com/apple/container/main/Sources/ContainerXPC/XPCClient.swift
- https://raw.githubusercontent.com/apple/container/main/Package.swift

### 3.2 沙盒 entitlement 取舍

- 【事实】Mac App Store 强制 App Sandbox（Apple 官方文档："To distribute a macOS app through the Mac App Store, you must enable the App Sandbox capability."）。
- 【事实】沙盒 app 的子进程继承沙盒（"If your macOS app embeds a command-line tool, that tool must inherit the containing app's sandbox configuration"）；沙盒默认禁止 lookup 第三方 mach service（需 temporary-exception entitlement，App Store 审核基本不放行）。
- 【事实】`com.apple.security.virtualization` 为 Boolean entitlement（macOS 11.0+），Apple 文档未提审批要求；非 App Store 分发的 VirtualBuddy 携带该 entitlement 可作旁证。该 entitlement 只需在真正跑 VM 的 helper 上（Apple 自己分发的 container-runtime-linux / container-network-vmnet），**调用方客户端不需要**。
- 【推断】沙盒内 exec `/usr/local/bin/container`（子进程继承沙盒后无法 lookup `com.apple.container.*` mach service、无法读写所需路径）或直连 apiserver XPC 均不可行 → **本场景必须走 Developer ID + 公证 + 非沙盒分发，不进 App Store**。Flutter app 本体 entitlements 可接近为空（orchard 仅 apple-events 一项）。

来源：
- https://developer.apple.com/documentation/security/app-sandbox
- https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization
- https://raw.githubusercontent.com/insidegui/VirtualBuddy/main/VirtualBuddy/Config/Entitlements/VirtualBuddy.entitlements

### 3.3 orchard 的签名公证方式（发布配置参考）

【事实】（andrew-waters/orchard `.github/workflows/release.yml`、`Orchard/Orchard.entitlements`、README）：

- 签名：**Developer ID**——`security import` 导入 `secrets.DEVELOPER_ID_CERTIFICATE_P12` 到临时 keychain；`xcodebuild archive` 带 `OTHER_CODE_SIGN_FLAGS="--options=runtime"`（**Hardened Runtime**）；`-exportArchive` 用 `method=developer-id` + teamID。
- 公证：仅 tag 触发——`xcrun notarytool submit <dmg> --apple-id … --password … --team-id … --wait`，Accepted 后 `xcrun stapler staple`，失败打印 `notarytool log` 并 `exit 1`。
- 打包：UDZO DMG（`hdiutil create -format UDZO`），附 SHA-256 校验文件。
- 渠道：GitHub Releases + **Sparkle 2** 自动更新（EdDSA 签名 appcast.xml 发 gh-pages，`sparkle:minimumSystemVersion` = 26.0）+ Homebrew cask（`brew install --cask orchard`）。**不进 App Store**。
- entitlements 全文件只有一项 `com.apple.security.automation.apple-events`（AppleScript 驱动终端）——**非沙盒、无 virtualization entitlement**。
- CI：测试在 macos-26 runner、构建在 macos-15 runner。
- 调用架构：主路径链接 `ContainerAPIClient` 走 XPC；CLI（`Foundation.Process`）兜底 `system start/stop/restart`、`kernel set`、`system property list`、builder 生命周期；**DNS create/delete 对 CLI 做提权（runWithSudo）**。版本门禁 `supportedContainerVersion = "1.6.0"`，`isContainerVersion(_:atLeast:)` 分量比较。

来源：
- https://raw.githubusercontent.com/andrew-waters/orchard/main/.github/workflows/release.yml
- https://raw.githubusercontent.com/andrew-waters/orchard/main/Orchard/Orchard.entitlements
- https://raw.githubusercontent.com/andrew-waters/orchard/main/Orchard/Services/ContainerBackend.swift
- https://raw.githubusercontent.com/andrew-waters/orchard/main/Orchard/Services/SystemService.swift
- https://raw.githubusercontent.com/andrew-waters/orchard/main/Orchard/Services/DNSService.swift
- https://raw.githubusercontent.com/andrew-waters/orchard/main/README.md

---

## 四、官方安装途径（未安装 / 版本过低时）

### 4.1 官方途径：GitHub Releases 签名 pkg

- 【事实】README 唯一文档化的安装途径：从 GitHub release 页下载**签名安装包**（`container-1.6.0-installer-signed.pkg`，155.9 MB，sha256 `a084d66df2fb573172d7f923fa83c9229d17f6c1ab61f09c8a90c43dab66ba02`），双击安装需**管理员密码**，文件装到 `/usr/local`（`/usr/local/bin/container` + `/usr/local/libexec/`）；同时提供 `container-installer-unsigned.pkg`（152.6 MB，供自签名）与 dSYM.zip。
- 【事实】CI（release.yml → common.yml）只产出 **unsigned** pkg 与 dSYM 并以 draft prerelease 上传；**signed pkg 由维护者（jglogan）在 CI 产物上传约 18.5 小时后手动上传**（GitHub API asset uploader/created_at 元数据）。
- 【推断】pkg 的签名（及可能的公证）在 CI 之外由人工完成；README 只写 "signed installer package"，**未找到 notarized 的逐字声明**（未确认项）。
- 【事实】升级：`/usr/local/bin/update-container.sh`（0.10.0 起随包分发）；降级须先 `uninstall-container.sh -k`；卸载 `/usr/local/bin/uninstall-container.sh`（`-k` 保留用户数据，`-d` 删除）。源码在仓库 `scripts/` 下。

来源：
- https://raw.githubusercontent.com/apple/container/main/README.md
- https://github.com/apple/container/releases/tag/1.6.0
- https://api.github.com/repos/apple/container/releases/tags/1.6.0
- https://raw.githubusercontent.com/apple/container/main/.github/workflows/release.yml
- https://raw.githubusercontent.com/apple/container/main/.github/workflows/common.yml
- https://raw.githubusercontent.com/apple/container/main/Makefile

### 4.2 社区途径：Homebrew formula（非官方文档化）

- 【事实】**无 Homebrew cask**（formulae.brew.sh cask API 404；【实测】`brew info --cask container` 报 "No Cask with this name exists"）。
- 【事实】homebrew-core 有 **formula `container`**（bottled）：`brew install container` 可行；formula 要求 macOS >= 26、arm64，构建需 Xcode 26。
- 【实测】本机经 Homebrew 安装 1.5.0：`/opt/homebrew/bin/container` → `../Cellar/container/1.5.0/bin/container`；brew caveats：用 `brew services` 启动时不自动装内核，需先 `container system kernel set --recommended`；服务命令为 `container system start --disable-kernel-install`。
- 【推断】README 从未提及 Homebrew，应视为社区维护途径，版本可能滞后于 GitHub release（本机 1.5.0 vs 最新 1.6.0）。

来源：
- https://formulae.brew.sh/formula/container
- https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/c/container.rb

---

## 五、程序化检测安装与版本的可靠方法

### 5.1 存在性与路径

- 【事实】官方 pkg 安装路径：`/usr/local/bin/container`；Homebrew formula：`/opt/homebrew/bin/container`（或对应 brew prefix）。
- 【事实】orchard 的做法（SettingsStore.swift）：`safeContainerBinaryPath()` 校验 customBinaryPath（可执行性检查），无效则回退默认路径并提示；检测到未安装时引导用户到 README `#initial-install` 下载。
- 【推断】检测应同时覆盖 `/usr/local/bin/container`、`/opt/homebrew/bin/container`，并允许用户自定义路径（对应 pkg 与 brew 两种安装形态）。

来源：https://raw.githubusercontent.com/andrew-waters/orchard/main/Orchard/Services/SettingsStore.swift

### 5.2 版本检测

- 【实测】`container --version` 输出单行：`container CLI version 1.5.0 (build: release, commit: unspeci…)`（需正则提取版本号）。
- 【事实】版本字符串来源（Sources/ContainerVersion/ReleaseVersion.swift）：CFBundleShortVersionString → `get_release_version()` → fallback `0.0.0`。
- 【事实 + 实测】`container system version --format json`（0.8.0 起）输出数组，每项含 `appName`/`version`/`buildType`/`commit`，**同时列 CLI 与 container-apiserver**——最适合程序化解析（可一次拿到双端版本做一致性判断）。
- 【事实】XPC 路径：`ClientHealthCheck.ping()` 返回 `apiServerVersion`；orchard 用「解码失败 + health check 关键字」判定协议级版本不匹配（isContainerVersionMismatch），区别于「服务未启动」。

来源：
- https://raw.githubusercontent.com/apple/container/main/Sources/ContainerVersion/ReleaseVersion.swift
- https://raw.githubusercontent.com/apple/container/main/docs/tutorials/start-here.md
- https://raw.githubusercontent.com/andrew-waters/orchard/main/Orchard/Services/ContainerBackend.swift

### 5.3 服务状态检测

- 【实测】`container system status --format json` 输出含 `status`（running/…）、`client.version`、`server.appName`（container-apiserver）、`host`、`paths.appRoot`（`~/Library/Application Support/com.apple.container/`）、`paths.installRoot`；1.4.1 起报 host/client/paths/resources。服务未启动时 CLI 报错并提示先 `container system start`。
- 【实测】apiserver 以 per-user launchd 服务运行（label `com.apple.container.apiserver`；brew services 场景为 `~/Library/LaunchAgents/sh.brew.container.plist` keep-alive 包装）。

来源：https://raw.githubusercontent.com/apple/container/main/docs/command-reference.md

### 5.4 内核检测

- 【事实】orchard 的做法：读 `~/Library/Application Support/com.apple.container/kernels/default.kernel-arm64` 符号链接目标，含 `vmlinux-` 视为推荐内核，否则为自定义内核；`kernel set --recommended` 遇 "already exists" 失败时加 `--force` 重试。

来源：https://raw.githubusercontent.com/andrew-waters/orchard/main/Orchard/Services/SystemService.swift

---

## 六、对 v1 引导与分发决策的含义（推断汇总）

1. **系统基线**：container 官方要求 macOS 26 + Apple silicon，与本仓库产品基线（docs/engineering.md）完全一致；无需为 macOS 15 做兼容（官方也不支持）。
2. **分发形态**：Developer ID 签名 + Hardened Runtime + 公证 + DMG（参照 orchard release.yml 全流程），不进 App Store（沙盒使 CLI/XPC 调用均不可行）。app 本体无需 virtualization entitlement。
3. **引导流程**：检测 `/usr/local/bin/container` 与 `/opt/homebrew/bin/container` → `container system version --format json` 取双端版本 → 版本低于基线则引导 `update-container.sh`（pkg 安装）或 `brew upgrade container`（brew 安装）→ 未安装则引导 GitHub Releases 签名 pkg（唯一官方文档化途径）或 `brew install container`（社区途径，需说明非官方）。
4. **提权面**：常规操作零提权；仅两类操作需管理员——①pkg 安装/卸载（installer 自身弹窗），②DNS 域 create/delete（写 `/etc/resolver` + HUP mDNSResponder，app 需自行设计提权交互，参照 orchard 的 runWithSudo）。注意 `--localhost` 域会禁用 Private Relay 且 pf 规则重启后消失。
5. **版本门禁**：XPC API 仅同一大版本内保证兼容；建议参照 orchard 锁定 `supportedContainerVersion`，对不匹配给出明确提示而非报「服务停止」。
6. **1.6.0 基线建议**：`container commit`（v1 的 Commit 原语）由 1.6.0 首次提供，若 v1 依赖 commit，最低版本应锚定 1.6.0（2026-10-20 发布，Homebrew formula 已跟进到 1.6.0）。

---

## 附：主要一手来源清单

apple/container（main 分支，除注明 tag 外）：
- README：https://raw.githubusercontent.com/apple/container/main/README.md
- docs：technical-overview.md / networking.md / host-integration.md / container-system-config.md / command-reference.md / tutorials/start-here.md（同前缀 https://raw.githubusercontent.com/apple/container/main/docs/…）
- BUILDING.md / Makefile / Package.swift：https://raw.githubusercontent.com/apple/container/main/…
- 签名 entitlements：https://raw.githubusercontent.com/apple/container/main/signing/container-runtime-linux.entitlements 、…/container-network-vmnet.entitlements
- 源码：Sources/ContainerCommands/System/{SystemStart,SystemStop}.swift、System/DNS/DNSCreate.swift、System/Kernel/KernelSet.swift；Sources/ContainerPlugin/{ServiceManager,ApplicationRoot}.swift；Sources/Services/ContainerAPIService/Client/{HostDNSResolver,Constants,ClientHealthCheck}.swift；Sources/ContainerXPC/{XPCServer,XPCClient}.swift；Sources/ContainerVersion/ReleaseVersion.swift（同前缀 https://raw.githubusercontent.com/apple/container/main/…）
- 各 tag README（0.1.0–1.6.0 逐字核对系统要求）：https://raw.githubusercontent.com/apple/container/<tag>/README.md
- releases API：https://api.github.com/repos/apple/container/releases?per_page=100 、…/releases/tags/1.6.0
- CI 工作流：https://raw.githubusercontent.com/apple/container/main/.github/workflows/{release,common}.yml

apple/containerization：
- https://raw.githubusercontent.com/apple/containerization/main/README.md

andrew-waters/orchard：
- https://raw.githubusercontent.com/andrew-waters/orchard/main/.github/workflows/release.yml
- https://raw.githubusercontent.com/andrew-waters/orchard/main/Orchard/Orchard.entitlements
- https://raw.githubusercontent.com/andrew-waters/orchard/main/Orchard/Services/{ContainerBackend,SystemService,DNSService,SettingsStore}.swift
- https://raw.githubusercontent.com/andrew-waters/orchard/main/README.md

Apple 官方文档：
- https://developer.apple.com/documentation/security/app-sandbox
- https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization

其他：
- Homebrew formula：https://formulae.brew.sh/formula/container 、https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/c/container.rb
- VirtualBuddy（virtualization entitlement 旁证）：https://raw.githubusercontent.com/insidegui/VirtualBuddy/main/VirtualBuddy/Config/Entitlements/VirtualBuddy.entitlements
- 本机实测环境：macOS 27.0.1 (arm64)，container 1.5.0（Homebrew），2026-10-23。
