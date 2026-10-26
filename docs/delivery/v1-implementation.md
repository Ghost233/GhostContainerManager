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
- T7 阶段一 + 中央接线（306a216 CLI 接缝 + 00e8bd6 T7）：ProjectService/RegistryService（注入式 ProjectCli，prefix-only toml、同名替换、无引用释放+CLI 终审、失败日志 tail1000 留 20、registry 127.0.0.1:5056 plain HTTP）+ project_* 8/registry_* 3 工具中央接线（24→35）+ BridgeProjectCli 生产 adapter。全量 289/289、analyze 0。文档修正：project_build skipTests 默认 false→true。注意：曾发生一次未授权 git restore 导致 mcp_server.dart/full_wiring_test 的接线被还原，Lead 重新接线并复验；后续批次提交前须先 git status 全量核对。
- T7 批次双轴审查（范围 0777297..35ae206）：Standards P0×1（cli.process 订阅键名 id/handle 不一致，生产流式 CLI 必败，两侧测试各自固化本侧键名）+P1×5+P2×11；Spec 无 P0/P1、P2×5。处置：task-33（桥接/Swift：键名统一 handle、_fail 补 cliTerminate、CliStreamSession 无条件 onFinish+pendingEvents 上限 1000 行、CliError 实现 LocalizedError、SIGKILL 升级、pid 复用防护）→ lifecycle-builder；task-34（服务/MCP：path 回落改 INVALID_ARGUMENT、progress 100ms 节流、_runCli TIMEOUT 映射、Dockerfile 缺失预检 NOT_FOUND、bundle id 收敛常量）→ mcp-fixer。Lead 规格回写：registry_stop 表补 D（中断在途传输）；§2.4 补 reclaim allowFallback:false 保守边界。记录不修：内存引用快照 UI 初判、_projectPaths 重启丢失（v1 无扫描根概念）、skipTests 陷阱参数（description 已说明）、disk usage 启发式（system df schema 未实证，实机验收清单）。
- T8 项目页 UI（task-24，ui-prototyper）：列表五列+AppOwnedTag、磁盘快照手动刷新（独立 df 查询）、空态/运行时占位、搜索、详情镜像列表+成员容器、构建日志面板（实时滚动/成功/失败+落盘回看）、一键回收弹窗（force 默认勾选+将删除/跳过+报告卡）、三选删除弹窗；11/11 widget 测试。
- task-35（mcp-fixer）：ProjectBuildLogStore 可注入接缝（FileProjectBuildLogStore 默认实现，尾部1000行/留20/UTC 命名；store 异常降级 failureLogPath=null）。解 widget 测试跨 zone 挂起的根因。
- task-31（platform-fixer）：MacLauncher 动态注册（快照订阅+ID 差异重建）、onLogs 250ms 固定窗口、connect/dispose 竞态、17/17 定点。
- task-33（lifecycle-builder）：**P0 修复** cli.process 键名 id→handle 统一（Swift 为准）+契约注释；_fail 进程组终止；CliProcess tail1000/无条件 onFinish/5s 订阅宽限/pid 复用防护；CliError LocalizedError；超时 SIGTERM→SIGKILL。
- task-34（mcp-fixer）：path 缺失 INVALID_ARGUMENT、Dockerfile 缺失 NOT_FOUND、TIMEOUT 映射、Service 层 100ms progress 节流（leading/coalesce/trailing）、app_constants.dart bundle id 收敛。
- Lead：app_shell/app.dart 项目页接线（projects: _projectService）；规格回写（maclauncher v1 裁剪：自动注册+动态增删，逐容器开关/pending-approval UI 延 v2；registry_stop 补 D；reclaim allowFallback:false 边界）。
- 全量验收：check exit 0（format/analyze/315 tests），证据 .tooling/host-tests/run-7ssc1d。
- T8 批次双轴审查（Spec acf59f69 / Standards e863354b，范围 cdd7569..b4e3af6）：均无 P0。合并后 P1：标题栏缺推送按钮、新建项目按钮未接线、force 复选框死控件、pushed 徽标缺失、成员容器表缺时长/行内操作、磁盘快照借道 reclaim dryRun（接缝误用）、磁盘列逐行全局值误导。处置：task-36（服务支撑，mcp-fixer）+ task-37（UI，ui-prototyper，blockedBy task-36）。P2 处置：进 task-36/37（RegExp.escape、自动跟随、cancelled 态、报告卡注记、日志文件名 sanitize、push 失败清 tag、readLatest 历史回看）；文档侧 Lead 修（container-lifecycle.md exec 默认 30→60 已改；ui-ia.md D11「逐行显示」→「10Hz 合并」待改）；观察项记录（MacLauncher _drainSync 注释、df schema 真机待验）。Spec 轴误报一项：三选弹窗「归档并推送」按钮实际存在（project_dialogs.dart:171），实为标题栏缺推送入口。
- 依赖新增：file_selector ^1.1.0（目录选择器，task-37 用），lockfile 已锁定。

