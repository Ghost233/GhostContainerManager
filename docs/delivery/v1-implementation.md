# v1 实施交付记录（当前入口）

- 起始：2026-10-23；Lead：DSH lead（spec-delivery 流程）
- 规格基线：地图 #1（已关闭）+ `docs/spec/` 七份简报 + `docs/research/` 五份调研 + `GLOSSARY.md`
- 交付起始 SHA：`e75fcfa`（main）
- 分支策略：阶段分支 → 阶段 PR → `integration/v1`；总 PR `integration/v1` → `main`（只标 ready，不合并，除非用户明确要求）
- Git 规则：写操作仅 Lead 串行执行；成员不暂存/提交/切分支；提交前收齐暂停写入确认

## 验收条件

- 检查入口：`scripts/test-host.sh`（prepare/check/analyze/test/format；需 `GCM_FLUTTER_SDK=$HOME/flutter`、`GCM_TEST_PYTHON`）
- 构建门禁：release 模式 macOS 构建（engineering.md §构建）在 P5 总验收执行
- 实机冒烟：本机 container **1.5.0**（用户决策：先用 1.5.0 开发）——onboarding 的版本地板（≥1.6.0）在 debug 构建下可用环境变量 `GCM_DEBUG_ALLOW_UNSUPPORTED_RUNTIME=1` 绕行（仅开发用，release 不生效）；集成冒烟避开 1.6.0 独有命令
- TDD：实现成员按 `tdd` skill 先红后绿，验收附真实退出码
- 审查：每阶段 Standards + Spec 双轴并行只读审查（code-review 方法），复盘修复 P0/P1/P2；实现者不审自己的变更
- CI：不加（用户决策）

## 阶段（工单对齐，spec #15 → tickets #16–#24）

| 工单 | 内容 | 板任务 / 负责人 | 阻塞 | 状态 |
|---|---|---|---|---|
| — | P0 Flutter 脚手架 | platform-analyst | — | 完成（#14，merge 807ec04） |
| #16 T1 | 运行时通路与 MCP 骨架（onboarding + system_* + MCP server） | task-15 mcp-architect（服务侧）/ task-16 platform-analyst（UI 侧） | — / task-15 | 完成（merge 2508965） |
| #17 T2 | 容器只读通路（列表/详情/日志 + 只读工具） | task-17 lifecycle-analyst / task-18 ui-prototyper | task-15 / +task-16 | 完成（2508965 + 085b9b7） |
| #18 T3 | 容器写操作全栈 | task-19 lifecycle-builder | task-17、task-18 | 完成（4f1cb2b；双轴审查进行中） |
| #19 T4 | exec 终端与菜单栏 | task-20 terminal-builder | task-19 | 完成（a683b2e） |
| #20 T5 | 镜像通路全栈 | task-21 mcp-architect / task-27 mcp-fixer | task-15、task-16 | 已实现（085b9b7），审查修复中 |
| #21 T6 | 挂载/网络/Compose 通路 | task-22 platform-analyst / task-28 platform-fixer | task-15、task-16 | 已实现（085b9b7），审查修复与构建验证中 |
| #22 T7 | 项目工作流与 registry（服务层 + 11 工具） | task-23 mcp-architect | task-19、task-21 | 待 T3、T5 |
| #23 T8 | 项目页 UI（D11 终轮版） | task-24 ui-prototyper | task-23 | 待 T7 |
| #24 T9 | MacLauncher 集成 | task-25 platform-fixer | task-19 | 已实现（a683b2e + Lead 接线）；审查修复 task-31 |

审查点：T1 完成后阶段审查（Standards+Spec）；其后按 T2/T5/T6、T3/T4、T7/T8、T9 分批审查；最终总审查覆盖 e75fcfa..总候选。

## 候选与证据记录

（随阶段推进追加：候选 SHA、审查报告指针、验收命令与退出码、未关闭问题、下一动作）

### 2026-10-24 00:xx T1+T2a（2508965）

- 候选 SHA：`2508965`（integration/v1，含 T1a 4f0cf84、T1b+T2a 2508965）
- 证据：`test-host.sh check` exit 0（85 tests，run-qy748e / run-ChgWlU）；`flutter build macos --debug` exit 0（首次 SwiftPM 全量解析后通过）
- Lead 修复：`system_tools.dart` openWorldHint false→true ×3（对齐 mcp-tools.md）；Runner 部署目标 12.0→15.0（container_bridge 插件最低 15.0，lifecycle-analyst 越权但必要，已记录）
- 未关闭问题（P1）：设置页「最近 MCP 调用简表」为占位（recentCalls 恒空），需 GcmMcpServer 提供调用记录 hook——排入 T9 阶段或收尾任务
- 环境备注：`GCM_TEST_PYTHON` 需指向 /opt/homebrew/Cellar/python@3.14/...（homebrew python3.14 prepare 过指纹）
- 阶段审查：Standards + Spec 双轴子代理已完成，均无 P0；修复轮 = task-26（lifecycle-analyst）
  - P1 修复：system_* 输出契约补 versionSupported/startupMs/kernelInstalled/containersStopped、installKernel 默认 true、unawaited+dispose 接线、system_* 一行摘要
  - P2 修复：errors source 字段、MCP instructions 英文、日志 parser 测试+eof 冲刷、Swift 注释、wireName 大小写、失效 .gitkeep
  - 文档债（Lead 已修）：mcp-tools.md §3.1 container_get → container_inspect
  - 延期记录：recentCalls 调用记录 hook（T9/收尾）；端口持久化；「打开下载页」按钮（需 url_launcher 依赖）；seam containerInspect/container.get 命名统一（动 API 面另议）。工具 name/title 英文已落档（mcp-tools.md §8 Q4，description v1 沿用中文）。

