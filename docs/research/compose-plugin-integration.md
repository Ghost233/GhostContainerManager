# 调研：`andrew-waters/compose` 插件在本项目中的集成

- 调研工单：GitHub issue #6（wayfinder）
- 调研日期：2026-10-23
- 调研对象：[andrew-waters/compose](https://github.com/andrew-waters/compose)（main 分支，tree sha `3738f2d8`）与项目站 [compose.andon.dev](https://compose.andon.dev)
- 标注约定：**事实**＝一手来源（上游仓库源码 / README / 官方文档站 / apple/container 源码）直接写明；**推断**＝本文作者基于事实对本项目（Flutter + Apple container）的推导，需在设计任务中确认。

## 摘要

`andrew-waters/compose` 与 Orchard 同作者，是给 Apple container 补上 compose 编排的项目，分发为**三部分共用一套实现**：Swift 包（`ComposeModel` / `ComposeParser` / `ComposePlanner` 三个纯逻辑库）、`container compose` CLI 插件（薄封装二进制）、Orchard 的 Compose 标签页（直接链接 Swift 包）。它只提供 `up` / `down` 两个子命令，**没有 `diff` 子命令**；"diff" 语义由容器上的配置哈希在第二次 `up` 时实现。CLI 输出为纯人类可读文本，**没有 JSON 等结构化输出**。GUI 集成的设计意图是直接链接 Swift 包（Orchard 的做法），而不是 shell 调用插件。

来源：[compose README](https://github.com/andrew-waters/compose/blob/main/README.md)、[compose.andon.dev](https://compose.andon.dev)。

## 1. 分发形态与插件安装机制

### 分发形态（事实）

三部分共享一个实现（[README "How it fits together"](https://github.com/andrew-waters/compose#how-it-fits-together)）：

1. **Swift 包**：compose 模型、YAML 解析、依赖图和 planner（把 compose 文件 + 现状快照变成有序操作列表）。纯逻辑，无子进程、无 XPC、无守护进程依赖，可在无运行时的情况下测试。
2. **`container compose` CLI 插件**：包之上的薄二进制，装进 container 的插件目录，`container compose up` 成为真实 CLI 下的真实命令。
3. **Orchard 的 Compose 标签页**：Orchard 经 SwiftPM 链接该包，通过自己已有的 XPC 路径执行计划——GUI 不 shell 调用插件，也不要求插件已安装。

构建目标（[README "Building"](https://github.com/andrew-waters/compose#building)）：三个库 target `ComposeModel`（spec 类型 + 每个 compose key 的支持度表）、`ComposeParser`（YAML→模型，含插值、`.env`/`env_file`，每个错误带行号和列号）、`ComposePlanner`（依赖图、项目标识、哈希、planner）；一个可执行 target `compose` 即插件本体，是唯一知道运行时存在的 target，链接 `apple/container` 与 `swift-argument-parser`。库的唯一依赖是 Yams（与 `apple/container` 同源）。`build` 操作不在进程内执行，插件 shell 调用 `container build`。

### container 的插件机制（事实）

来自 [apple/container 源码](https://github.com/apple/container)：

- 插件是一个目录，内含配置文件和与目录同名的二进制（compose 的 [Makefile](https://github.com/andrew-waters/compose/blob/main/Makefile) 注释）：

  ```
  <install-root>/libexec/container-plugins/compose/config.toml
  <install-root>/libexec/container-plugins/compose/bin/compose
  ```

- 插件目录位置：`<installRoot>/libexec/container-plugins`，见 [`PluginLoader.userPluginsDir(installRoot:)`](https://github.com/apple/container/blob/main/Sources/ContainerPlugin/PluginLoader.swift)。`installRoot` 默认取 `container` 可执行文件的上两级目录（如 `/usr/local/bin/container` → `/usr/local`），可用环境变量 `CONTAINER_INSTALL_ROOT` 覆盖，见 [`InstallRoot`](https://github.com/apple/container/blob/main/Sources/ContainerPlugin/InstallRoot.swift)。
- CLI 启动时扫描插件目录，把 `isCLI` 类插件合并进 `container --help` 的 "OTHER SUBCOMMANDS" 段；CLI 按名字找到二进制后重置 SIGINT/SIGTERM 并 `execvp` 进去（compose [`Sources/compose/Compose.swift`](https://github.com/andrew-waters/compose/blob/main/Sources/compose/Compose.swift) 注释）。
- compose 的 `config.toml`（[`Sources/compose/config.toml`](https://github.com/andrew-waters/compose/blob/main/Sources/compose/config.toml)）只有 `abstract` / `author` / `version` 三行。

### 安装命令（事实）

插件目录是 root 所有的，因此安装需要 `sudo`：

- **从源码**（推荐，需要 Swift 6.2）：
  ```
  git clone https://github.com/andrew-waters/compose
  cd compose
  make build && sudo make install
  ```
- **从 release 预编译包**（tarball 即安装形态的插件目录；未公证，macOS 可能隔离）：
  ```
  tar -xzf compose-<version>-macos-arm64.tar.gz
  sudo mkdir -p /usr/local/libexec/container-plugins
  sudo cp -R compose /usr/local/libexec/container-plugins/
  ```
- **验证**：`container compose --help` 应打印 abstract 和两个子命令；CLI 看不到的插件会静默失败。

来源：[compose.andon.dev "Install it"](https://compose.andon.dev/#install)、[README "Using it"](https://github.com/andrew-waters/compose#using-it)。

### 版本要求（事实）

- Apple silicon Mac，macOS 26
- [apple/container](https://github.com/apple/container) **1.4.1 或更高**
- 构建需 Swift 6.2

来源：[README "Requirements"](https://github.com/andrew-waters/compose#requirements)、compose.andon.dev。

### 已知运维陷阱（事实）

- **升级 container 会清空插件目录**：container 安装器每次升级清空插件目录（[apple/container#1617](https://github.com/apple/container/issues/1617)），升级后需重新安装插件。
- 上游明确不接收 compose：compose PR [apple/container#239](https://github.com/apple/container/pull/239) 于 2026 年 4 月被维护者关闭，理由是 compose 应在项目外作为插件生态建设（[README "Why this exists"](https://github.com/andrew-waters/compose#why-this-exists)）。

## 2. 子命令与输出格式

### 子命令（事实）

**只有 `up` 和 `down`**，无 `diff`、`ps`、`logs`、`exec`、`stop`、`start` 等子命令（[README "Using it"](https://github.com/andrew-waters/compose#using-it)："There are no other verbs yet"；源码 `subcommands: [Up.self, Down.self]`）。"diff" 语义由第二次 `up` 的哈希对账承担（见第 3 节）。其余能力由 container 自带的 `ls` / `logs` / `exec` 覆盖。

两个命令的公共选项：`-f/--file`（指定 compose 文件）、`-p/--project-name`（项目名，默认取文件 `name`，再取目录名）、`--dry-run`（算出计划、打印、不做任何变更）。

`up` 独有：`--force-recreate`（无条件重建所有容器）、`--pull missing|always|never`、`--keep-orphans`（保留已从文件中消失的服务对应容器）。
`down` 独有：`--keep-networks`（保留本项目创建的网络）。

`down` 按 label 找容器，只从文件读服务名与停止顺序，因此 `up` 之后文件改过仍能完整 down 掉项目（`Compose.swift` 中 `Down.run()` 注释）。

### 依赖顺序（事实）

- 支持 `depends_on` 列表形式，planner 构建依赖图，**依赖先于被依赖者启动**。
- **不等待 ready**：`depends_on` 的 `service_healthy` 等条件形式不支持；运行时不具备健康上报（[apple/container#1502](https://github.com/apple/container/issues/1502)），`up` 只保证启动顺序，应用需自行重试首次连接。
- 端口与运行中容器冲突时，计划在创建任何东西之前即失败。

来源：compose.andon.dev 对比表、README "Scope"。

### 输出格式（事实 + 推断）

- **事实**：CLI 输出为纯人类可读文本，**没有 JSON 等结构化输出**。源码 [`Sources/compose/Output.swift`](https://github.com/andrew-waters/compose/blob/main/Sources/compose/Output.swift) 与 [`Compose.swift`](https://github.com/andrew-waters/compose/blob/main/Sources/compose/Compose.swift) 中无任何 `--format`/`--json` 选项；输出规则是"将要发生的事写到 stdout，阻止运行的事写到 stderr"，颜色仅在 tty 下启用，计划步骤按 `[n/total]` 编号逐行打印，错误带 compose 文件行号列号。
- **推断**：程序消费 CLI 输出只能解析面向人类的文本，脆弱且不是上游意图；需要结构化数据的调用方应链接 Swift 包（planner 返回的 `Plan` 是结构化类型），而不是解析 CLI 文本。

## 3. label 约定与二次 `up` 的 diff 行为

### label 约定（事实）

源码 [`Sources/ComposePlanner/ProjectIdentity.swift`](https://github.com/andrew-waters/compose/blob/main/Sources/ComposePlanner/ProjectIdentity.swift)。label 命名空间归 compose 项目而非创建工具，使所有前端读写同一组 key：

| label | 含义 |
| --- | --- |
| `com.compose.project` | 容器所属项目名 |
| `com.compose.service` | 容器对应的 compose 文件服务 key |
| `com.compose.hash` | 创建容器那一刻服务解析结果的 SHA-256 哈希 |

网络只打 `com.compose.project`（`networkLabels()`），使 `down` 能区分项目自建网络与已有网络。项目三个 label 在服务自定义 `labels:` **之后**写入，文件无法覆盖它们以躲避 `down`。

容器名：文件设了 `container_name` 则用之，否则为 `<project>-<service>`；无 `networks:` 的服务加入 `<project>_default` 网络。项目名归一化为小写、仅 `[a-z0-9_-]`、去除前导 `_`/`-`——与 Docker Compose 一致，保证一个工具建的项目能被另一个识别。

### 二次 `up` 的 diff 行为（事实）

- **无状态文件**：容器是唯一记录。创建时把哈希打上容器，第二次 `up` 时比对现状快照中每个容器上的 `com.compose.hash`。
- 哈希覆盖"会改变容器的一切"（`Service.canonicalDescription` 的 SHA-256）；不一致即 recreate（容器配置创建后不可改）。
- 第二次 `up` 对每个服务做出五种决策之一：create、start、leave alone（不动）、recreate、remove（orphan，除非 `--keep-orphans`）。
- 改动服务的 hooks 会在下一次 `up` 触发 recreate。
- hostname 不在服务哈希内：旧版本插件以裸名注册的容器，`up` 不会自动替换，需 `container compose up --force-recreate` 或 `down` 后 `up`（README "Scope"）。

来源：ProjectIdentity.swift、compose.andon.dev "Idempotent"、README。

## 4. compose 文件兼容性

来源：[compose.andon.dev 对比表](https://compose.andon.dev/#scope) 与 [README "Scope"](https://github.com/andrew-waters/compose#scope)（两者一致）。设计原则：每个 compose key 被分为 honoured / deferred / impossible 三档并带严重级别（`ComposeModel` 的支持度表）；无法兑现的行为性 key **拒绝整个文件**，报出 key、服务、行号列号，不创建任何东西；无害 key（如过时的 `version`）以 note 形式跳过。

### 支持（事实）

`image`、`build`（含 args/target/dockerfile；实际构建 shell 调用 `container build`）、`environment` / `env_file` / `.env`（含变量插值）、`command`、`working_dir`、`labels`、`container_name`、`ports`（短/长形式）、`volumes` 下的 **bind mount**、`deploy.resources`（cpus 向上取整——VM 不能有半个核）、`depends_on`（列表形式）、`dns` / `dns_search` / `dns_opt`、`post_start` / `pre_stop` hooks（在容器内以 hook 的 command/environment/working_dir/user 运行；`privileged: true` 拒绝；Orchard 不执行 hooks）、项目命名（`-f`、`-p`、`--dry-run`）。

### 读取但不兑现（partial，事实）

- `pull_policy`、`platform`：镜像缺失时拉取；该栈一切均为 linux/arm64。

### 尚未支持（not yet，事实）

`entrypoint`（create 接口只能覆盖 cmd）、**named volumes**（只有 bind mount）、单服务多网络（每容器一个 attachment）、`profiles`、`include`、`healthcheck`（容器无法上报健康）、`depends_on` 条件形式（等 ready 需运行时健康能力，[apple/container#1502](https://github.com/apple/container/issues/1502)）、`ps`/`logs`/`exec`/`stop`/`start` 子命令。

### 运行时不可能（拒绝文件，事实）

`restart`（无重启策略，[apple/container#2142](https://github.com/apple/container/issues/2142)）、`user`（create 接口无法设进程用户）、`cap_add`/`cap_drop`/`privileged`（无 capability、无特权模式）、`devices`/`tmpfs`/`ulimits`、`secrets`/`configs`、`extra_hosts`（创建时 hosts 文件不可写）、`network_mode`（仅用户自定义网络可挂接）。

### 已知限制（事实）

1. **不等 ready**：依赖只保证启动顺序，应用需自行重试首次连接。
2. **hostname 全局唯一**：服务以 `<project>-<service>` 可达而非 `db`（需 per-network 命名空间，[apple/container#1809](https://github.com/apple/container/issues/1809)）。名称需**限定（qualified）**才注册进 container DNS：带点 `container_name` 原样使用；其他名字在 `~/.config/container/config.toml` 设了 `[dns] domain` 后注册为 `<name>.<domain>`，未设则完全不可按名解析。域需先 `sudo container system dns create <domain>` 并重启 container。跨网络解析成功但连不通。
3. **升级 container 清空插件目录**（[apple/container#1617](https://github.com/apple/container/issues/1617)）。

## 5. Flutter 应用调用方式与插件检测

### 上游的设计意图（事实）

- 库 target 不含运行时客户端，"built to be embedded"：**GUI 应链接 Swift 包、经 XPC 直接执行计划，不 shell 调用插件，也不需要插件已安装**（compose.andon.dev "Built to be embedded"）。
- Orchard 即此模式的实现：经 SwiftPM 链接，走自己已有的 XPC 路径创建容器和网络；`build` 同样 shell 调用 `container build`（README）。
- CLI 无结构化输出（第 2 节），不适合程序化消费。

### 对本项目的建议（推断）

- **首选：在 Swift 原生桥接层链接 `ComposeModel`/`ComposeParser`/`ComposePlanner`**。本项目桌面端为 Flutter、运行时操作经原生桥接（docs/project-scope.md），与 Orchard 的"包 + XPC"模式同构：桥接层解析 compose 文件、调 planner 得结构化 `Plan`、经 container API 执行。好处：拿到结构化计划与逐 key 的严重级别（可在 UI 展示"将忽略什么"），不依赖插件安装状态，不受插件目录被升级清空影响。
- **次选/降级：shell 调用 `container compose up/down`**。仅适合做"接管用户已有 compose 工作流"的轻量入口；输出需解析人类可读文本，且要求用户机器装了插件并会在 container 升级后失效。
- 注意本项目 GLOSSARY 中"App 创建的资源"需打应用标识 label：compose 插件固定打 `com.compose.*` 三个 label（项目 label 写最后，compose 文件无法覆盖）；若走包内嵌路线，可在执行计划时为容器追加应用自有 label；若走 CLI 路线，则需事后补打或接受用 `com.compose.project` 识别项目。
- hooks 的 `$VAR` 插值发生在读文件的进程的 shell 环境（写 `$$VAR` 留给容器内变量）；包内嵌时注意这一环境来源差异。

### 插件检测方法（事实 + 推断）

- **事实**：CLI 看不到的插件会静默失败；官方验证命令是 `container compose --help`（成功打印 abstract 与 up/down 即已安装）。插件实体位于 `<container 安装根>/libexec/container-plugins/compose/`（含 `config.toml` 与 `bin/compose`），安装根默认由 `container` 二进制位置推导（默认 `/usr/local`），可被 `CONTAINER_INSTALL_ROOT` 覆盖。
- **推断**：检测可靠性排序——(1) 运行 `container compose --help` 并检查退出码与输出（最真实，覆盖 install root 被覆盖的情形）；(2) 检查默认插件目录是否存在 `compose/bin/compose`（快，但 install root 被覆盖时会误判）。因升级会清空插件目录，检测应在每次使用前做，而非安装时缓存结果。若采用包内嵌路线，则无需检测插件。

## 来源清单

- https://compose.andon.dev （项目站：对比表、安装、限制）
- https://github.com/andrew-waters/compose/blob/main/README.md （架构、scope、labels 之外的用法）
- https://github.com/andrew-waters/compose/blob/main/Sources/ComposePlanner/ProjectIdentity.swift （label 常量、哈希、项目名归一化）
- https://github.com/andrew-waters/compose/blob/main/Sources/compose/Compose.swift （子命令与选项全集）
- https://github.com/andrew-waters/compose/blob/main/Sources/compose/Output.swift （输出为纯文本，无 JSON）
- https://github.com/andrew-waters/compose/blob/main/Sources/compose/config.toml （插件配置）
- https://github.com/andrew-waters/compose/blob/main/Makefile （插件目录布局与安装）
- https://github.com/apple/container/blob/main/Sources/ContainerPlugin/PluginLoader.swift （插件目录 `libexec/container-plugins`、CLI 集成）
- https://github.com/apple/container/blob/main/Sources/ContainerPlugin/InstallRoot.swift （install root 推导与 `CONTAINER_INSTALL_ROOT`）
- 上游 issue：apple/container [#239](https://github.com/apple/container/pull/239)（compose 不进上游）、[#1502](https://github.com/apple/container/issues/1502)（健康上报）、[#1617](https://github.com/apple/container/issues/1617)（升级清插件目录）、[#1809](https://github.com/apple/container/issues/1809)（per-network 命名空间）、[#2142](https://github.com/apple/container/issues/2142)（重启策略）、[#1794](https://github.com/apple/container/issues/1794)（旧 defaults 设置被忽略）