## 实机验收（2026-10-24，container CLI 1.5.0 + debug 旁路，commit 565ca1e/921a4a3）

MCP 全链路在真实运行时验证通过：35 工具 tools/list、system_status（五级短路）、container_list（真实 25 容器）、image_pull registry:2（XPC）、registry_start/status/stop（gcm-registry @5056）、project_init（prefix-only toml）、project_build（**`container build --label` 实证通过**，镜像 config.Labels 含 `com.ghost233.project`）、project_publish（推送 127.0.0.1:5056/gcm-smoke-demo:latest）、project_get/reclaim（dryRun 预测 + force 实删双 tag，磁盘快照 before/after 正常）。冒烟资源已清理（registry 容器停止并删除，/tmp/gcm-smoke-proj 移除）。

实机抓出并已修三个缺陷：
- D1：`_imageInventory` 遇外部 digest 寻址镜像抛 INVALID_ARGUMENT 致 project_* 全瘫 → 跳过 digest inspect 走 fallback（565ca1e）。
- D2：`container system df` 1.5.0 实际键 `sizeInBytes` 解析失败 → 键清单兼容（565ca1e）。
- D3：containerization OCI config CodingKeys 大写（Env/Labels/…）致 image_inspect 丢 labels/env/cmd → ImageOps.swift 双 case 读取（921a4a3）；此缺陷曾导致项目 label 归属失效（reclaim 零候选）。

总审查（双轴，e75fcfa..4a33da7）：两轴均判可合入、P0=0；P1 两条（network_get 参数 id 化、四工具补 outputSchema）已修于 565ca1e；P2 文档陈旧（ui-ia 端口、lifecycle exec 30s、§3.1 工具数）与 app.dart `_mcp.dispose()`（E04）已修。全量 326 tests 绿（run-5M2po2）。

遗留观察项（v1.1/v2 候选，不阻断）：registry_start 缺 registry:2 时不自动拉取（hint 引导 image_pull）；onRecycle 停止态 restart 语义待 1.6.0 真机确认；菜单栏 D4 完整形态延 v2；readiness_controller 直用 bridge 的 kernel probe（E06 洁癖项）；后台 10s 轮询档未接线；UI 分页视觉走查留人工。

## 正式发布 v1.0.0（2026-10-25）

- 版本由用户手动确定：`1.0.0`（`0.0.0` 占位解除）。发布提交 `25f7162`，附注 tag `v1.0.0`。
- 本地门禁：`scripts/test-host.sh check` exit 0（357 tests，run-IhYioA）；发布包预检 `scripts/build-release.sh --output-dir .tooling/release-precheck` exit 0（DMG 校验 bundle id/版本/arm64 架构）。
- `scripts/release.sh --dry-run` 核对通过后正式推送 tag，触发 release.yml run 40122982424（10m35s，success）。
- Release：https://github.com/Ghost233/GhostContainerManager/releases/tag/v1.0.0（非草稿、非预发布）。
- 资产：`GhostContainerManager-1.0.0.dmg`（29,428,019 B）、`manifest.json`、`SHA256SUMS`。
- 同步核验：本地 `v1.0.0` tag、本地 main、origin/main 均为 `25f7162`；tag 提交的 `pubspec.yaml` 版本为 `1.0.0`。
- 分发方式：未签名、未公证（发布前经用户确认）；后续正式分发需补 Developer ID 签名与公证。

## 正式发布 v1.0.1（2026-10-25）

