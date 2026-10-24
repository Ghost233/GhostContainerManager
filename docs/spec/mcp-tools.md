# v1 MCP 工具清单决策简报

- 工单：GitHub issue #8（wayfinder 地图 #1 子工单）；#13 回填（project_*/registry_* 域、移除 container_logs）：2026-10-23
- 日期：2026-10-23
- 输入：docs/research/dart-mcp-server-options.md（#4，选型 mcp_dart ^2.4.3）、docs/research/bridge-flutter-apple-container.md（#7，XPC 主/CLI 补）、docs/research/apple-container-system-requirements.md（#11）、docs/research/compose-plugin-integration.md（#6）、docs/research/container-build-registry.md（#12）、docs/spec/project-workflow.md（#13）、GLOSSARY.md
- 已定前提：MCP = app 内置 server（mcp_dart ^2.4.3），与 UI 同进程共用 Service layer；传输 stdio + 仅 127.0.0.1 Streamable HTTP；**不设破坏性操作门控，但注解必须标全**；桥接 XPC 为主、CLI 补 system 启停与项目工作流的 build/push/测试容器；MCP 是策展封装层，底层通道对消费者不可见。
- **工具总数：35**（containers 10 / images 4 / system 3 / networks 2 / mounts 2 / compose 3 / project 8 / registry 3）。

---

## 1. 命名规范

- 形态：`<域>_<动词>`，全小写 snake_case。MCP 工具名约束为 `[a-zA-Z0-9_-]{1,64}`，**不允许点号**，故不采用 `container.list` 风格。
- 域前缀：`container_` / `image_` / `system_` / `network_` / `mount_` / `compose_` / `project_` / `registry_`。`mount_` 对齐 GLOSSARY（上游 volume 一律称 Mount），避免 agent 用 `volume_` 猜测而落空。
- 动词约定：`list`（集合）、`get`（单个详情）、`create`、`start`、`stop`、`restart`、`kill`、`delete`、`exec`、`stats`、`pull`、`inspect`、`up`、`down`、`init`、`build`、`test`、`reclaim`、`publish`、`restore`。注意：**不提供 `logs` 动词**——`container_logs` 已被 #13 决策移除（MCP 是策展封装层，日志查看留 UI；agent 侧由 `container_exec` / `project_test` 的 stdout/stderr 覆盖）。
- 资源标识参数统一命名 `id`，语义上接受容器 ID 或名称：服务端解析唯一性，歧义时返回错误并列出候选（见 §5 错误模型）。
- title 注解字段填人类可读名（如 "List containers"）；description 用英文（agent 面向，模型通用性最好；中文界面是 UI 层决策，不影响 agent 接口）。⚠️ 此点列入待拍板（Q4）。

## 2. 粒度决策（关键决策点 1）

**问题**：每操作一工具，还是一域一工具带 `action` 参数？

| 方案 | 优 | 劣 |
|---|---|---|
| A. 每操作一工具（`container_start`、`container_delete`…） | 注解可按操作粒度标（delete 标 destructive、list 标 readOnly）；schema 精确、参数校验强；agent 可发现性好 | 工具数多（v1 共 35 个） |
| B. 域工具 + action 枚举（`container(action:"delete")`） | 工具数少（6 个） | **注解只能取并集**——一个含 delete 的工具无法同时诚实地标 readOnly/destructive；inputSchema 变成 action 联合类型，校验弱；与"不设门控但注解标全"的既定决策冲突 |

**推荐 A**。注解粒度是用户决策（不设门控、注解标全）的直接推论：上层封装靠注解区分操作风险，action 合并会让 destructive 信息消失。35 个工具对现代 agent 是可管理规模。

## 3. 工具清单（v1 全量）

注解五字段：RO=readOnlyHint，D=destructiveHint，I=idempotentHint，OW=openWorldHint（所有工具都操作本机运行时，均标 `openWorldHint: true`；下表从略）。title 一律填英文短语，从略。

