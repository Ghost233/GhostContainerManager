---
status: accepted
---

# 大列表分页契约（limit/offset）

`image_list` 与 `container_list` 采用有界返回：`limit`（默认 50、上限 500）与 `offset`（默认 0）两个参数，响应携带 `total`（总数）、`returned`（本页数量）、`hasMore`（是否还有后续数据）；排序稳定——镜像按 `repo:tag` 升序、容器按名称升序。默认值与上限写入 inputSchema（`default`/`maximum`）。

背景：工具定义体积经精简注册模式压缩约 95.7% 后，业务返回成为新的上下文大头（实测镜像列表 162 项）。完整配置不复制进列表项——列表给常用摘要字段，完整信息走已有的详情工具。stdout/stderr/日志的长度上限与截断标记沿用现有约定，长输出完整保留走日志文件机制。

## Considered Options

- **只加统计字段、默认仍全量返回**：不改行为，但大列表的上下文问题没有解决。
- **cursor 分页**：对本地即时查询没有收益（数据在内存、无并发写入漂移问题重要到需要游标），limit/offset 足够且更直观。

## Consequences

- 响应形状新增字段是对外行为变更，随 1.1.0 一并发布。
- `structuredContent` 保留完整结构化数据；文本 content 只放按结果形状生成的一行人类可读摘要（列表类「共 N 项，本页 M 项」），不再复制整份 JSON。
