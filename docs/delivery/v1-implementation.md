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
| #18 T3 | 容器写操作全栈 | task-19 lifecycle-builder | task-17、task-18 | 进行中（含 container_kill 与审查修复） |
| #19 T4 | exec 终端与菜单栏 | task-20 ui-prototyper | task-19 | 待 T3 |
| #20 T5 | 镜像通路全栈 | task-21 mcp-architect / task-27 mcp-fixer | task-15、task-16 | 已实现（085b9b7），审查修复中 |
| #21 T6 | 挂载/网络/Compose 通路 | task-22 platform-analyst / task-28 platform-fixer | task-15、task-16 | 已实现（085b9b7），审查修复与构建验证中 |
| #22 T7 | 项目工作流与 registry（服务层 + 11 工具） | task-23 mcp-architect | task-19、task-21 | 待 T3、T5 |
| #23 T8 | 项目页 UI（D11 终轮版） | task-24 ui-prototyper | task-23 | 待 T7 |
| #24 T9 | MacLauncher 集成 | task-25 platform-analyst | task-19 | 待 T3 |

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
- 下一阶段：T3 容器写操作全栈（lifecycle-builder，含 container_kill 与审查修复）；T4 为 exec 终端与菜单栏，待 T3。