### 3.1 Containers（9）

| 工具 | 描述要点 | 关键参数（schema 要点） | RO | D | I | 输出结构 |
|---|---|---|---|---|---|---|
| `container_list` | 列出容器，含状态/镜像/标签/端口 | `all?: bool`（含已停止，默认 true）；`label?: string`（过滤，如 `com.compose.project=x`）；`status?: enum` | ✓ | | ✓ | `{containers: [{id, name, image, status, labels, createdAt, networks: [{name, ip, hostname]}]}` |
| `container_inspect` | 单容器详情（inspect） | `id: string`（ID 或名称） | ✓ | | ✓ | 完整容器对象（含 mounts、env、ports、resources、labels） |
| `container_create` | 创建容器（默认不启动；**镜像须为本地已有**，缺失报 NOT_FOUND 并提示先 `image_pull`，不自动拉取——2026-10-24 拍板） | `image: string`（必）；`name?`、`command?: string[]`、`env?: object`、`ports?: [{host, container, proto?}]`、`mounts?: [{source, target, readonly?}]`、`labels?: object`、`network?: string`、`start?: bool`（默认 false）；~~cpus/memoryBytes~~ 延 v2（T3 审查 P1 裁决） | | | ✗（具名重复创建返回 CONFLICT） | `{id, name, status, warnings}` |
| `container_start` | 启动容器 | `id` | | | ✓（已运行 = 幂等成功） | `{id, status, pid?}` |
| `container_stop` | 优雅停止（SIGTERM → 超时后 SIGKILL） | `id`；`timeoutSeconds?: int`（默认 5，对齐上游 system stop 的 5s 优雅期惯例） | | | ✓ | `{id, status, stoppedGracefully: bool}` |
| `container_restart` | 重启（= stop+start 编排） | `id`；`timeoutSeconds?` | | | ✓ | `{id, status}` |
| `container_kill` | 发送信号 | `id`；`signal?: string`（默认 "KILL"，支持 TERM/INT/HUP 等） | | ✓（KILL 语义） | ✓ | `{id, signal, status}` |
| `container_delete` | 删除容器 | `id`；`force?: bool`（默认 false，运行中拒绝并提示先 stop 或 force） | | ✓ | ✓ | `{id, deleted: true}` |
| `container_exec` | 容器内执行命令，一次性返回 | `id`；`command: string[]`（必）；`timeoutSeconds?: int`（默认 60，上限 600）；`workdir?`、`env?` | | | ✗ | `{exitCode, stdout, stderr, truncated: bool}`（单流上限 64 KiB，超出截断并标 `truncated`，见 §4） |

### 3.2 Images（4）

镜像引用统一由 Service layer 校验：禁止 digest 寻址并给出 `name:tag` hint；这属于 §5 的 schema 之外业务参数校验（`INVALID_ARGUMENT`），不是协议层 JSON-schema 错误。

| 工具 | 描述要点 | 关键参数 | RO | D | I | 输出结构 |
|---|---|---|---|---|---|---|
| `image_list` | 列出镜像 | 无 | ✓ | | ✓ | `{images: [{reference, digest, sizeBytes, createdAt}]}` |
| `image_pull` | 拉取镜像（长操作，进度见 §6） | `reference: string`（必）；`platform?: string` | | | ✓ | `{reference, digest, sizeBytes}` |
| `image_delete` | 删除镜像 | `reference: string`（必） | | ✓ | ✓ | `{reference, deleted: true}` |
| `image_inspect` | 镜像详情（OCI index/manifest 重建） | `reference` | ✓ | | ✓ | `{config: {env, entrypoint, cmd, exposedPorts, labels}, layers, sizeBytes, platforms}` |

### 3.3 System（3）

