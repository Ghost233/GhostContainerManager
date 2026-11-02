# MCP 工具契约

MCP 协议只注册 `gcm_help` 与 `gcm_call`。业务名称、schema、风险注解和示例的唯一来源是 `lib/mcp/tool_catalog.dart`；处理函数由同一注册表绑定，调用前校验参数。帮助目录携带 catalogRevision，变化后重新获取。

| 领域 | 业务工具 |
|---|---|
| system | `system_status`, `system_start`, `system_stop` |
| container | `container_list`, `container_inspect`, `container_stats`, `container_create`, `container_start`, `container_stop`, `container_restart`, `container_kill`, `container_delete`, `container_exec` |
| image | `image_list`, `image_inspect`, `image_delete`, `image_pull` |
| mount | `mount_list`, `mount_inspect` |
| network | `network_list`, `network_get` |
| compose | `compose_list`, `compose_up`, `compose_down` |
| project | `project_list`, `project_get`, `project_init`, `project_build`, `project_test`, `project_reclaim`, `project_publish`, `project_restore`, `project_resource_record`, `project_cleanup_plan`, `project_cleanup_execute` |
| registry | `registry_status`, `registry_start`, `registry_stop` |

## Docker 行为

容器、镜像、网络、构建和编排使用标准 Docker CLI，沿用现有 context 和端点。Compose 使用标准 Docker Compose，项目与服务标签为 `com.docker.compose.project`、`com.docker.compose.service`。项目维护 Compose 固定运行参数；直接入口的实际参数须一致。

镜像接受 name:tag、name@sha256:digest 与镜像 ID。Dockerfile 大小不设固定上限。挂载聚合支持 bind、volume、tmpfs，卷由引擎管理，不能把远程引擎路径当宿主路径。

`system_status` 返回真实连接与版本信息；`system_start` 仅检查当前连接；`system_stop` 明确返回不支持通用引擎停止。引擎安装、启停和数据目录由外部管理。

`compose_up` 使用 `docker compose --file ... up --detach`，dry-run 是 Compose 全局参数；`compose_down` 使用标准 down，removeOrphans 删除孤立容器，不表示保留网络。默认不删除持久卷。

## 结果与资源保护

协议错误留在 JSON-RPC；业务失败返回 isError 和结构化 error（code/message/hint/source）。exec 和测试的非零退出保留为结果数据，超时和取消不计为通过。源数据与原始错误用于诊断，不把清理失败覆盖为业务成功。

每个项目登记资源身份、依赖和替代关系。`project_cleanup_plan` 不删除资源；`project_cleanup_execute` 只接受计划内明确批准的 ID，并重新核对身份、状态、引用和保留标记。运行中的旧容器不被强制停止。清单外资源、持久数据和依赖缓存不会因创建新资源被全局清理。

依赖镜像与缓存按输入复用，SDK 提前准备，最终组装和启动时不安装 SDK；临时测试数据留在容器内，先取回结果再清理。
