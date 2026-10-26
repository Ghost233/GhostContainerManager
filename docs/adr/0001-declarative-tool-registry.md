---
status: accepted
---

# MCP 业务工具收敛为声明式单一注册表

35 个业务工具的定义收敛为一份声明式注册表：每个工具的名称、域、title/description、inputSchema、outputSchema、风险注解、示例与 handler 在同一条目里声明；帮助目录（gcm_help）、分发（gcm_call）、参数校验与测试全部从注册表读取。

此前 schema 散在八个 `register*Tools` 函数里、目录散在 `tool_catalog.dart` 里，两处手工同步——精简注册模式上线当天就出现了目录 title 与真实 title 漂移（"Exec In Container" vs "Execute Container Command"）。双写注定漂移，而帮助、校验、分发任何一处读到过期数据都是对外契约错误。

## Considered Options

- **保留现状 + 只加校验层**：从 register 函数提取 schema 做校验，目录继续手工维护。省了重构，但留下两处真相，漂移问题不解决。
- **代码生成**：从注册表生成 register 函数。多一层构建复杂度，注册表本身已足够表达，不需要生成步骤。

## Consequences

- 这是一次触及全部 35 个工具注册代码的大重构，但 handler 逻辑不动，只是声明搬家。
- 单工具帮助（`gcm_help({tool})`）可以直接返回完整 inputSchema 与示例，无需第二份文档。
- 目录修订号（catalogRevision）取注册表内容的稳定哈希，目录不变则修订号不变。