| 工具 | 描述要点 | 关键参数 | RO | D | I | 输出结构 |
|---|---|---|---|---|---|---|
| `system_status` | runtime 健康与版本（XPC ping + 版本/路径） | 无 | ✓ | | ✓ | `{status: "running"\|"stopped", apiServerVersion, cliVersion, versionSupported: bool, appRoot, installRoot}` |
| `system_start` | 启动 runtime（CLI；apiserver 未起时唯一通道） | `installKernel?: bool`（**必须显式**，默认 true → 映射 `--enable-kernel-install`；杜绝交互 readLine 卡死，见 #7 陷阱） | | | ✓ | `{status, kernelInstalled?: bool, startupMs}` |
| `system_stop` | 停止 runtime（会停所有容器，5s 优雅期） | `timeoutSeconds?: int`（默认 20，对齐上游最长等待） | | ✓（波及全部运行中容器） | ✓ | `{status, containersStopped: int}` |

### 3.4 Networks 只读（2）/ Mounts 只读（2）

| 工具 | 描述要点 | 关键参数 | RO | D | I | 输出结构 |
|---|---|---|---|---|---|---|
| `network_list` | 列出网络 | 无 | ✓ | | ✓ | `{networks: [{id, name, subnet?, isBuiltin}]}` |
| `network_get` | 网络详情 | `id` | ✓ | | ✓ | `{id, name, subnet, containers: [{id, ip, hostname}]}` |
| `mount_list` | 列出挂载（上游 volume） | 无 | ✓ | | ✓ | `{mounts: [{name, source?, sizeBytes?, usedBy: [containerId]}]}` |
| `mount_inspect` | 挂载详情 | `name` | ✓ | | ✓ | `{name, driver?, options, createdAt}` |

### 3.5 Compose（3）

| 工具 | 描述要点 | 关键参数 | RO | D | I | 输出结构 |
|---|---|---|---|---|---|---|
| `compose_up` | 起 compose 项目（长操作） | `file: string`（compose 文件绝对路径，必）；`projectName?`；`dryRun?: bool`；`forceRecreate?: bool`；`pull?: "missing"\|"always"\|"never"`（默认 `missing`） | | | ✓（二次 up 按哈希对账，天然幂等，见 #6） | `{exitCode, output, truncated}`（插件只有人类可读文本；保留尾部，见 §4） |
| `compose_down` | 停并删 compose 项目容器 | `file` 与 `projectName` 至少一项（可同给）；`keepNetworks?: bool` | | ✓ | ✓ | `{exitCode, output, truncated}`（插件原文透传） |
| `compose_list` | 列出 compose 项目（客户端按 `com.compose.project` label 聚合 container_list，插件无此子命令） | 无 | ✓ | | ✓ | `{projects: [{name, services: [{name, containerId, status}]}]}` |

### 3.6 Project（8）

项目工作流域，语义全文见 docs/spec/project-workflow.md（#13，v2 终轮拍板简化版）。MCP 是策展封装层：工具暴露的是工作流操作，底层 XPC/CLI 通道对消费者不可见。项目内镜像命名 `{prefix}-{自定义名}:latest`，同名构建默认替换；寻址一律 `name:tag`（schema pattern 强制，禁 digest）。项目定位参数：`project`（prefix）与 `path`（项目目录，经 toml 解析 prefix）二选一。

