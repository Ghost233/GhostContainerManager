# Docker 构建与 Registry

构建使用标准 docker build，保留 BuildKit 缓存。工具链和项目依赖镜像可由 Registry、归档或持久构建缓存跨构建器复用；指纹包含工具链、目标平台、清单、锁文件、本地引用与编译模式。

SDK 在依赖准备阶段下载、校验和编译，业务编译使用准备结果。最终镜像组装和启动不安装 SDK。推拉使用 docker image push/pull；HTTP/TLS 信任在 Docker 引擎中配置，不增加专用 CLI scheme 参数。

参考：[Docker build](https://docs.docker.com/reference/cli/docker/buildx/build/)、[Registry](https://docs.docker.com/registry/)。
