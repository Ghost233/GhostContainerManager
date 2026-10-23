# v1 总体架构决策简报

- 工单：GitHub issue #2（wayfinder 地图 #1 子工单）
- 日期：2026-10-23
- 输入：docs/spec/mcp-tools.md（#8 简报）、docs/research/bridge-flutter-apple-container.md（#7）、docs/research/dart-mcp-server-options.md（#4）、docs/research/apple-container-system-requirements.md（#11）、docs/research/compose-plugin-integration.md（#6）、docs/engineering.md（E01–E12）、GLOSSARY.md
- 已定前提：非沙盒分发（Developer ID + 公证，#11 定论）；XPC 主/CLI 补的桥接分工（#7）；MCP 内置、与 UI 同进程共用管理入口（地图决策）；版本门禁对齐 orchard `supportedContainerVersion = "1.6.0"`。
- 术语：本文用 codebase-design 词汇——模块/接口/实现/接缝/适配器/深度。

---

## 1. 分层总览

```
┌──────────────────────────────────────────────────────────┐
│ 前端适配器层（三个对等前端，只调管理入口接口，互不知晓）      │
│  Flutter UI (lib/features/*)                              │
│  内置 MCP server (lib/mcp/*, mcp_dart ^2.4.3)             │
│  MacLauncher SDK 接入 (lib/launcher/*)                    │
├──────────────────────────────────────────────────────────┤
│ 管理入口 / Service layer（lib/services/*）                 │
│  - 领域服务：ContainerService/ImageService/SystemService/  │
│    ComposeService/NetworkService/MountService             │
│  - 权威状态 store（E07）：容器/镜像/系统状态的唯一来源        │
│  - 操作线性化、错误码映射（mcp-tools.md §5）、进度节流       │
├──────────────────────────────────────────────────────────┤
│ 桥接接缝（Dart 抽象接口 ContainerBridge）                  │
├──────────────────────────────────────────────────────────┤
│ 桥接适配器（packages/container_bridge，本地 Flutter plugin）│
│  Swift 侧：链接 ContainerAPIClient（XPC 主路径）            │
│           + CLI 进程包装（system 启停/内核安装）            │
├──────────────────────────────────────────────────────────┤
│ Apple container：container-apiserver（XPC）/ container CLI │
└──────────────────────────────────────────────────────────┘
```

核心命题：**管理入口是全 app 唯一深模块**——三个前端（UI/MCP/MacLauncher）共享同一接口与同一状态源（E06/E07 的直接落地），桥接接缝之下才是平台适配。任何容器操作的语义（超时、错误码、幂等、线性化）只在 Service layer 定义一次。

## 2. Dart↔Swift 通道选型（关键决策点 1）

| 方案 | 优 | 劣 |
|---|---|---|
| A. **MethodChannel + EventChannel** | Flutter 官方通道；async 语义自然；EventChannel 原生支持流（日志 fd、pull 进度、stats 轮询）；payload 走 JSON（Swift Codable → dart:convert，#7 §2.5 评估为"中"工程量）；orchard 的 `ContainerBackend` protocol（约 20 方法）可直接作接口蓝本 | 每次调用一次序列化；二进制大payload需分块 |
| B. FFI（ffigen + Swift C ABI 封装） | 无序列化开销、调用延迟低 | Swift async/await 与 XPC 的 fd 传递（日志 FileHandle）经 C ABI 暴露极痛苦；需手写内存管理边界；流式仍需自研回调通道；生态对 Swift 支持远弱于 MethodChannel |

**推荐 A**。本场景瓶颈在 XPC 往返与进程 IO，MethodChannel 的序列化开销可忽略；fd 传递、progress 回调这些 Swift 侧能力经 EventChannel 暴露是成熟模式。FFI 的优势（延迟）在本场景不构成收益，劣势（Swift 互操作成本）是实打实的。

## 3. 桥接适配器形态（关键决策点 2）

| 方案 | 优 | 劣 |
|---|---|---|
| A. **独立本地 plugin**（`packages/container_bridge/`，Swift 侧链 SwiftPM：apple/container 固定版本 + andrew-waters/compose） | 接缝真实存在（Dart 侧 fake 适配器可供 UI/Service 层全部测试）；E09 按职责拆分；plugin 接口即测试表面 | 多一个包的维护成本 |
| B. 代码直接放 `macos/Runner` | 少一层 | Runner 与 app 生命周期耦合，无法在 Dart 测试中替换；接缝变假 |

**推荐 A**。Dart 侧定义抽象接口 `ContainerBridge`（约 20 个方法，蓝本 = orchard `ContainerBackend`），两个适配器：`MethodChannelContainerBridge`（真）与 `FakeContainerBridge`（测试/无容器环境开发）。这同时满足 E02（I/O 边界校验后成形业务数据）与"接口就是测试表面"。