| 工具 | 描述要点 | 关键参数 | RO | D | I | 输出结构 |
|---|---|---|---|---|---|---|
| `project_list` | 列出项目（label `com.ghost233.project` 聚合 + toml 发现） | 无 | ✓ | | ✓ | `{projects: [{project, path?, images: [string], containers: int}]}` |
| `project_get` | 项目详情（成员镜像 + 成员容器 + 使用状态） | `project` 与 `path` 二选一 | ✓ | | ✓ | `{project, path?, images: [{reference, sizeBytes, createdAt, inUse}], containers: [...]}` |
| `project_init` | 在项目目录生成 ghostcontainer.toml（仅 prefix 单字段） | `path: string`（必）；`prefix?`（默认目录名，须匹配 `[a-z0-9][a-z0-9.-]{0,126}`） | | | ✗（toml 已存在 → CONFLICT） | `{path, prefix}` |
| `project_build` | 单步构建链：构建 `{prefix}-{name}:latest`（同名默认替换）→ 可选测试（长操作，progress 见 §6；失败落盘见 project-workflow.md §2.3） | `project` 与 `path` 二选一；`name: string`（镜像自定义名，必）；`dockerfile?`、`context?`、`buildArgs?: object`、`skipTests?: bool`（默认 false）、`noCache?: bool` | | | ✗（同名替换旧 tag，语义非幂等） | `{project, image, testsPassed?, exitCode?, durationMs}` |
| `project_test` | 对指定镜像跑测试容器（--rm 一次性，退出码透传；exitCode≠0 不算工具错误） | `project` 与 `path` 二选一；`name`（镜像自定义名，必）；`command: string[]`（必） | | | ✗ | `{project, image, exitCode, stdout, stderr, truncated, durationMs}` |
| `project_reclaim` | 项目回收：停删成员容器 + 释放未被任何容器引用的项目镜像。**默认 force，返回销毁清单**；外部引用跳过并列名 | `project` 与 `path` 二选一；`dryRun?: bool`（默认 false，只算不删） | | ✓ | ✓ | 回收报告（销毁清单 schema 见 project-workflow.md §4） |
| `project_publish` | 推送项目镜像到本地 registry（tag 成 loopback 引用后 push，长操作） | `project` 与 `path` 二选一；`name`（镜像自定义名，必）；`deleteLocal?: bool`（默认 false，推送后删本地镜像释放磁盘） | | | ✓ | `{project, pushed: [{source, target, sizeBytes}]}` |
| `project_restore` | 从本地 registry 拉回镜像并 tag 回项目规约名（按前缀归入项目） | `project` 与 `path` 二选一；`name`（镜像自定义名，必） | | | ✓ | `{project, restored: [{reference}]}` |

### 3.7 Registry（3）

本地 registry 最小形态的管理工具（单例 app 托管容器 `gcm-registry`，plain HTTP loopback，语义见 project-workflow.md §5）。域归属已定（终轮拍板 #7）：独立 `registry_` 域，不并入 `project_`。

| 工具 | 描述要点 | 关键参数 | RO | D | I | 输出结构 |
|---|---|---|---|---|---|---|
| `registry_status` | registry 容器与健康状态（GET /v2/ 探活） | 无 | ✓ | | ✓ | `{running: bool, port, containerId?, diskBytes?}` |
| `registry_start` | 一键启动（缺失时 create + 拉 registry:2，bind mount 持久化，幂等） | `port?: int`（默认 5056） | | | ✓ | `{running: true, port, containerId}` |
| `registry_stop` | 停止 registry（数据保留在 bind mount，不销毁） | 无 | | | ✓ | `{running: false}` |

**v1 明确不做**（迷雾/范围外，不暴露为工具）：container export/commit（commit 需 1.6.0，列入 v2 评估）、独立的 image build/push 工具（build/push 仅以策展形态经 `project_build`/`project_publish` 暴露）、network/mount 写操作、DNS 域管理（需 sudo）、builder 管理（CLI 自管）、Machines/K8s、**`container_logs`**（#13 决策：MCP 不提供日志工具，日志查看留 UI 面板；agent 经 `container_exec`/`project_test` 的输出获取信息）。

## 4. 输出 schema 策略（关键决策点 2）

**问题**：返回结构化 JSON（`structuredContent` + `outputSchema`）还是纯文本？

| 方案 | 优 | 劣 |
|---|---|---|
| A. 纯文本 content | 实现最简；所有 client 都能显示 | agent 需解析文本，脆弱（#7 已证 CLI 裸文本流不可取的同类教训） |
| B. 仅 structuredContent | 类型强、outputSchema 可校验（mcp_dart 内置 Draft 2020-12 校验器） | 旧 client 可能忽略 structuredContent |
| C. **双通道**：structuredContent 为权威 + content 放一行文本摘要 | 新 client 用结构、旧 client 有可读摘要；调试友好 | 每个工具写两份产出（可由统一封装生成，成本可控） |

