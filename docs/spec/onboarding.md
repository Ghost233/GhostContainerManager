# Onboarding 与系统检测流程决策简报

- 工单：GitHub issue #9 / 团队任务 task-4（wayfinder 地图 #1 子工单）
- 日期：2026-10-23
- 输入：`docs/research/apple-container-system-requirements.md`（检测命令、版本锚、安装途径、权限事实）、`docs/research/bridge-flutter-apple-container.md`（system start 的 kernel-install flag 陷阱）、`GLOSSARY.md`
- 性质：决策简报——给出选项、权衡与推荐；结论待用户在末尾编号问题清单中拍板后转入实施规格。

## 1. 检测模型：启动就绪状态机

应用每次冷启动执行一次**就绪检测**，结果是后续所有 UI/MCP 能力的前置门禁。状态机按依赖顺序逐级检测，前一级失败即短路（不继续后续检测）：

```
未安装 NotInstalled
  └─→ 版本过低 VersionTooLow        （存在 binary 但 < 1.6.0）
        └─→ 主版本不兼容 UnsupportedMajor（≥ 2.x，XPC 官方只承诺同一大版本兼容）
              └─→ 服务未运行 ServiceNotRunning
                    └─→ 内核缺失 KernelMissing
                          └─→ 就绪 Ready
```

每一级的检测方法（均有调研事实支撑）：

| 级别 | 检测方法 | 失败判定 |
| --- | --- | --- |
| 存在性 | 依序探测 `/usr/local/bin/container`（官方 pkg）、`/opt/homebrew/bin/container`（Homebrew）、用户在设置中保存的自定义路径；校验可执行性 | 三者皆不可执行 |
| 版本 | `container system version --format json`（0.8.0 起，一次取回 CLI 与 apiserver 双端版本） | CLI 或 apiserver < 1.6.0；或主版本 ≠ 1 |
| 服务状态 | `container system status --format json`（exit code 1 = 未注册/ping 失败）；辅助手段 XPC `ClientHealthCheck.ping()` | status 非 running |
| 内核 | 读 `~/Library/Application Support/com.apple.container/kernels/default.kernel-arm64` 符号链接目标，含 `vmlinux-` 视为推荐内核在位（orchard 做法） | 符号链接不存在或目标缺失 |

补充规则：

- **双端一致性**：`system version` 同时返回 CLI 与 apiserver 版本，两者不一致（典型场景：pkg 升级后 apiserver 仍在跑旧版）应引导 `container system restart` 而非报版本过低。
- **版本不匹配 vs 服务未启动的区分**：XPC ping 的解码失败特征（"failed to decode" + "health check"，orchard 的 isContainerVersionMismatch）与连接失败特征（"connection invalid"）分别映射到 UnsupportedMajor 与 ServiceNotRunning，避免把版本问题误报为"服务停了"。
- **最低版本锚 1.6.0**：`container commit`（v1 容器→镜像能力）由 1.6.0 首次引入；XPC API 官方只承诺同一大版本内兼容，故锁定大版本 1（参照 orchard 的 `supportedContainerVersion` 门禁）。

## 2. 各失败分支的引导内容与动作

### 2.1 未安装 NotInstalled

- 主引导：**官方签名 pkg**（GitHub Releases `container-1.6.0-installer-signed.pkg`，唯一官方文档化途径）。页面提供：版本号与校验值展示、"打开下载页"按钮（跳 release 页）、安装步骤说明（双击 pkg → 需管理员密码 → 装到 `/usr/local`）。
- 次引导：`brew install container`（社区途径，明确标注"非官方、版本可能滞后"）。
- 动作：仅"打开下载页 / 复制 brew 命令 / 我已安装，重新检测"。**app 不代执行 pkg 安装**（需管理员密码且写 /usr/local，超出 v1 零提权边界）。

### 2.2 版本过低 VersionTooLow

- 按安装形态分流指引：pkg 安装 → `/usr/local/bin/update-container.sh`（0.10.0 起随包分发）；brew 安装 → `brew upgrade container`。
- 提示升级后需 `container system restart` 使 apiserver 切换到新版本（双端一致性规则）。

### 2.3 主版本不兼容 UnsupportedMajor

- 不做降级适配：明示"本应用支持 Apple container 1.x（≥1.6.0），检测到 X.Y"，引导回退或等待应用更新。不提供"勉强继续"。

### 2.4 服务未运行 ServiceNotRunning

- 提供**一键启动**：执行 `container system start --enable-kernel-install`（首次、内核缺失时）或 `--disable-kernel-install`（内核已在位时）。
- ⚠️ **必须显式传 flag**：不传时 CLI 会 `readLine` 交互询问安装内核，stdin EOF 抛 "failed to read user input"（桥接调研核实的陷阱）。flag 选择依据内核检测结果。
- 启动期间显示进度态；启动后轮询 ping（最多 10×0.5s，orchard 做法）确认 XPC 就绪，再进入 Ready。
- system start/stop 不需要 root，一键启动无提权交互。

### 2.5 内核缺失 KernelMissing

