---
status: accepted
---

# 统一入口 gcm_call 采用保守风险注解

`gcm_call` 的 `destructiveHint` 标为 `true`：它能分发到删除容器、删除镜像、停止运行时、项目回收等破坏性操作，只看外层注解的宿主必须按最坏情况处理。

`gcm_help` 目录保留每个业务工具准确的 readOnly/destructive/idempotent 注解，并对受参数影响的风险（`force`、`deleteLocal`、`dryRun`、`container_exec` 的命令内容）在描述中补充说明。

## Considered Options

- **保持 `destructiveHint:false`**：只读调用的审批体验最好，但宿主若只看外层注解，删除类调用会无提示通过——这正是触发本决策的外部审查发现。
- **按调用动态上报**：MCP 的工具注解是静态的，协议不支持按参数动态改变注解。

## Consequences

- 只读请求经 gcm_call 分发时，在严格执行注解的宿主里可能多一次确认；这是为不漏判删除类操作付的代价，需在目标宿主实测审批体验。
- 风险注解和帮助文字只是提示，不构成权限控制；授权边界依赖宿主的审批机制，必须写进交付说明。