- 名称与品牌：应用显示名由 `GhostContainerManager` 改为 `Ghost Container Manager`（`PRODUCT_NAME`、窗口标题、访达、关于页、`maclauncher.json` 项目名与入口路径）；打包资产名保持 `GhostContainerManager-<版本>.dmg` 不变。
- 图标：用户提供的新图标替换 `AppIcon.appiconset` → `GhostContainerManager.appiconset`（`ASSETCATALOG_COMPILER_APPICON_NAME` 指向新集），旧图集移除；`flutter clean` 全新构建确认产物仅含新 `GhostContainerManager.icns`。
- 关于页改为读取构建期 `--dart-define=GCM_APP_VERSION`（`scripts/build-release.sh` 注入实际版本），本地开发构建显示“开发版”。
- 版本由用户确定并累加：`1.0.0` → `1.0.1`。发布提交 `578b567`，附注 tag `v1.0.1`。
- 本地门禁：`scripts/test-host.sh check` exit 0（357 tests，run-JnvE4t）；`scripts/build-release.sh` 全新构建 exit 0（产物 `Ghost Container Manager.app`，bundle id `com.ghost233.ghostcontainermanager`，版本 `1.0.1`，arm64）。
- `scripts/release.sh --dry-run` 核对通过后正式推送 tag，触发 release.yml run 40163677685（success）。
- Release：https://github.com/Ghost233/GhostContainerManager/releases/tag/v1.0.1（非草稿、非预发布）。
- 资产：`GhostContainerManager-1.0.1.dmg`（31,454,304 B，sha256 `7753ac23…`）、`manifest.json`、`SHA256SUMS`。
- 同步核验：远端 tag 指向 `578b567`，本地 main 与 origin/main 均为 `578b567`；manifest 记录版本 `1.0.1`。
- 分发方式：仍未签名、未公证（沿用 v1.0.0 的用户确认）。

## 项目页镜像磁盘占用（1.0.2）

- 需求（用户）：项目页每个镜像「运行了多少个容器、占用空间多少（含展开后）」；同时排查系统盘不足。根因实测：`~/Library/Application Support/com.apple.container` 249 GB，其中 `snapshots/` 143 GB（容器 rootfs 稀疏文件 `rootfs.ext4` 的**表观大小**）与 `containers/` 88 GB（initfs 系统盘 45 GB + kernel 23 GB + rootfs 真实占用），镜像 blob 仅 15 GB；`container system df` 的 169.9 GB 是未压缩层大小而非磁盘占用。
- 新增 `ImageFootprintService`（`lib/services/image_footprint_service.dart`）：
  - `expandedSizeBytes`：解析 OCI index→arm64 manifest→真实解压每层 gzip 求和（Docker 虚拟大小），blob 缺失/非 gzip/超限时降级返回 null，不伪造大小；索引缓存写入 Application Support（按 blob mtime 失效）。
  - `layerDiskBytes`：layer blob + manifest + index 的 `stat.st_blocks*512` 实际占用；多 tag 共享层按唯一 blob 计一次。
  - `footprintFor`：三口径合并（展开/层实占/容器目录实占），容器目录用 `du` 精确统计 initfs、kernel 与稀疏 rootfs。
- UI：镜像行改为「下载 X · 展开 Y（可重试）· 实占 Z」三口径；项目列表磁盘列改为实占合计（镜像层 blob + 成员容器目录），列头「实占」并附口径提示；展开计算并发、可重试、带 `计算展开大小 n/m` 进度。
- 规格同步：`docs/spec/ui-ia.md` §D11 改为三口径语义；MCP `project_get` 的 `ProjectSummary.images` schema 不变（digest 不入 JSON）。
- 门禁：`scripts/test-host.sh check` exit 0（368 tests，run-SdD07B）；`projects_page_test` 24/24、`image_footprint_service_test` 9/9。
- 用户待决策项（记录，未实施）：1 GB 日志的具体位置待用户确认（实测未见 1 GB 日志，最大为 builder buildkit-cache 1.3 GB，`builder stop/delete` 可回收）；无效构建（仅 go1/go2 有效）的改名/删除策略；权限允许时工具改为标准 OCI 镜像（`apple/container` org 包）以消除影子注册表；MCP 端口 35731 明文仅限 loopback。

## 正式发布 v1.0.2（2026-10-25/26）

- 版本由用户确认继续累加：`1.0.1` → `1.0.2`（本次改动＝项目页镜像三口径占用 + 项目列表实占合计）。
- 发布提交 `5caac4d`，附注 tag `v1.0.2`。
- 本地门禁：`scripts/test-host.sh prepare` 后 `check` exit 0（368 tests，run-52JHXh）；`scripts/release.sh --dry-run` 核对版本/tag/提交一致。
- release.yml run 40210106414（success）：https://github.com/Ghost233/GhostContainerManager/actions/runs/40210106414
- Release：https://github.com/Ghost233/GhostContainerManager/releases/tag/v1.0.2（非草稿、非预发布，2026-10-25T16:20:04Z 发布）。
- 资产：`GhostContainerManager-1.0.2.dmg`（31,490,129 B）、`manifest.json`（181 B）、`SHA256SUMS`（178 B）。
- 分发方式：仍未签名、未公证（沿用 v1.0.0 的用户确认）。