### 2026-10-24 02:2x T2b + T5 + T6 + 审查修复轮

- 内容：T2b 容器页 UI（#17 验收 1/2）；T5 镜像通路全栈（#20：service/MCP 4 工具/桥接三层/Swift ImageOps+containerization 0.52.1/镜像页）；T6 挂载/网络/Compose 通路（#21：7 工具/三 service/三页/compose CLI 冒烟证据）；task-26 审查修复（P1×4+P2×6 全落地）；Lead 统一接线（GcmMcpServer 注册 image/mount/network/compose 四域共 17 工具、app_shell 镜像页、instructions 英文更新）
- 证据：prepare+check 全绿，174 tests（run-KxDiop）；T6 compose 插件本机 CLI 冒烟 exit 0
- 修复要点：Utf8Decoder allowMalformed:true 对齐 Swift 容错解码；installKernel=false 不探测内核（收尾 checkReadiness 自身探一次）；fake pullHangs 改 Completer 闸门（fake-async 泵不出定时器链）
- 构建门禁：当前批次已通过。早先 run-44LdNO 失败（GeneratedPluginRegistrant/macOS 12.0 诊断）未再复现；保留 ImageOps imports 与 Package.swift products 修复后，platform-fixer 在 HEAD `085b9b7` + 当前工作区复跑 `flutter build macos --debug`，PIPESTATUS[0]=0，生成 `build/macos/Build/Products/Debug/GhostContainerManager.app`，未改 macos 文件（三处 deployment target 本已 15.0）。最终复验日志 `/tmp/gcm-task28-macos-debug-final.log`（BUILD_EXIT_CODE=0）；配置链证据为 macos/Runner.xcodeproj/project.pbxproj:353-360（GeneratedPluginRegistrant 属 Runner sources）与 :556（project Debug=15.0），ephemeral 无覆盖；仅有 ContainerBridgePlugin.swift:320 Sendable warning。真机 1.6.0 仍未验证，后续批次与总验收仍须重跑构建。
- 双轴审查（Standards c066 + Spec 855）结论：无规格级 P0；Standards 将上述未通过的 Swift 构建列为 P0。P1 修复已分派：镜像拉取失败 UI、ImageService 删除预检接线（Lead 已修）、CLI/XPC source、guardToolCall 归并、非 GcmException 兜底与 unawaited；P2 修复含英文工具 title、注释漂移、日志 5000 行尾部上限、保留 full_wiring_test。
- 修复验收：task-27 完成（镜像失败 UI、guard 归并、XPC source、14 个英文 title；定点 44/44 exit 0，run-GOYbPk）。task-28 完成（T6 source/unawaited/兜底/注释/full_wiring_test；定点 29 + MCP 2 exit 0；macOS 最终构建 exit 0）。两者全量检查恰逢 T3 接口在飞而失败（container start/activityFor 尚未同步等），不记为回归；待 T3 收尾后由 Lead 重新执行，不沿用并发现场结果。
### 2026-10-24 03:2x T3 + 审查修复集成（4f1cb2b）

