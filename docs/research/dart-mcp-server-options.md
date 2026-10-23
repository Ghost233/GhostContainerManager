# Dart MCP server 技术选型调研

- 调研工单：GitHub issue #4
- 调研日期：2026-10-23
- 适用约束：Flutter 3.47.7 / Dart 3.13.5（见 docs/engineering.md），macOS 桌面（arm64）
- 术语对齐：GLOSSARY.md 中 MCP server 的两种模式（HTTP on 127.0.0.1 / stdio 子进程）
- 标注约定：【事实】= 有一手来源支撑；【推断】= 基于事实的推论或建议，未经实证。

## 结论速览（TL;DR）

- 【事实】MCP 官方（modelcontextprotocol 组织）没有 Dart SDK；Dart 生态的事实标准候选是社区包 `mcp_dart` 与 Dart 团队实验包 `dart_mcp`。
- 【推荐】首选 **mcp_dart ^2.4.3**（MIT，SDK 约束 ^3.4.0，兼容 Dart 3.13.5）：唯一同时覆盖 stdio 与 Streamable HTTP 服务端、默认开启 DNS rebinding 防护、通过官方一致性测试并与 TS/Python SDK 互操作验证的 Dart 包。
- 【备选】**dart_mcp ^0.5.2**（BSD-3-Clause，Dart 团队维护但标注 experimental）：stdio 与 Streamable HTTP 均可用，但不支持 OAuth 授权、定位偏本地 server。
- 【事实】工具注解（readOnlyHint/destructiveHint/idempotentHint/openWorldHint/title）在 mcp_dart 与 dart_mcp 中均为一等公民。
- 【事实】macOS App Sandbox 下监听 socket（含仅 127.0.0.1）必须声明 `com.apple.security.network.server` entitlement；这影响打包配置而非 SDK 选型。

---

## 1. 可用的 Dart MCP server SDK

### 1.1 官方组织现状

【事实】modelcontextprotocol GitHub 组织仓库列表中没有 Dart SDK；`modelcontextprotocol/dart-sdk` 返回 404。官方 SDK 覆盖 TypeScript、Python、Swift、Rust、Ruby、C# 等语言，不含 Dart。
来源：
- https://api.github.com/orgs/modelcontextprotocol/repos （全量列表检索无 dart）
- https://api.github.com/repos/modelcontextprotocol/dart-sdk （404）

### 1.2 候选包对比

指标采集时间：2026-10-23，来源为 pub.dev API 与 GitHub API。

| 维度 | mcp_dart | dart_mcp | mcp_server |
|---|---|---|---|
| 最新版本 | 2.4.3（2026-10-14） | 0.5.2（2026-06-29） | 3.0.0（2026-10-13） |
| 仓库 | github.com/leehack/mcp_dart | github.com/dart-lang/ai（pkgs/dart_mcp） | github.com/app-appplayer/mcp_server |
| 维护方 | 社区（leehack 等） | Dart 团队（publisher labs.dart.dev） | 个人（publisher makemind.dev） |
| 许可证 | MIT | BSD-3-Clause | MIT |
| Dart SDK 约束 | ^3.4.0 | ^3.7.0 | ^3.7.0 |
| GitHub stars / forks / open issues | 116 / 33 / 2 | 288 / 74 / 73（整个 monorepo） | 9 / 5 / 1 |
| pub 分数 / likes / 30 天下载 | 160/160 / 79 / ≈237k | 150/160 / 83 / ≈555k | 160/160 / 15 / ≈1.65k |
| 协议覆盖 | 2026-07-28 核心 client/server 全覆盖，协商更早版本 | 2026-07-28（仅 Streamable HTTP）；stdio 最高协商 2025-11-25 | 宣称 2024-11-05 → 2026-07-28 全部修订 |
| 定位声明 | 正在申请 MCP SDK Tier 1 | "still experimental and is likely to evolve quickly"，主要面向本地 server | — |

