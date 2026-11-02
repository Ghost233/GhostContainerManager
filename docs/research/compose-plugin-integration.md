# Docker Compose 集成

使用标准 `docker compose`；不维护独立编排插件。Compose 文件保留标准语法和依赖关系，由 Compose 自身解析。

全局参数（file、project-name、dry-run 等）位于子命令之前；后台启动使用 up --detach。down 默认保留持久卷；remove-orphans 只用于已授权的孤立容器清理。项目和服务通过标准 com.docker.compose 标签识别。

参考：[Docker Compose CLI](https://docs.docker.com/reference/cli/docker/compose/)。
