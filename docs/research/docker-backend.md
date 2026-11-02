# Docker 后端实现依据

生产适配器使用 Dart Process 启动标准 Docker CLI，独立 argv 避免 shell 插值；JSON 归一化到服务层模型。引擎与宿主之间通过 Docker 端点通信，不依赖平台专用客户端库或宿主存储布局。

容器、镜像、网络和 Compose 入口见 [架构](../spec/architecture.md)。输出、取消、身份与引用校验由测试和真实端点验证覆盖。

参考：[容器 inspect](https://docs.docker.com/reference/cli/docker/container/inspect/)、[镜像 inspect](https://docs.docker.com/reference/cli/docker/image/inspect/)。
