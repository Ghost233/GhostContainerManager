# 容器生命周期

容器操作经 `ContainerService` 串行化后交给标准 Docker CLI。列表包含已停止容器；检查结果提供真实创建时间、镜像内容 ID、挂载、标签、命令和网络信息。

- 创建使用 `docker container create`；已声明项目应优先从 Compose 配置启动。
- 启动使用 `docker container start`，停止使用 `docker container stop --time N`，删除使用 `docker container rm`；仅明确要求强制删除时传 `--force`。
- 重启沿用服务层停止后启动的组合行为。kill 明确传递信号并重新检查状态。
- exec 使用独立 argv，无 TTY；stdout、stderr、退出码分别返回。超时报告真实失败并终止客户端，容器内进程是否结束需另行核实。
- 日志使用 `docker container logs --follow --timestamps`，取消订阅后终止客户端；统计使用 `docker container stats --no-stream`。
- 服务层活动状态与运行时状态分开。运行、暂停和重启中的容器均作为活动资源保留；原始 Docker 状态在快照中保留。

同资源写操作保持顺序；不同资源可独立操作。镜像删除同时核对引用名和内容身份，不能因换标签绕过使用保护。项目清理必须先生成计划并得到 agent 的明确范围确认，执行时重新核对身份、状态和依赖。