来源：
- https://pub.dev/packages/mcp_dart 、 https://pub.dev/api/packages/mcp_dart/score
- https://pub.dev/packages/dart_mcp 、 https://pub.dev/api/packages/dart_mcp/score
- https://pub.dev/packages/mcp_server 、 https://pub.dev/api/packages/mcp_server/score
- https://api.github.com/repos/leehack/mcp_dart 、 https://api.github.com/repos/dart-lang/ai 、 https://api.github.com/repos/app-appplayer/mcp_server
- https://github.com/leehack/mcp_dart （README：双时代协议、官方一致性测试 alpha.11 全部 25 个授权场景通过、与官方 TypeScript SDK 2.3.1 / Python SDK 2.3.0 双向互操作）

【推断】三个包的 SDK 约束下限（≥3.4.0 / ≥3.7.0）都低于本仓库固定的 Dart 3.13.5，语义化约束上限 <4.0.0，因此均可在当前固定工具链下解析；最终须在引入时以 `flutter pub get` 与 lockfile 实际验证（对应 docs/engineering.md 的 E12 流程）。

【事实】mcp_dart 的直接依赖仅为 crypto、http、meta 等少数包，无原生代码依赖，声明支持 macOS 等平台（pub.dev 平台标签）。这对 macOS 沙盒/公证友好（无额外原生产物需要签名）。
来源：https://pub.dev/packages/mcp_dart

### 1.3 排除项

【事实】pub.dev 上的 `mcp` 包是 0.0.1 占位包，与本主题无关。
来源：https://pub.dev/packages/mcp

## 2. 传输支持

### 2.1 mcp_dart

【事实】mcp_dart 提供以下服务端传输（来源：https://github.com/leehack/mcp_dart/blob/main/doc/transports.md）：

- **StdioServerTransport**：newline-delimited JSON-RPC；stdout 专用于协议帧、日志走 stderr；2.4.2 起默认单消息上限 10 MiB（可配 `maxIncomingMessageBytes`）。平台表明确支持 Dart VM 与 Flutter desktop（可拉起 app 托管的 helper 进程）。
- **StreamableHTTPServerTransport**（底层）与 **StreamableMcpServer**（高层封装）：高层封装接受 `host`、`port`、`path` 参数，可直接 `host: '127.0.0.1'` 绑定 loopback；`enableDnsRebindingProtection` 对 Streamable HTTP 入口默认启用，校验 `Host`/`Origin` 头。官方文档给出的本地开发配方即：绑定 127.0.0.1 + `allowedHosts: {'localhost', '127.0.0.1'}` + 精确 `allowedOrigins`。底层用法也可 `HttpServer.bind('localhost', 3000)` 后把请求交给 transport。
- **IOStreamTransport / 自定义 Transport**：进程内流，适合测试与 isolate 间通信。
- 旧 HTTP+SSE 传输（SseServerManager）仍保留但已废弃（SEP-2596，最早可移除日期 2026-08-18），新项目不应选用。

【推断】绑定 127.0.0.1 的做法与 GLOSSARY.md 的模式 1（HTTP transport on 127.0.0.1）完全吻合，且 SDK 自带 DNS rebinding 防护与 Host/Origin 校验，满足"只服务本机客户端"的安全基线，无需自己实现这层校验。

### 2.2 dart_mcp

【事实】（来源：https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp README）
- 传输以 `StreamChannel` 抽象；内置 stdio channel 与 Streamable HTTP（服务端 `handleStreamableHttpRequest`，客户端 `streamableHttpClientChannel`）。
- Streamable HTTP 仅支持 2026-07-28 协议版本；stdio 握手最高协商到 2025-11-25。
- **不支持 Authorization**（README 明示，定位为"primarily targeted at local MCP server usage"）；不支持 JSON-RPC batching；Cancellation 与 Pagination 为部分实现。

【推断】绑定 loopback 需由应用自己在 `HttpServer.bind(InternetAddress.loopbackIPv4, port)` 层实现（dart_mcp 只提供 request handler，不像 mcp_dart 有内建 host 参数与 DNS rebinding 防护）。对本仓库"仅本机"场景够用，但防护层要自己补。

## 3. 工具定义能力（schema 与注解）

【事实】MCP 规范定义的工具注解字段为 title、readOnlyHint、destructiveHint、idempotentHint、openWorldHint。
来源：https://modelcontextprotocol.io/specification/2025-11-25/schema （ToolAnnotations 条目）；https://modelcontextprotocol.io/specification/2025-11-25/server/tools

