---
status: accepted
---

# 分发前 schema 校验与 INVALID_ARGUMENT 错误分类

`gcm_call` 分发到业务工具 handler 之前，必须用注册表里的 inputSchema 校验业务参数；校验失败时 handler 不得执行，统一返回 `INVALID_ARGUMENT` 业务错误（中文 message + hint）。

背景：精简注册模式后，业务工具不再直接注册到 MCP server，SDK 对注册工具自动执行的 inputSchema 校验随之失效——`container_inspect` 传 `{}` 落到 `INTERNAL`、`container_list` 传字符串类型的 `all` 被静默接受、额外字段被忽略。`gcm_call` 自己的 schema 只约束 `{tool, arguments}` 外层形状，代替不了目标工具的参数校验。

校验器复用 mcp_dart 2.4.3 公开导出的内建 JSON Schema 校验器（draft 2020-12/draft-7，`JsonSchemaValidation.validate`），不新增第三方依赖；我们的 schema 本来就用它的 `JsonObject` DSL 声明，语义与 SDK 对直接注册工具的校验完全一致。业务特有限制（非空命令、绝对路径、端口范围、project/path 选择规则）放在紧邻的业务校验里，不塞进 schema。

错误分类：参数无效 `INVALID_ARGUMENT`、资源不存在 `NOT_FOUND`、状态冲突 `CONFLICT`、未预期故障才用 `INTERNAL`。容器命令与测试命令的非零退出码不是错误，继续作为执行结果返回（保留 stdout/stderr/退出码）。

## Considered Options

- **引入 json_schema 等第三方校验包**：功能等价，但新增依赖且错误消息要二次加工；SDK 内建校验器已满足「不自研」的意图。
- **每个工具手写 if 校验**：最直接但 35 份重复代码，且与 schema 声明又成双写。

## Consequences

- 这是对外的行为变更：此前被静默接受的错误参数（错类型、额外字段）现在被拒绝。经决策直接生效、不留宽松开关，随 1.1.0 发布并在交付说明写明。