- 提供**一键安装推荐内核**：`container system kernel set --recommended`（经 XPC 装到 per-user 目录，无需 root；brew caveat 场景常见此缺失）。
- 下载内核（Kata 预编译内核，从其 GitHub releases 拉取）可能耗时，需进度呈现；遇 "already exists" 失败时自动加 `--force` 重试一次（orchard 做法）。

## 3. 重试与降级策略

- **检测时机**：冷启动必做；此后按需触发——任一管理操作返回"服务不可用"特征错误时自动重检并更新状态机；菜单栏提供手动"重新检测"。
- **自动重试**：ServiceNotRunning / KernelMissing 的一键动作失败后可手动重试，不做无界自动重试（避免对 launchd bootstrap 打摆子）；ping 轮询上限固定 10×0.5s，超时回落到 ServiceNotRunning 并保留错误原文。
- **检测失败的降级**：任何一级检测命令自身失败（超时、输出无法解析）时，状态落入对应失败级并展示原始错误与"重试"按钮；**不静默跳过**（E02：I/O 边界校验外部数据后再形成业务状态）。
- **运行中失能**：运行期 apiserver 崩溃/被停（ping 失败）→ 状态机回落 ServiceNotRunning，主 UI 进入降级模式（见 §4），MCP 工具统一返回结构化"runtime unavailable"错误而非崩溃。

## 4. 与主 UI 的关系：阻塞式向导 vs 可跳过横幅

三个候选形态：

- **A. 全阻塞向导**：任何非 Ready 状态都挡住主界面，必须走完引导。
- **B. 可跳过横幅**：主界面始终可进，顶部横幅提示 + 一键修复按钮。
- **C. 分级混合（推荐）**：
  - NotInstalled / VersionTooLow / UnsupportedMajor → **阻塞式向导页**（没有运行时，主界面一切能力皆空，进去只有失望；但提供"跳过并仅查看设置/帮助"的出口，不强制退出 app）；
  - ServiceNotRunning / KernelMissing → **非阻塞降级壳**：主界面可进，容器/镜像区域显示空态 + 醒目修复按钮（这两个状态 app 自己能修，修复成本一次点击）；
  - Ready → 正常界面。

权衡：A 最不容易误导但最霸道；B 最灵活但用户可能在空界面上困惑"我的容器呢"；C 按"app 能否自救"分流——外部依赖缺失（要装 155MB pkg）阻塞+指引，内部可修复（start/kernel set 都是一条命令）非阻塞+一键修。推荐 **C**，符合 macos-ui-standards 的渐进式披露原则。

## 5. 与 MCP / MacLauncher 的联动

- **MCP**：内置 MCP server 在非 Ready 状态下照常可连接，但所有管理工具返回结构化 `runtime_unavailable` 错误（携带当前状态机状态与修复指引文本）；`system_status` 类只读工具返回状态机当前状态。MCP 客户端不能执行引导动作（pkg 安装需人）。
- **MacLauncher**：onStatus 上报的状态必须反映状态机真实状态（未就绪 ≠ running）；SDK 断连不影响状态机本身（启动器未运行时应用独立工作，见 #10 简报）。

## 6. 待用户拍板的问题清单

- **Q1 - 主 UI 形态**：是否采用 §4 推荐的分级混合方案 C？
  ➡️ 推荐：是。外部依赖缺失（未安装/版本低）阻塞向导，内部可修复（服务未起/内核缺失）降级壳 + 一键修复。
- **Q2 - 最低版本锚定**：是否锚定 container ≥ 1.6.0（commit 能力），大版本锁定 1.x？
  ➡️ 推荐：是，与 orchard 的 supportedContainerVersion 门禁同构；未来上游 2.x 发布时再评估适配。
- **Q3 - 一键 system start 的内核 flag**：内核缺失时一键启动是否默认 `--enable-kernel-install`（顺带装内核，少一步）？
  ➡️ 推荐：是——合并"启动服务 + 装内核"为一个动作，进度条合并呈现；用户可在设置中改为手动分步。
- **Q4 - brew 途径的定位**：未安装引导页是否展示 `brew install container` 作为第二选项？
  ➡️ 推荐：展示但明确标注"社区途径、非官方、版本可能滞后"，主按钮始终是官方 pkg。
- **Q5 - 自定义二进制路径**：设置页是否允许用户指定 container 二进制路径（orchard 有此能力）？
  ➡️ 推荐：允许，放在设置页（校验可执行性，无效则回退默认路径并提示）；onboarding 页不提供，保持引导简单。

## 7. GLOSSARY 新术语建议

- **就绪检测（Readiness check）**：应用启动时按依赖顺序逐级核验运行环境（存在性 → 版本 → 服务状态 → 内核）的状态机，结果是全部管理能力的前置门禁。
- **就绪（Ready）**：就绪检测全部通过的状态；此时 XPC 管理路径可用。
- **降级壳（Degraded shell）**：服务未运行或内核缺失时的非阻塞主界面形态——页面可进、数据区空态、提供一键修复动作。
- **默认内核（Default kernel）**：apiserver per-user 目录下 `kernels/default.kernel-arm64` 符号链接指向的 Linux 内核（推荐内核为 Kata 预编译）；每个容器 VM 使用它启动，与 macOS 系统内核无关。