【事实】**mcp_dart**：`server.registerTool(name, description:, inputSchema:, outputSchema:, annotations:, callback:)`；`ToolAnnotations` 稳定字段即上述五项（文档明示 legacy priority/audience 仅解析不回写）。内置 JSON Schema 校验器默认 Draft 2020-12、兼容 Draft 7，支持 enum/const/nullable union、进度通知（`extra.sendProgress`）与取消（`extra.signal`）。
来源：https://github.com/leehack/mcp_dart/blob/main/doc/tools.md

【事实】**dart_mcp**：源码 `pkgs/dart_mcp/lib/src/api/tools.dart` 中 `ToolAnnotations` extension type 含 destructiveHint/idempotentHint/openWorldHint/readOnlyHint/title 五字段，与规范一致；`Tool` 工厂含必填 `inputSchema`（ObjectSchema，即 object 根）、可选 `outputSchema`、`annotations`；Schema 体系支持 type/enum/const/allOf/anyOf/oneOf/not，并自带 `validate()` 返回 ValidationError 列表。
来源：https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp/lib/src/api/tools.dart

【推断】对 GhostContainerManager 而言，容器删除等操作可标注 `destructiveHint: true`、只读查询标注 `readOnlyHint: true`，两家 SDK 都不构成阻碍。

## 4. 与 Flutter 桌面应用同进程运行

### 4.1 架构建议

【事实】mcp_dart 官方平台支持表：Flutter desktop 上 stdio 可"拉起 app 托管的本地 helper 进程"，Streamable HTTP 支持"Client and VM-hosted server"（即 VM 内嵌 HTTP 服务端）。SDK 是纯 Dart，server 对象（McpServer + transport）可作为普通 Dart 对象在 Flutter app 主 isolate 常驻，与 UI 共享同一进程。
来源：https://github.com/leehack/mcp_dart （README 平台支持表与 Flutter recipes）、https://github.com/leehack/mcp_dart/blob/main/doc/transports.md

【推断】映射到 GLOSSARY.md 的两种模式：
- **模式 1（HTTP on 127.0.0.1）**：在 app 内用 `StreamableMcpServer(host: '127.0.0.1', ...)` 或底层 transport + `HttpServer.bind(InternetAddress.loopbackIPv4, port)` 常驻；tool 回调直接调用与 UI 相同的 Service layer 单例——这是最简单的同进程共享方式，无需 IPC。建议端口可配并处理占用冲突，且保持 DNS rebinding 防护开启。
- **模式 2（stdio）**：stdio 传输本质是父子进程管道；若复用 app 自身二进制作 helper，则需支持 headless 入口（无窗口模式）并以 `StdioServerTransport` 启动。也可不拆进程：用 `IOStreamTransport` 在进程内同时挂 client 与 server 做自测（SDK 文档的测试范式）。
- server 生命周期应跟随 app 生命周期（启动时 connect、退出时 close）；长任务利用 `extra.sendProgress` 与 `extra.signal` 做进度与取消。

### 4.2 macOS 沙盒与公证

【事实】Apple 官方文档：`com.apple.security.network.server` = "A Boolean value indicating whether your app may listen for incoming network connections"，用于"allow other computers to initiate network connections to your sandboxed app"；TCP 下该 entitlement 只限制连接发起方向，不限制数据流（macOS 10.7+）。
来源：https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server

【事实】Flutter 官方 macOS 构建文档包含 "Entitlements and the App Sandbox" 与 "Hardened Runtime" 章节，即 Flutter macOS 发布流程涉及 entitlements 配置与 Hardened Runtime 公证。
来源：https://docs.flutter.dev/platform-integration/macos/building