compose 接入（#6 结论）：Swift 桥接层链接 andrew-waters/compose 包、结构化执行 Plan 为主路径（不依赖 CLI 插件安装，规避"container 升级清空插件目录"的脆弱性）；`container compose` CLI 调用作降级路径，检测方式 = `container compose --help` 退出码。

## 4. MCP server 嵌入与 stdio helper（关键决策点 3）

**HTTP 模式**（主形态）：app 主 isolate 常驻 `StreamableMcpServer(host: '127.0.0.1', port: 可配, 默认选一个如 35731)`；tool 回调直调 Service layer 单例，无 IPC；保持 mcp_dart 默认 DNS rebinding 防护开启；端口占用冲突时在设置页提示换端口。生命周期跟随 app（启动 connect、退出 close）；长操作接 `extra.sendProgress` / `extra.signal`。

**stdio 模式**：stdio 本质是父子进程管道，MCP client 需要 spawn 一个进程。三个方案：

| 方案 | 优 | 劣 |
|---|---|---|
| a. **瘦代理 helper**：app bundle 内附一个 Dart AOT 编译的小可执行（`dart compile exe`），把 stdio 帧转发到运行中 app 的 127.0.0.1 HTTP server | 权威逻辑只有一份（app 内 server）；helper 极小、无原生依赖、公证友好；非沙盒下 spawn 无约束 | app 未运行时 stdio 不可用（helper 报错并提示启动 app） |
| b. 独立完整 server：helper 自带 Service layer + 自己的桥接，直连 XPC | app 未运行也可用 | Service layer 两份实现（或强制共享代码但状态源分裂，违反 E07）；helper 需链接 Swift 桥接，Dart AOT exe 无法承载 Flutter plugin → 实际不可行 |
| c. v1 只做 HTTP，stdio 留 v2 | 最省事 | stdio 是桌面 agent（Claude Code 等）的主流接入方式，砍掉会削弱 MCP-first 定位 |

**推荐 a**。方案 b 违反单一状态源且技术不可行（Dart AOT exe 不跑 Flutter engine，用不了 MethodChannel plugin）；方案 a 的"app 未运行不可用"与菜单栏常驻（已决策）配合后影响很小——MCP server 是否随菜单栏常驻保持可用，属于 #3 生命周期工单的决策范围，本简报只保证架构上支持。

## 5. 状态同步模型

**事实约束**（#7）：XPC 侧没有容器列表变更的订阅推送（`containerEvent` 路由存在但语义未验证）；日志是 fd 传递（FileHandle），stats 是单次快照；CLI 流式不可用。orchard 的做法是轮询 + 可见性自适应（StatsService：可见 2s / 不可见 10s，双快照差值算速率）。

**推荐模型：变更驱动刷新 + 自适应轮询，单一权威状态源（E07）**：

1. **写路径**：任何前端发起操作 → Service layer 执行 → 成功后立即刷新受影响资源的状态到 store（不等轮询）。操作线性化：同一资源 ID 的操作串行（per-resource mutex），跨资源并行；UI 与 MCP 对同一容器的并发操作自然互斥，进行中的操作以状态（如 `status: "stopping"`）呈现在权威状态里，所有前端看到一致的"进行中"。
2. **读路径**：store 对运行中容器集合做自适应轮询（前台可见 2s / 后台 10s，对齐 orchard）；`system_status` 变化（apiserver 挂掉/重启）经 ping 失败特征检测后全量刷新。
3. **流式**：日志 fd（Swift 侧 readabilityHandler）与 pull 进度回调（~10Hz 节流）经 EventChannel 进 Service layer 的流；UI 订阅流渲染，MCP 长操作把同一流折叠为 progress notification——**两个前端共用同一节流点**，不产生第二份流。
4. **状态归属**：store 是唯一权威源（`Listenable`/流暴露）；UI 局部状态（选中项、滚动位置）留在 widget 层（E07 允许）。

## 6. 模块划分与目录结构

```
lib/
  main.dart                  # 组装入口：构造依赖、接线（E08 依赖传入）
  app/                       # app shell、菜单栏常驻、窗口管理
  features/                  # UI 页面（E05：只展示与交互）
    containers/ images/ compose/ networks/ mounts/ system/ settings/
  services/                  # 管理入口（唯一深模块）
    container_service.dart   # 容器域操作 + 线性化 + 错误码映射
    image_service.dart
    system_service.dart      # 启停（CLI）、ping、版本门禁
    compose_service.dart     # compose up/down、label 聚合
    network_service.dart  mount_service.dart   # 只读
    state/                   # 权威状态 store（app_state.dart 等）
    errors.dart              # mcp-tools.md §5 错误码枚举与映射
  bridge/
    container_bridge.dart    # 抽象接口（接缝）
  mcp/
    mcp_server.dart          # 内嵌 server 生命周期（HTTP）
    tools/                   # 34 个工具注册（薄适配：参数校验→调 Service layer→格式化输出）
  launcher/
    maclauncher_registrar.dart  # MacLauncher SDK 接入（对接面见 §7）
packages/
  container_bridge/          # 本地 plugin：Swift 侧 ContainerAPIClient + compose 包 + CLI runner
    darwin/Classes/          # XPC client 封装、CLI runner（DispatchGroup 抽干管道，#7 工程经验）
```

