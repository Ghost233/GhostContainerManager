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

## 阶段

| 阶段 | 内容 | 负责人 | 状态 |
|---|---|---|---|
| P0 | Flutter 脚手架 + 包结构 + 检查通过 | platform-analyst | 进行中 |
| P1 | container_bridge（XPC+CLI runner）+ Service layer 核心 + 生命周期 | mcp-architect / lifecycle-analyst | 待 P0 |
| P2 | MCP server（mcp_dart，HTTP+stdio helper）+ 34 工具 | mcp-architect | 待 P1 |
| P3 | UI 页面 + 菜单栏 + onboarding | ui-prototyper / platform-analyst | 待 P1 |
| P4 | 项目工作流 + registry + 项目页 | lifecycle-analyst / ui-prototyper | 待 P2、P3 |
| P5 | MacLauncher 集成 + 设置页 MCP 区块 + 总审查 + 总 PR | platform-analyst | 待 P4 |

## 实施期验证点（实证事项）

- CLI `container build --label` 支持与否（P4 实证，规格已写成 label 优先、前缀兜底）
- stopping 状态上报时机（P1 实证）

## 候选与证据记录

（随阶段推进追加：候选 SHA、审查报告指针、验收命令与退出码、未关闭问题、下一动作）
