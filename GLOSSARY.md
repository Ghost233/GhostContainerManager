# 术语表

GhostContainerManager 的领域术语。只含领域概念，不含实现细节。

## 运行时

- **Apple container**：Apple 官方的容器工具链与运行时（github.com/apple/container），本仓库管理的唯一容器运行时。每个容器是一个轻量 VM。
- **Runtime 服务（container-apiserver）**：Apple container 的常驻守护进程，所有管理操作的最终执行者。

## 资源

- **Container（容器）**：由 Apple container 创建和运行的容器实例。
- **Image（镜像）**：容器镜像；可拉取、删除、检查，可由 Dockerfile 构建。
- **Mount（挂载）**：把宿主机目录绑定进容器的机制。Apple container **没有 volume 原语**，持久化一律使用 Mount；不要使用 "volume" 指代本项目的持久化概念。
- **Network（网络）**：容器网络，附带 DNS 域；容器有 IP 与 hostname。
- **Compose 项目**：由 compose 文件定义的一组容器，通过 orchard 作者的 compose 插件（andrew-waters/compose）执行 up/down 等生命周期操作。
- **App 创建的资源**：由 GhostContainerManager 创建、带有应用标识 label 的资源；与用户已有的同名类型资源相区分，但默认可同等查看和管理。

## 产品

- **MCP-first**：产品的核心差异化定位——AI agent 是一等用户，通过内置 MCP server 获得与界面相同的管理能力。
- **内置 MCP server**：随应用运行、与界面共用同一管理入口的 MCP 服务，向 agent 暴露容器管理工具。
- **管理入口（Service layer）**：界面、内置 MCP server、MacLauncher SDK 复用的同一层容器管理能力。
- **MacLauncher**：本机启动器生态，应用按 SDK 规范向其注册已实现的服务。
