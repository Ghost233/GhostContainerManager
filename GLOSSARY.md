# 术语表

Ghost Container Manager 的领域术语。只含领域概念，不含实现细节。

## 运行时

- **Apple container**：Apple 官方的容器工具链与运行时（github.com/apple/container），本仓库管理的唯一容器运行时。每个容器是一个轻量 VM。
- **Runtime 服务（container-apiserver）**：Apple container 的常驻守护进程，所有管理操作的最终执行者。

## 资源

- **Container（容器）**：由 Apple container 创建和运行的容器实例。
- **Image（镜像）**：容器镜像；可拉取、删除、检查，可由 Dockerfile 构建。
- **Mount（挂载）**：把宿主机目录绑定进容器的机制。Apple container **没有 volume 原语**，持久化一律使用 Mount；不要使用 "volume" 指代本项目的持久化概念。
- **Network（网络）**：容器网络，附带 DNS 域；容器有 IP 与 hostname。
- **Compose 项目**：由 compose 文件定义的一组容器，通过 orchard 作者的 compose 插件（andrew-waters/compose）执行 up/down 等生命周期操作。与「项目」是两个独立概念：Compose 项目来自 compose 文件，项目来自本产品的组合管理。
- **App 创建的资源**：由 GhostContainerManager 创建、带有应用标识 label 的资源；与用户已有的同名类型资源相区分，但默认可同等查看和管理。
- **项目（Project）**：本产品的组合管理单元——一组带 `com.ghost233.project=<name>` label 的镜像与容器，镜像按 `{前缀}-{自定义名}` 命名（如 `myapp-go1`）。项目内同名镜像唯一，同名构建默认替换（旧镜像变 dangling 由 GC 兜底）；「项目内唯一」是管理层约定，runtime 的镜像名是全局的。
- **项目前缀（prefix）**：`ghostcontainer.toml` 唯一的字段，声明「这个目录属于哪个项目」。不假定语言、不假定镜像数量、不解释名字含义。
- **ghostcontainer.toml**：项目根目录的可选配置文件，只存 `prefix` 一个字段。构建/测试参数（dockerfile、context、buildArgs、command）一律由调用方传入，不落配置文件。
- **项目工作流（Project workflow）**：围绕项目的标准操作链：构建镜像（`project_build`）→ 跑测试容器（`project_test`）→ 清理未被引用的镜像 → 推送本地 registry。构建/测试参数由调用方给出。
- **项目回收（Project reclaim）**：按项目粒度停止并删除成员容器、释放未被任何容器引用的项目镜像的组合操作。释放判定：凡未被任何容器引用的项目镜像都可释放，被本项目引用的保留，被项目外资源引用的跳过并在报告中列出；同项目操作在内存中维护引用快照、由操作触发重估，**事实以 CLI 查询结果为准**。与 MacLauncher 的 `recycle` 回调（语义=重启单个容器）无关，二者不要混用。
- **本地 registry**：由本应用一键起停的全局唯一本地镜像仓库容器，用于归档项目镜像以释放本地磁盘，并可从中拉回恢复。它是普通容器，无特殊管理地位。
- **归档（archive）**：把项目镜像推送到本地 registry 的动作；「归档并删除」= 推送后删除本地副本（可从 registry 拉回）。

## 产品

- **MCP-first**：产品的核心差异化定位——AI agent 是一等用户，通过内置 MCP server 获得与界面相同的管理能力。
- **内置 MCP server**：随应用运行、与界面共用同一管理入口的 MCP 服务，向 agent 暴露容器管理工具。
- **管理入口（Service layer）**：界面、内置 MCP server、MacLauncher SDK 复用的同一层容器管理能力。
- **MacLauncher**：本机启动器生态，应用按 SDK 规范向其注册已实现的服务。