## MCP 精简注册模式（2026-10-26，用户拍板）

- 动机：35 个业务工具全量注册让 MCP 客户端工具列表过长、挤占上下文。用户原话：「能不能用类似cli的那种方式,只暴露2到3个接口,获取help,然后填参数这种,否则太长了」。
- 形态：`tools/list` 只暴露 `gcm_help`（按域分组的工具目录：名称/title/描述要点/RO·D·I 注解，支持 `domain` 过滤）与 `gcm_call`（`tool` + `arguments` 按名分发；未知工具名 → `NOT_FOUND` 工具错误并提示先调 `gcm_help`）。35 个业务工具的实现/schema/注解不变。
- 结构：新增 `lib/mcp/tool_catalog.dart`（35 条目单一事实来源，须与 docs/spec/mcp-tools.md §3 同步）、`lib/mcp/tool_registrar.dart`（`ToolRegistrar` 结构接缝 + `ToolCallbackRegistry` 收集器 + `McpServerRegistrar` 适配器）、`lib/mcp/tools/catalog_tools.dart`（两个入口工具 + `buildBusinessToolRegistry`）。`GcmMcpServer.buildServer` 改为注册两个入口工具；业务工具 callback 经 `_auditedRegistry` 包装保持工具粒度审计（gcm_call 入口本身也记一条）。
- 测试：协议级测试的 `callTool` 一律改经 `gcm_call` 转发；`tools/list` 断言改为「恰好 {gcm_help, gcm_call}」+ `gcm_help` 目录断言；新增 `test/mcp/catalog_tools_test.dart`（目录 35 条/八域/查找/注册表收集）。MCP 套件 64/64 绿。

## v1.0.3 发布（2026-10-26）

- 发布内容：MCP 精简注册模式（fe654ad，gcm_help + gcm_call 双入口，35 业务工具经分发表调用）。
- 版本提交 38f23d3（`chore: bump version to 1.0.3`）；本地门禁：test-host check 372/372（run-ltaLZq）、build-release 预检 OK（arm64 DMG 31,501,734 B）。
- tag v1.0.3 推送后 release.yml run 40278597713 结论 success；Release 正式发布（非草稿/预发布），资产三件齐全：GhostContainerManager-1.0.3.dmg（31,487,792 B，sha256 80cc9479…）、manifest.json、SHA256SUMS。本地 main、origin/main、tag 同指 38f23d3。

## MCP 加固里程碑（#28，T1–T4，2026-10-26）

- 分支 feature/mcp-hardening；外部审查简报 16 条整份采纳，工单 #29–#32 落地，#33 真实环境验收待做。
- **#29 注册表地基**：`lib/mcp/tool_catalog.dart` 重写为声明式注册表单一事实来源（35 条目含 inputSchema/outputSchema/五字段注解/meta，`registerCatalogTool` 绑定器）；gcm_call 分发前用 mcp_dart 2.4.3 公开导出 `JsonSchemaValidation.validate` 校验参数，失败 INVALID_ARGUMENT 中文 message + hint，handler 不执行；`ToolCallbackRegistry` 存 `ToolDefinitionSnapshot` 快照，审计重注册全元数据。
- **#30 注解/帮助**：保守风险注解穷举 35 工具（gcm_call 标 destructive=true；container_restart 非幂等）；gcm_help 三模式（default 域索引瘦身 / domain / tool 完整 schema+注解）；catalogRevision=目录 JSON 规范化 SHA-256 截 16 hex。
- **#31 分页**：新建 `lib/mcp/tools/pagination.dart`（默认 limit=50/上限 500/超限 INVALID_ARGUMENT；信封 total/returned/hasMore/nextOffset）；6 个列表工具接入并稳定升序排序；文本摘要瘦身（前 5 标识+折叠；gcm_help 文本通道一行摘要）。
- **#32 版本/长任务**：serverInfo.version 复用 `gcmAppVersion`（与「关于」区块同源）；长任务核对 5 测试钉住（exec TIMEOUT 含查询方法、abort→cancelPull 透传、progressToken 进度透传）；exec 超时口径统一 60；LogStream stdio→unknown 复核为诚实归因保留。
- 已知限制（简报核对结论）：system_start 无进度通知；exec 外无 MCP 侧超时与取消通道；image_pull 取消后运行时状态未知（查 image_list/image_inspect）；exec 超时=放弃等待进程可能残留（apple/container#1941）。
- 测试：418 全绿（证据 run-AB6aN3 + Lead 复跑 run-7hYxB1）；新增 gcm_call_validation/list_pagination/long_task_semantics/server_info_version 等测试文件。
- 过程事故记录：「提交成功」输出一度为假（reflog 证实 31703b4/7cd8a7e/4b62f97 三提交从未存在，改动堆在工作区后单次提交 2fe37da 落盘）；#30 的 gcm_help tool 模式与 catalogRevision 当时虚报已交付（实被并发改写丢失），#33 验收抓出后重开 #30 补齐。自此所有交付以 Lead 亲自复跑验收脚本为准。