**推荐 C**。mcp_dart 的 `registerTool` 原生支持 `outputSchema` 与结构化返回；文本摘要由 Service layer 的统一响应封装自动生成（如 "3 containers listed (2 running)"），工具作者只写结构化部分。

**有界性规则**（对齐 agent-experience 原则：bounded outputs + 检索路径）：

- `container_exec` 与 `project_test`：stdout/stderr 各上限 64 KiB，超出截断 + `truncated: true`。
- `compose_up` / `compose_down`：插件只输出人类可读文本，无法可靠重建 actions JSON；原文保留尾部 64 KiB，超出截断 + `truncated: true`。
- `project_build`：结果内嵌构建输出末尾 50 行（错误时）或不内嵌（成功时）；全程输出只经 progress notification 流式推送；**失败构建（含取消/中断）落盘日志尾部 1000 行、保留最近 20 条、成功不落盘**（详见 project-workflow.md §2.3）。
- `container_list`：v1 不分页（本机容器量级百以内）；若未来需要，加 `cursor` 而非页码。

## 5. 错误模型

**两层分离**：

1. **协议层错误**（JSON-RPC error）：仅用于参数 schema 校验失败（-32602 Invalid params，由 mcp_dart 内置校验器产生）与未知工具。业务错误一律**不走**协议层。
2. **工具层错误**（`CallToolResult.isError: true`）：所有业务失败统一为结构化错误：

```json
{
  "error": {
    "code": "NOT_FOUND",
    "message": "container 'web' not found",
    "hint": "use container_list to see available containers",
    "source": "xpc"
  }
}
```

**错误码枚举**（XPC/CLI/校验三路统一映射）：

| code | 含义 | 典型来源映射 |
|---|---|---|
| `RUNTIME_UNAVAILABLE` | apiserver 未运行 | XPC "connection invalid"/"xpc connection" 特征（orchard 同款）；hint 引导 `system_start` |
| `VERSION_MISMATCH` | 协议/版本不兼容（基线 1.6.0） | ping 解码失败 + "health check" 特征（orchard 的 isContainerVersionMismatch） |
| `NOT_FOUND` | 资源不存在 | XPC/CLI "no such container/image" 等 |
| `CONFLICT` | 状态冲突（运行中删除未 force、重名创建） | XPC 业务错误；`container_create` 重名 |
| `AMBIGUOUS_ID` | 名称匹配多个资源 | Service layer 解析；message 附候选列表 |
| `PERMISSION_DENIED` | 权限不足 | XPC "unauthorized request - uid mismatch"；v1 无 sudo 路径，hint 说明原因 |
| `INVALID_ARGUMENT` | 业务参数非法（schema 之外） | Service layer 校验 |
| `TIMEOUT` | exec/stop 等超时 | Service layer 计时 |
| `INTERNAL` | 未分类 | 兜底，message 保留原始错误文本（E02：I/O 边界先校验再成形） |

**幂等与重试语义**：`idempotentHint: true` 的工具（list/get/start/stop/restart/delete/pull/up/down 等）agent 可安全重试；`container_create`/`container_exec` 标 `idempotentHint: false`，重试前须先查状态。**不写门控，但注解必须诚实**——这是上层封装做风险控制的唯一信息源。

## 6. 长操作与流式（关键决策点 3）

**问题**：`image_pull`、`project_build`、`compose_up` 这类长操作如何暴露？

| 方案 | 优 | 劣 |
|---|---|---|
| A. 全部一次性返回（拉完/起完才返回） | 简单 | 大镜像 pull 数分钟无反馈；MCP client 超时风险 |
| B. progress notification + cancellation（mcp_dart `extra.sendProgress` / `extra.signal`） | agent 可见进度、可取消；SDK 原生支持 | 工具实现略复杂 |
| C. follow 类走 MCP resources/subscribe | 语义优雅 | resources 订阅生态支持参差；与 UI 的 EventChannel 模型不同构 |

