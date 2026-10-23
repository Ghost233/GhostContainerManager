# 项目方向

GhostContainerManager 是 Apple container 的 macOS 管理工具。桌面技术采用 Flutter；Swift 原生桥接的接口和实现留给后续开发任务确认。当前只有基础配置和发布工具。

## Orchard 参考

参考来源：[andrew-waters/orchard](https://github.com/andrew-waters/orchard)，查阅于 2026-10-23。

Orchard 是 Apple container 的原生管理界面。其主要管理路径通过 `ContainerAPIClient` 和 XPC 获取结构化数据；系统启停等部分操作使用 CLI。Compose 来自独立的 `andrew-waters/compose` 包。这些是参考项目的实现方式，本仓库尚未选择具体桥接接口。

## 本仓库的边界

- 运行时使用 Apple container；桌面界面、MacLauncher SDK 和原生桥接复用同一管理入口。
- 只有实际实现后，才声明启动、停止、状态和日志能力。连接启动器或 CLI 命令受理不等于容器已经就绪。
- 区分应用创建的资源与用户已有的容器、镜像、网络和挂载。应用退出、SDK 断连和业务资源回收分别定义。
- 本机编排使用 Apple container 原生命令及 `andrew-waters/compose`。Docker socket/API 依赖须单独适配。
- 本地持久化采用用户指定目录的绑定挂载。具体目录、权限和清理行为在功能任务中确定。

## 开发前待确认

首期功能、页面、容器及 Compose 的管理范围；Swift API 与 CLI 的分工；权限和系统要求；资源所有权；MacLauncher 服务粒度；退出与后台运行行为。

后续按确认的规格初始化 Flutter macOS 工程、实现功能并补充测试。Orchard 的功能列表和验收记录不构成本仓库的完成范围。
