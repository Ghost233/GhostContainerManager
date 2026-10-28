# 术语表

Ghost Container Manager 的领域术语。只含领域概念，不含实现细节。

## 运行时

- **Apple container**：Apple 官方的容器工具链与运行时（github.com/apple/container），本仓库管理的唯一容器运行时。每个容器是一个轻量 VM。
- **Runtime 服务（container-apiserver）**：Apple container 的常驻守护进程，所有管理操作的最终执行者。
- **运行时数据目录（app-root）**：Runtime 服务存放运行时数据的目录。

## 资源

- **Container（容器）**：由 Apple container 创建和运行的容器实例。
- **Image（镜像）**：容器镜像；可拉取、删除、检查，可由 Dockerfile 构建。
- **Mount（挂载）**：把宿主机目录绑定进容器的机制。Apple container **没有 volume 原语**，持久化一律使用 Mount；不要使用 "volume" 指代本项目的持久化概念。
- **Network（网络）**：容器网络，附带 DNS 域；容器有 IP 与 hostname。
- **Compose 项目**：由 compose 文件定义的一组容器，通过 orchard 作者的 compose 插件（andrew-waters/compose）执行 up/down 等生命周期操作。与「项目」是两个独立概念：Compose 项目来自 compose 文件，项目来自本产品的组合管理。
- **App 创建的资源**：由 GhostContainerManager 创建、带有应用标识 label 的资源；与用户已有的同名类型资源相区分，但默认可同等查看和管理。
- **项目（Project）**：本产品中用于记录和批量管理的具名登记概念，可以在没有资源时存在。项目不是资源访问的安全隔离边界；项目名与用于人工复查的目录都是登记字符串，不构成资源或目录归属约束。
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
- **业务工具**：MCP 服务对外提供的 35 项管理功能（system/container/image/mount/network/compose/project/registry 八个域），是产品能力的完整集合。
- **统一入口**：MCP 协议面只注册的两个工具——帮助入口（`gcm_help`）与调用入口（`gcm_call`）；业务工具不逐个出现在客户端的工具列表里，经统一入口可达。
- **工具注册表（Tool registry）**：35 项业务工具的唯一定义来源——名称、域、描述、参数约束（schema）、风险注解、示例与处理函数同处声明；帮助目录、分发、参数校验与测试全部从注册表读取，不允许第二份手工目录。
- **分发（dispatch）**：`gcm_call` 按工具名查注册表、先做参数校验、校验通过才调用处理函数的过程；校验失败时处理函数不得执行。
- **风险注解（annotations）**：工具的 readOnly / destructive / idempotent 三元风险表达。统一入口采用保守标记（可分发到删除类操作即视为 destructive）；注册表保留每个业务工具的准确注解。风险注解是提示，不是权限控制。
- **分页契约**：大列表工具（镜像列表、容器列表）的有界返回约定：`limit`（默认 50、上限 500）+ `offset`，响应携带总数、实际返回数量与是否还有后续数据，排序稳定。