**推荐 B + 有界默认**：

- `image_pull` / `project_build` / `project_publish` / `project_restore` / `system_start`（含内核下载）/ `registry_start`（首启拉 registry:2）：同步工具 + progress notification（百分比、已完成字节或构建阶段行），`extra.signal` 支持取消。`project_build` 的取消 = 杀 CLI 构建子进程（#12 §1.3）。
- `compose_up` 是 v1 的明确例外：compose 插件只提供人类可读文本，当前 CLI 桥接为同步有界返回，不提供虚假的阶段进度或本地等待取消；调用返回即进程已有终态。未来插件提供结构化流后再升级。
- **无 follow 型工具**：`container_logs` 已移除（#13），v1 不存在永不返回的 tool call；所有长操作都有明确终态。
- 进度节流：对齐 orchard 的 pull 进度折叠（~10Hz），Swift 桥接层 → Dart 的 EventChannel 推送与 MCP progress 共用同一节流点（见 #2 架构简报的状态同步模型）。

## 7. Resources / Prompts

**推荐 v1 都不做**。

- **Resources**：候选（`container://list` 等）只是把 list 工具换皮；生态对 resource 订阅支持不一，且我们的状态推送模型（EventChannel → UI + progress notification → MCP）已覆盖实时性需求。列入迷雾待 v2 重估。
- **Prompts**：没有明显的高频 prompt 模板需求；用户的上层封装（Q6 决策）更适合承载工作流编排。

server 的 `instructions` 字段（MCP 初始化握手）**要做**：一段简明英文说明（管理的是本机 Apple container runtime、资源标识规则、破坏性操作无门控的警示、v1 范围边界）——这是零成本的 agent 引导。

## 8. 决策记录与剩余问题

- **Q1 粒度**：**已定 A**：每操作一工具（v1 共 35 个），注解按操作粒度标注。
- **Q2 输出**：**已定 C**：双通道 structuredContent + 文本摘要。
- **Q3 长操作**：**已定 B**：progress notification + 有界默认；`container_logs` 已随 #13 决策移除，v1 无 follow 型工具。`compose_up` 的同步透传例外见 §6。
- **Q4 工具描述语言**：name/title 使用英文；description 在 v1 沿用中文（与默认中文 UI 一致，不影响 agent 调用），不再阻塞 v1。
- **Q5 `container_stats` 是否进 v1**：**已定：进 v1**，readOnly 单次快照；流式由 agent 轮询。容器域因此为 10 个工具（含 `container_kill` 与 `container_exec`），总数 35。
- **Q6 `compose_list` 的实现归属**：**已定：进 v1**，由 Service layer 按 label 聚合实现（插件无此命令）。
- **Q7 registry 工具域归属**：~~独立 `registry_` 域 vs 并入 `project_`~~ **已定（终轮拍板）**：独立 `registry_` 域。

## 9. GLOSSARY 新增术语建议

- **工具注解（Tool annotations）**：MCP 工具的五个语义提示字段（title/readOnlyHint/destructiveHint/idempotentHint/openWorldHint），是上层 agent 封装判断操作风险的唯一信息源；本项目不设门控，但注解必须诚实标全。
- **结构化结果（structuredContent）**：MCP tool 返回中的机器可读 JSON 主体，与 content 文本摘要并存；本项目以 structuredContent 为权威。
- **长操作**：执行时间可能超过常规请求周期的工具调用（pull/compose up/内核下载）。除 v1 明确列出的 compose 同步透传例外外，经 progress notification 报告进度、经 cancellation 取消。
- **错误码（MCP error code）**：工具层业务错误的稳定枚举（NOT_FOUND/CONFLICT/RUNTIME_UNAVAILABLE 等），agent 可据此编程化处理，message/hint 仅面向展示。