【推断】
- 只要启用 App Sandbox（Mac App Store 分发强制；直接分发的公证不强制沙盒），即使只监听 127.0.0.1 也必须在 Release entitlements 中加 `com.apple.security.network.server`，否则 `HttpServer.bind` 会被沙盒拒绝。这是打包配置项，与 SDK 无关，但属于"内置 HTTP server"的已知必备坑。
- 若走 stdio 模式（模式 2）且不监听任何端口，则不需要 network.server entitlement——沙盒下 stdio 管道不受网络 entitlement 约束；但沙盒对 spawn 子进程另有约束（沙盒 app 通常只能 exec 同 bundle 内的 helper，且 helper 继承沙盒），设计模式 2 时须按"同 bundle helper"规划。
- 公证（notarization）层面：纯 Dart 依赖（mcp_dart 无原生代码）不引入额外的签名/公证负担；本地 loopback 监听本身不触发 Hardened Runtime 的额外 entitlement（Hardened Runtime 的例外项针对 JIT、dylib 加载等，不含网络监听）。此点无直接官方条文，属基于 Hardened Runtime entitlement 清单的推论，发布前应以实际公证流水线验证。
- macOS 26 上首次监听端口可能触发"接受传入连接"的本地网络提示/防火墙弹窗（对签名后 app 通常只提示一次）；属推断，需在真机签名构建上确认。

## 5. 推荐选型

### 首选：mcp_dart ^2.4.3

理由（事实支撑见上文各节）：
1. 传输最全：stdio + Streamable HTTP 服务端均可用于 Flutter desktop，唯一内建 127.0.0.1 绑定配方与默认 DNS rebinding 防护的 Dart 包。
2. 协议覆盖最完整且经第三方验证：官方一致性测试（alpha.11，25 个授权场景）通过、与官方 TS/Python SDK 双向互操作；正在申请 MCP SDK Tier 1。
3. 工具定义能力完整：五字段注解、JSON Schema 校验、进度/取消、structured content。
4. 纯 Dart、无原生依赖，MIT 许可证，对沙盒/公证友好。
5. pub 160/160 分，维护活跃（2026-10-14 仍发版），30 天下载量约 237k。

风险（推断）：社区单组织维护，bus factor 高于 dart-lang 官方仓库；2.x 迭代快，升级需关注 changelog（如 2.4.2 的 10 MiB stdio 上限行为变更）。

### 备选：dart_mcp ^0.5.2

适用情形（推断）：更看重 Dart 团队背书与长期归属、或未来官方化（若 Dart SDK 官方采纳）时再迁移。当前短板：experimental 声明、不支持 OAuth（本仓库仅本机使用影响小）、Streamable HTTP 仅 2026-07-28、Cancellation/Pagination 部分实现、无内建 DNS rebinding 防护。若选用，loopback 绑定与 Host/Origin 校验需在应用层补齐。

### 不推荐：mcp_server 3.0.0

【事实】下载量（30 天 ≈1.65k）与社区规模（9 stars）远低于前两者，互操作/一致性无公开验证记录。【推断】协议覆盖宣称虽广，但缺乏第三方验证与生态采用度，不适合作为基础设施选型。

### 落地检查清单（推断，供后续实施工单参考）

- [ ] `flutter pub add mcp_dart` 后跑 E12 依赖检查并提交 lockfile。
- [ ] HTTP 模式：`StreamableMcpServer` 绑定 127.0.0.1，保持 DNS rebinding 防护开启，端口可配。
- [ ] Release entitlements 增加 `com.apple.security.network.server`（若启用沙盒）。
- [ ] 工具按 GLOSSARY 的 MCP 界面规范标注 readOnlyHint/destructiveHint 等注解。
- [ ] server 生命周期挂接 app 启停；长任务接 progress/cancellation。

## 来源汇总

- MCP 规范（2025-11-25 schema / tools）：https://modelcontextprotocol.io/specification/2025-11-25/schema 、 https://modelcontextprotocol.io/specification/2025-11-25/server/tools
- modelcontextprotocol 组织仓库：https://api.github.com/orgs/modelcontextprotocol/repos
- mcp_dart：https://pub.dev/packages/mcp_dart 、 https://github.com/leehack/mcp_dart 、 https://github.com/leehack/mcp_dart/blob/main/doc/transports.md 、 https://github.com/leehack/mcp_dart/blob/main/doc/tools.md 、 https://pub.dev/api/packages/mcp_dart/score
- dart_mcp：https://pub.dev/packages/dart_mcp 、 https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp 、 https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp/lib/src/api/tools.dart 、 https://pub.dev/api/packages/dart_mcp/score
- mcp_server：https://pub.dev/packages/mcp_server 、 https://pub.dev/api/packages/mcp_server/score
- Apple entitlement：https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server
- Flutter macOS 构建：https://docs.flutter.dev/platform-integration/macos/building