**深度检查**：`mcp/tools/*` 每个工具是薄适配器（参数解析 → Service layer → 输出格式化），复杂性集中在 Service layer——删除测试成立（删掉某个 tool 文件，复杂逻辑不散布）；`container_bridge` 的 Dart 抽象是真实接缝（两个适配器：真/假）。

## 7. E06 与 MacLauncher 对接面

架构上 MacLauncher SDK 是与 UI/MCP 对等的**第三个前端适配器**（`lib/launcher/`）：

- 它只依赖 Service layer 接口；SDK 回调（`onStart`/`onRecycle`/`onStatus`/`onLogs`）在 launcher 适配器内翻译成 Service layer 调用，回调内不产生任何独立的容器管理逻辑（maclauncher-sdk.md 的明确要求）。
- `onStatus`/`onLogs` 订阅权威状态 store 与日志流，与 UI/MCP 同源。
- **注册哪些服务、recycle 的业务语义由 #10 工单决定**；本简报只承诺对接面形状：`launcher/` 适配器构造时接收 Service layer 实例（E08），无反向依赖。
- 启动器未运行时该适配器不激活，app 独立工作（已决策）。

## 8. 非沙盒分发的架构影响

- app 本体 entitlements 可近空（参照 orchard 仅 apple-events 一项——我们的 exec 走 XPC createProcess 内联返回输出，**不需要** apple-events 驱动终端，除非 UI 决策要"在终端中打开"，留给 #5/#3）。
- 不需要 `com.apple.security.network.server`（非沙盒下 127.0.0.1 监听不受 entitlement 约束）；不需要 mach-lookup 例外。
- 版本门禁：启动时 ping 取 `apiServerVersion`，对齐 orchard 锁定 `1.6.0`；不匹配时区分「未启动」与「版本不匹配」两类错误特征（#7/#11），在 UI 与 MCP（`RUNTIME_UNAVAILABLE`/`VERSION_MISMATCH` 错误码）同时呈现。
- 发布管线（Developer ID + Hardened Runtime + 公证 + DMG）已有，orchard 的 release.yml 为参照（#11 §3.3）。

## 9. 待用户拍板

- **Q1 Dart↔Swift 通道**：MethodChannel + EventChannel + JSON payload（推荐 A）vs FFI。➡️ 推荐 A。
- **Q2 桥接形态**：独立本地 plugin `packages/container_bridge`（推荐 A）vs Runner 内嵌。➡️ 推荐 A。
- **Q3 stdio helper**：瘦代理转发到 app 内 HTTP server（推荐 a）vs v1 只支持 HTTP。➡️ 推荐 a；接受"app 未运行时 stdio 报错"的代价（菜单栏常驻缓解）。
- **Q4 状态同步**：变更驱动刷新 + 自适应轮询（推荐）vs 先验证 `containerEvent` XPC 路由是否可用作推送源。➡️ 推荐轮询先行（与 orchard 同构、风险低），`containerEvent` 列入实现期 spike。
- **Q5 MCP HTTP 端口**：固定默认端口（如 35731）+ 冲突时提示改配，还是随机端口 + 发现文件（写 `~/.config/ghostcontainermanager/mcp.json` 供 client 读取）？➡️ 推荐固定默认 + 可配（agent 配置简单）；发现文件机制留 v2。
- **Q6 目录结构**：§6 的划分是否认可，特别是 `services/` 单目录平铺 vs 按域子目录（`services/containers/`…）。➡️ 推荐平铺起步（E09/E10：拆分需求出现后真的出现再拆）。

## 10. GLOSSARY 新增术语建议

- **桥接层（Bridge）**：Dart 与 Swift 原生能力之间的适配层；Dart 侧为抽象接口（接缝），Swift 侧为链接 ContainerAPIClient 与 CLI 包装的本地 plugin 实现。桥接层只做平台适配，不含业务语义。
- **权威状态源（Authoritative state）**：Service layer 持有的容器/镜像/系统状态的唯一来源；UI、MCP、MacLauncher 三个前端都从这里读，写操作结果先回流到这里再分发。
- **MCP stdio helper**：随 app bundle 分发的 Dart AOT 小可执行，把 MCP client 的 stdio 帧转发到运行中 app 的 loopback HTTP server；自身不含管理逻辑。
- **操作线性化**：同一资源上的写操作在 Service layer 串行执行的约束；跨资源可并行；进行中状态是权威状态的一部分。
