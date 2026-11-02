# MCP 接入指南

Ghost Container Manager（GCM）内嵌一个 MCP server，把容器
运行时的管理能力暴露给外部 agent。本文档面向接入方：如何连接、如何发现
工具、如何调用，以及发布前的核对清单。

## 通道

| 通道 | 入口 | 说明 |
| --- | --- | --- |
| Streamable HTTP | `http://127.0.0.1:35731/mcp` | 应用启动后自动监听（设置中可关闭），仅回环地址 |
| stdio | `dart lib/mcp/stdio_proxy.dart --port 35731` | 换行分隔 JSON-RPC ↔ HTTP 的转发代理，供只支持 stdio 的宿主使用 |

应用设置中的 MCP 端口默认为 `35731`（`lib/features/settings/`），
stdio 代理用 `--port` 指向同一端口。代理本身无状态，可按需启停。

## 项目容器运行规则

当前执行约定统一使用 Docker 兼容接口与标准 `docker compose`，底层引擎由现有 context 或端点决定。项目 Compose 可使用标准 Docker Compose 能力，配置由标准 Compose 解析。先用 `docker compose config` 核验配置与目标端点。

GCM 后端统一使用 Docker CLI；`compose_up`、`compose_down` 调用标准 `docker compose`。连接设置沿用当前 context、DOCKER_HOST、TLS 和凭据。

项目工程中的容器应维护 Compose 文件及配套环境配置，固定镜像、命令、环境变量、端口、挂载、网络、运行用户、标签和资源限制。agent 操作前先读取配置；缺失时补齐，参数变化先更新配置，再执行并核验。

已声明服务优先使用 `compose_up`。`container_create`、`project_test` 和 CLI 直接运行仍可使用，但项目容器的实际运行参数应与配置一致。现有工具不会自动把 Compose 内容转换为这些工具的参数，调用方负责核对。日常源码编译和测试可通过 `container_exec` 在已有开发容器内执行。

依赖约束保持：复用匹配输入的工具链、依赖镜像和编译缓存，开发容器可复用或重建。SDK 与传递依赖提前下载、校验和准备，最终镜像组装及启动时不再安装。临时测试数据默认留在容器内，取回必要结果后随容器销毁；仅为必要持久化或输入输出交换挂载宿主目录。项目独立维护资源关系，清理先生成计划供 agent 确认，按确认范围执行；不为替代资源强制停止仍在运行的旧容器。

此规则通过 MCP 初始化 instructions 与相关工具帮助交付给 agent，不额外增加运行时禁止开关。

## 工具发现：gcm_help

server 采用精简注册：`tools/list` 只返回 `gcm_help` 与 `gcm_call` 两个
工具，全部 38 个业务工具经 `gcm_help` 发现、经 `gcm_call` 调用。`gcm_help`
支持三种模式：

**默认模式** `gcm_help({})` — 返回全部工具，按 8 个领域分组：

```json
{"usage": "...", "totalTools": 38, "domains": {
  "system":    ["system_status", "system_start", "system_stop"],
  "container": ["container_list", "container_inspect", "container_stats",
                "container_create", "container_start", "container_stop",
                "container_restart", "container_kill", "container_delete",
                "container_exec"],
  "image":     ["image_list", "image_inspect", "image_delete", "image_pull"],
  "mount":     ["mount_list", "mount_inspect"],
  "network":   ["network_list", "network_get"],
  "compose":   ["compose_list", "compose_up", "compose_down"],
  "project":   ["project_list", "project_get", "project_init", "project_build",
                "project_test", "project_reclaim", "project_publish",
                "project_restore", "project_resource_record",
                "project_cleanup_plan", "project_cleanup_execute"],
  "registry":  ["registry_status", "registry_start", "registry_stop"]}}
```

**领域模式** `gcm_help({"domain": "container"})` — 只返回该领域的工具
清单（上例返回 10 个容器工具）。合法域：system/container/image/mount/
network/compose/project/registry；未知域返回结构化中文错误
（`INVALID_ARGUMENT`，附合法域清单）。

**单工具模式** `gcm_help({"tool": "container_create"})` — 返回该工具的
完整定义：`{mode: "tool", catalogRevision, tool: {name, title, domain,
description, inputSchema, outputSchema, annotations, example, meta}}`。
其中 `example` 是一份必能通过该工具 inputSchema 校验的示例参数对象。
`domain` 与 `tool` 互斥，同传返回 `INVALID_ARGUMENT`；未知工具名返回
`NOT_FOUND` 并附全部合法工具名清单。

**catalogRevision**：三种模式的响应都带 `catalogRevision`（注册表内容
的规范化 SHA-256 哈希，前 12 位 hex）。目录不变则哈希不变——客户端可按
它缓存目录、变化时再刷新（server instructions 亦作此提示）。

## 工具调用：gcm_call

