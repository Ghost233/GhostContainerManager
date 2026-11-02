# Docker 后端架构

桌面 UI、MCP、MacLauncher → 服务层 → `ContainerBridge` → `DockerContainerBridge` → Docker CLI → 当前 Docker 兼容端点。

服务层统一处理校验、错误映射、同资源写操作串行化、项目登记和清理。`FakeContainerBridge` 用于单元测试；生产适配器位于 `lib/bridge/docker_container_bridge.dart`，使用独立 argv 启动进程，不拼接 shell 命令。

## 运行入口

| 功能 | 标准入口 |
|---|---|
| 连接与版本 | `docker version --format '{{json .}}'`、`docker info --format '{{json .}}'` |
| 容器列表与检查 | `docker container ls --all --quiet --no-trunc`、`docker container inspect` |
| 生命周期 | `docker container create/start/stop/rm/kill` |
| 执行、日志、统计 | `docker container exec/logs/stats` |
| 镜像 | `docker image ls/inspect/pull/rm/tag/push` |
| 构建 | `docker build`，沿用现有构建缓存 |
| 网络 | `docker network ls/inspect` |
| 编排 | `docker compose`，使用标准项目和服务标签 |
| 空间 | `docker system df`、`docker container inspect --size` |

CLI 继承当前 context、端点、TLS、凭据和代理配置。二进制从 PATH 及常见安装目录查找；自定义路径经存在性检查后复用。版本用于展示和诊断，不设固定品牌或大版本门槛。

## 数据与进程

Docker JSON 在桥接边界转换为现有服务模型，保留镜像 ID、创建时间、标签、挂载和网络。容器名用于界面操作，镜像内容 ID 与容器创建时间用于清理身份复核。Docker 原始检查数据保留在快照中。

进程分别读取 stdout/stderr；退出码等待两条管道排空后返回。长任务提供进度与取消；超时和取消不计为成功。终止客户端不代表服务端 exec 已停止，超时须保留容器标识供查询。日志取消订阅时停止对应客户端。

空间使用引擎报告的镜像大小和容器可写层大小，不读取宿主运行时存储。共享层可能重复，不能把各镜像显示值相加视为可回收磁盘。整体回收差值以引擎 df 快照为准。

清理规则见 [项目工作流](project-workflow.md)，工具定义见 [MCP 工具契约](mcp-tools.md)。