- 候选 SHA：`4f1cb2b`（integration/v1，含 T3、task-27、task-28、Swift 导入修复与 Lead 集成）。
- T3：Swift/XPC create/start/stop/delete/kill；Service 同操作 Future 合并、异操作排队、restart 单锁合成、queued/active stop/restart 时 delete CONFLICT、乐观快照与合成态；六个 MCP 写工具；UI 五操作、创建表单、force 分叉、stop 15s 等待上限；日志尾部 5000 行。
- Lead 集成：`test/mcp/mcp_full_wiring_test.dart` 从 17 子集加强为精确 23 工具集合，并让 ImageService 预检接线与 app 一致。
- 证据：`test-host.sh check` exit 0（format/analyze/205 tests，run-VG2oWA）；bridge package analyze 无问题；macOS debug build 通过（T3 实现者与 task-28 分别验证）。
- 残余验收：未执行真实 Apple container 写操作或人工窗口视觉验收。
- T3 双轴审查结果（085b9b7..4f1cb2b，两轴均无 P0）：P1 直接修复项=P1-C stop 补 stoppedGracefully/kill 补 status（测试改断言契约）、P1-D 并发同名 create→CONFLICT、stop/delete 按参数区分合并、P1-E Service 输入校验（id ≤63、端口格式、signal 白名单、错误码 INVALID_ARGUMENT 映射）；P2 低成本批量=读工具英文 title、注释漂移、UI env/命令/端口解析、弹窗 432→480、TIMEOUT 映射、合成态 overlay/refresh。全部归入 task-30（blockedBy task-20）。
- 用户拍板（2026-10-24，ask_user_question 双裁决）：
  1. **create 能力面**：v1 补 mounts+labels（挂载/标签全链路：Swift→bridge→Service→MCP schema→UI 表单分段）；cpus/memoryBytes 延 v2。规格已改：mcp-tools.md:40、container-lifecycle.md create 行、ui-ia.md D10。
  2. **create 不自动 pull** 定为正式语义：镜像须本地已有，缺失 NOT_FOUND 且文案指名 image + 提示先 image_pull；pulling 合成态随之取消；lifecycle:69 已由「缺时 fetch」改为本地镜像-only。
- 延期记录（不随 v1 修）：日志初始 500 行/筛选/导出/暂停、bootlog 来源切换、UI stop 高级 timeout/signal、deleting 行置灰、cpus/memoryBytes。
- 并行边界：T4 与 T9 启动；T7 与 T4 共用容器桥接文件，待 T4 定型后启动，T8 继续等待 T7。

### 2026-10-24 11:xx T4 + T9 + MCP 审计（a683b2e + Lead 收尾批）

- T4（task-20，terminal-builder）：一次性非 TTY exec 全链路（ExecOps.swift best-effort SIGKILL 超时 + 64KiB/流截断 + 3s drain）、container_exec 工具（timeout 默认 60/上限 600）、菜单栏（运行中 ≤5 + 快捷停止 + 空态，原生 MenuBarController.swift + Dart MenuBarController）、设置页通用区块（D9）。228/228 tests（run-hjnh0B + Lead 复验 run-x2LFwt）。
- T9（task-25，platform-fixer）：MacLauncherBridge 适配层（四回调、仅 com.ghost233.* 注册、断连不动容器、onLogs 批式映射）+ 9 测试；连带修复 eventTransformed 日志取消根因（container_logs_parser.dart，Lead 授权扩域）。
- task-29（Lead）：MCP 调用审计层（tool_audit.dart：McpToolAuditor 环形 20 条 + AuditedMcpServer override registerTool，finally 记录工具名/时间/成败/耗时，不记参数）+ GcmMcpServer/controller 接线 + 设置页「最近调用」非空简表（_RecentCallsList）+ e2e（真实 HTTP tools/call 落记录）+ widget 测试。issue #16 验收项「最近调用简表」由占位转实装。
- Lead 集成：MacLauncherBridge 挂到 app.dart composition root（enableLauncher 参数、connect 失败降级 debugPrint、dispose 先于 ContainerService，E04）；app_shell_test 补 enableLauncher:false。
- 证据：`test-host.sh check` exit 0（229 tests，run-QfGWiy）。
- Spec 轴审查（537c2360，范围 4f1cb2b..a683b2e）：#19 五条中四条代码级满足；#24 P0-1 桥未接线（Lead 收尾批已补 app.dart 接线）→ 转 P1/P2 修复任务 task-31：P1-1 onLogs 等 EOF 对运行中容器挂起、P1-2 注册静态快照（新容器不自动注册）、P2-1 lifecycle exec 默认 30→60 漂移、P2-3 maclauncher.json services 空（需裁决动态注册下的写法）、P2-4 LogStream stdio→unknown 归因复核。P2-2 菜单栏 D4 完整形态（状态行/▣n/启停运行时/MCP 项）记录为 v2 延期。
- Standards 轴审查（b90c57b0）待收。
- Standards 轴审查（b90c57b0，同范围）：无 P0；P1×2（P1-1 零接线同 Spec P0-1，已由 0e9d5c3 关闭；P1-2 静态注册快照同 Spec P1-2 → task-31 动态注册）。P2 处置：ContainerService.dispose 悬挂 Future → 追加进 task-30；auditor 自建时 _changes 未 close → Lead 已修（_ownsAuditor + dispose）；connect/dispose 竞态、timedOut→TIMEOUT 测试、menu_bar 测试补强、LogStream 归因复核 → task-31；菜单栏 D4 完整形态（状态行/▣n 图标/启停运行时/MCP 项）→ v2 延期（与前批记录一致）；ExecOps 超时 kill 有界挂起、Swift 字节截断 U+FFFD → 记录不修（注释已自知，规格未强制边界安全）；app.dart 菜单初始化无超时 → 记录，总验收时评估。recycle 对已停容器语义依赖运行时 → 列入实机验收清单。