`gcm_call({"tool": "<工具名>", "arguments": {...}})` 分发到业务工具；分发
前对 `arguments` 做 JsonSchema 校验（mcp_dart 内建校验器），非法参数返回
结构化工具错误（`isError: true`，`error.code = "INVALID_ARGUMENT"`，中文
message 指明字段），handler 不会执行。注意 `gcm_call` 外层注解为
`destructiveHint: true`（保守：它可能分发到删除类工具）。

真实示例（验收快照）：

```jsonc
// gcm_call system_status
{"level": "ready", "ready": true, "cliVersion": "29.8.2",
 "apiServerVersion": "28.1.0", "versionSupported": true,
 "status": "running",
 "resources": {"containersRunning": 11, "containersTotal": 32,
               "images": 159}}

// gcm_call project_list {"limit": 3}
{"projects": [{"project": "coinhub", "images": [...], "containers": 0}, ...],
 "total": 9, "returned": 3, "hasMore": true, "nextOffset": 3}

// gcm_call image_list {"limit": 2, "offset": 2}
{"images": [...], "total": 159, "returned": 2, "hasMore": true,
 "nextOffset": 4}
```

列表类工具的分页信封见 ADR-0004：`limit`（默认 50，上限 500）、
`offset`；响应携带 `total` / `returned` / `hasMore` / `nextOffset`
（末页 `nextOffset` 为 `null`）。排序稳定：镜像按 `reference` 升序、
容器按 `name` 升序。

MCP 镜像与容器视图来自同一 Docker 端点，不对引擎基础设施按品牌额外过滤；数量核对需使用相同 context 与筛选条件。

## 握手探测 smoke

`scripts/mcp-handshake-smoke.sh [--port N]` 对运行中的 server 分别在
HTTP 与 stdio 通道各做一次真实 `initialize` 握手，断言：

- `serverInfo.version` 非空且不等于 `"0.0.0"`（防 release 构建丢失
  `GCM_APP_VERSION` 注入的回归，见 #32）；
- 响应含协议版本声明；
- `tools/list` 恰好为 `{gcm_help, gcm_call}`（防精简注册被意外展开）。

输出为结构化 `ACCEPT <通道> <检查项> PASS|FAIL <详情>` 行加一行
`RESULT smoke PASS|FAIL`；退出码 `0` 通过、`1` 失败、`2` 用法/环境错误。
dart 解析顺序：`GCM_DART` → PATH 上的 `dart` → `$GCM_FLUTTER_SDK` /
`$HOME/flutter` 的内置 dart-sdk。

同一目录下的 `scripts/mcp_acceptance.dart` 是 smoke 背后的完整验收客户
端，另有 `chain`（真实链路）、`concurrency`（并发一致性）、`pagination`
（大样本翻页 + CLI 对照）、`help-modes`（发现机制探测）子命令，均输出同
样格式的 `ACCEPT`/`RESULT` 行。

## 发布核对清单

发布出包（`scripts/build-release.sh` 会以 `--dart-define
GCM_APP_VERSION=<版本>` 注入版本号）后逐项核对：

1. 启动出包应用，运行 `scripts/mcp-handshake-smoke.sh`，退出码必须为
   `0`；`serverInfo.version` 应等于发布版本号而不是 `dev` 或 `0.0.0`。
2. `dart scripts/mcp_acceptance.dart chain` 双通道真实链路全绿。
3. `dart scripts/mcp_acceptance.dart concurrency` 与 `pagination`
   全绿（需要真实运行时上有若干容器/镜像）。
4. 在最小 macOS 26 虚拟机上安装 DMG 并重复 1–3（人工步骤，见 release
   流程文档）。
5. 若机器上装过旧版本：确认旧实例已退出，避免旧实例占用 35731 端口
   让探测打到旧 server（旧版本 `serverInfo.version` 为 `0.0.0`，正是
   smoke 要拦截的回归形态）。

## 项目清理的 agent 调用顺序

创建容器或使用历史资源后，用 `project_resource_record` 登记用途和关系；成功的 `project_build` 已登记镜像身份，调用方仍须补充依赖。通过 `project_get.resources` 获取资源 ID。修改记录时传入需要保留的完整元数据。

```jsonc
// 通过 gcm_call 登记一个已存在的临时容器，结果尚未取回时保持 false。
{"tool":"project_resource_record","arguments":{"project":"myapp","kind":"container","reference":"test-old","purpose":"test","temporary":true,"resultsCollected":true}}
// 获取计划，读取候选身份、关系、数据影响与保留原因。
{"tool":"project_cleanup_plan","arguments":{"project":"myapp"}}
// agent 确定可删除后，填入返回的计划 ID 和批准的候选 ID；只批部分也可以。
{"tool":"project_cleanup_execute","arguments":{"project":"myapp","planId":"<返回的 planId>","approved":["<候选资源 ID>"]}}
```

没有明确批准就不调用执行工具。计划 30 分钟有效且只能执行一次；新的同项目计划和应用重启会使旧计划失效。执行时状态或引用发生变化会跳过资源，报告不会自动重试或扩大范围。整项目 `project_reclaim` 仍会按既有参数停删资源，不用于此流程。