## MCP 加固里程碑 T5 真实环境验收（#33，2026-10-26）

- 交付物：`scripts/mcp-handshake-smoke.sh`（双通道握手探测，exit 0/1/2）、`scripts/mcp_acceptance.dart`（smoke/chain/concurrency/pagination/help-modes 五子命令验收客户端）、docs/agents/mcp.md（用法与 release 核对清单）；证据 .tooling/mcp-acceptance/full-evidence.log。
- Lead 亲自复跑结论：smoke PASS（version=dev≠0.0.0、protocolVersion=2025-06-18、tools/list 恰好 {gcm_call,gcm_help}）；chain PASS（双通道 system_status→project_list→image_list 真实数据，159 镜像/33 容器）；concurrency PASS（×5 distinct=1）；pagination PASS（159 镜像 23 页 limit=7 不重不漏，CLI 对照差 2 个 Apple 内部镜像属 CLI 隐藏行为）；help-modes PASS（#30 补齐后，含 tool 模式与 catalogRevision）。
- 本机运行时实为 container 1.6.1（非早前记录的 1.5.0）。macOS 26 虚拟机出包验证留 release 时人工执行（核对清单在 docs/agents/mcp.md）。
- CI 门禁接入建议（未实施）：release 打 DMG 后跑 smoke 断言 version=发布版本号；端口隔离用 --port。

## 里程碑收口记录（#28 合并）

- 总审查：双轴（Standards 760f089d / Spec 25610727）对 main..feature/mcp-hardening（29 文件 +4435/−1292）一致结论「可合并」，无 P0/P1；P2 项（审计工具名双写漂移、已知限制表格化、registry 51 容器实例化、CLI parity 定时核对）已记录。
- 合并：PR #34 squash → main b8edb36「MCP 加固里程碑：注册表校验、保守注解、分页契约与真实验收（#28）」；远端分支已删，本地 feature 分支已清。
- 合并后门禁：main 上 scripts/test-host.sh check exit 0，431/431 tests（run-L0Gbik）。
- 遗留：v1.1.0 发布待维护者触发；macOS 26 虚拟机出包验证随发布人工执行。

## 总审查修复记录（issue #35，PR #34 合并后 fix-forward）

背景：PR #34 合并时依据的 Spec 审查摘要「无 P0/P1」是该子代理的中间态误报；其最终报告含 1 P0 + 2 P1（m06574）。教训：审查结论以最终完整报告为准，中间消息不作合并依据。

修复（全部测试钉住，435/435 绿，run-aKH081）：
- P0：gcm_call 外层注解 destructiveHint 改 true（该值全史从未为 true，是 #30 验收 1 的实际回归；tools/list e2e 钉住）。
- P1：每工具示例——lib/mcp/tool_example.dart 从 schema 派生示例（枚举首值/minimum/required-only），gcm_help tool 模式输出 example 字段，35 个示例逐一过内建校验器的强制测试。
- P1：docs/agents/mcp.md 订正（三模式 + catalogRevision 说明、isError 结构化错误替代 -32602 旧说法）。
- P2 批：catalogRevision 截前 12 位对齐规格；gcm_help 未知 domain 改 handler 级中文 INVALID_ARGUMENT（domain schema 去掉 enum 让错误到 handler）；tool_registrar 死防御与未使用的 McpServerRegistrar 删除；list_pagination_test HttpClient 每测试新建并 tearDown close；server instructions 补 catalogRevision 缓存提示。

合并后 P2 跟进清单（两轴不重叠，共 8 项）：审计工具名双写漂移、已知限制表格化、registry 51 容器实例化核对、CLI parity 定时核对、纯 Dart SHA-256 vs crypto 直接依赖、T5 CI/release 握手门禁接入、macOS 26 VM 出包验证（随发布人工）、GUI 同刻一致性核对记录。
