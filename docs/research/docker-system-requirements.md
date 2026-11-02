# Docker 运行要求

应用：macOS 26、arm64、固定项目 Flutter SDK。容器端点：提供 Docker 兼容接口，由标准 Docker CLI 访问；不要求特定引擎产品。编排需要标准 Docker Compose。

检查 `docker version`、`docker info` 和 `docker compose version`。上下文、DOCKER_HOST、TLS、代理和凭据沿用用户现有配置。引擎启动、安装和存储配置在引擎自身入口完成。

参考：[Docker CLI](https://docs.docker.com/reference/cli/docker/)、[Docker contexts](https://docs.docker.com/engine/manage-resources/contexts/)。
