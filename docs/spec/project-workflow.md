# 项目工作流

项目由 `ghostcontainer.toml` 的 prefix 或显式项目名登记；Compose 项目是 Docker Compose 按标准标签识别的编排单元，两者可以关联但不混用。

## 构建与依赖

项目维护 Compose 文件与环境配置。先用 `docker compose config` 核验，再执行标准 Compose。直接 MCP/CLI 入口可保留，但实际参数应与配置一致。

工具链 → 项目依赖镜像 → 业务编译容器三层独立复用。Go 的依赖层保存 SDK/模块及匹配编译条件的 GOMODCACHE、GOCACHE。业务容器可复用或从相同依赖镜像重新创建；源码同步包含删除。依赖输入变化才重新准备，最终组装和启动不下载 SDK。

`project_build` 执行标准 `docker build` 并记录产物和验证结果，保留缓存；不限制 Dockerfile 为固定大小。`project_test` 以明确 command 运行一次性测试容器，保留真实退出码和有界输出；临时数据不挂载宿主机。

## 镜像与空间

镜像支持名称、tag、内容 ID 与 digest。Registry 推拉使用标准 `docker image push/pull`；HTTP/TLS 信任由当前 Docker 引擎配置决定，命令不带专用 scheme 参数。归档成功后才按授权删除本地引用。

空间来自 Docker 引擎：`docker system df` 与容器 `inspect --size`。共享层和持久卷不应被误计为单容器可回收空间。整项目回收与获批清理是不同入口；前者须明确确认其停止和删除影响。

## 9. 项目资源关系与确认后清理（2026-10-30）

新增流程与 §4 的整项目回收独立。创建新资源不自动停止或删除旧容器；清理必须先向 agent 返回计划，再接受具体候选 ID 的批准。

### 资源关系

- 每个项目持久记录资源 ID、类型、实际镜像摘要或容器创建时间、引用名、用途、任务、依赖关系、替代关系及保留要求。登记资料存于应用数据目录的 `project-resources/`，不扩充 `ghostcontainer.toml`。
- `project_build` 成功后登记镜像，并记录同名旧内容的替代关系；返回 `resourceTracking.resource` 和 `resourceTracking.cleanupPlan`。构建失败或附带测试失败时不登记成功替代。登记失败单列 warning，构建真实结果不变。
- 调用方使用 `project_resource_record` 补充业务用途、依赖、跨名称替代及容器关系。登记容器时自动保存实际镜像引用；运行时提供摘要且已有相应镜像记录时，自动关联依赖。登记是完整元数据更新，省略的布尔项恢复 false，关系数组恢复空；更新前可由 `project_get.resources` 读取已有记录。
- 历史资源只有显式登记才会进入此流程。无标签资源允许显式接管；存在冲突项目标签或其他项目登记时拒绝。依赖可跨项目，替代仅限本项目同类资源；自引用和循环拒绝。

### 计划与执行

1. `project_cleanup_plan` 返回 `planId`、过期时间、`requiresApproval=true`、候选和保留项。条目含用途、关系、身份与数据影响。只考虑已被有效新资源替代的旧资源，或结果已取回的临时资源。
2. agent 决定批准全部、部分或暂不清理。暂不清理无需调用执行工具；不能从超时推断同意。
3. `project_cleanup_execute(project, planId, approved)` 仅接受该计划的非空、不重复候选 ID。计划 30 分钟有效、一次性消费；新同项目计划替换旧计划，应用重启后需重新生成。
4. 执行前逐项重新查询资源身份、状态、项目归属和全局引用。运行中、停止中、状态不明、身份或登记内容变化的资源跳过；从不调用 stop/kill/force delete。
5. 镜像同时检查所有容器（含 stopped）、同摘要别名和跨项目登记依赖。容器未提供镜像摘要时，不能证明无引用，保守保留。明确要求保留或临时结果未取回时也保留。
6. 报告分为 `deleted`、`skipped`（含原因）和 `failed`，不把删除引用数量视为磁盘释放量。容器删除只影响可写层，不删除宿主挂载目录。

当前镜像删除入口仅支持 name:tag。同名构建后旧摘要已失去可核验的原引用，或只剩 dangling 内容时，记录为 `identityChanged` / `missingOrUntagged` 并保留；不使用已指向新内容的旧 tag 删除，也不绕过现有 digest 寻址限制。
