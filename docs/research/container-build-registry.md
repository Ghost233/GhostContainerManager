# 调研：镜像构建、tag/push、本地 registry、清理与测试容器（apple/container + orchard）

> 一次性 research，服务于 GhostContainerManager「项目工作流」（拉基础镜像 → 构建 base 镜像 → 构建版本镜像 → 跑测试容器 → 自动清理 → 推送本地 registry）。
> 标注约定：【事实】附一手来源 URL；【推断】为基于事实的推论，未经实测验证。
> 调研时间：2026-10-23。源码基线：apple/container、apple/containerization、apple/container-builder-shim 的 `main` 分支；orchard（github.com/andrew-waters/orchard）默认分支。
> 相关前置调研：[bridge-flutter-apple-container.md](bridge-flutter-apple-container.md)（XPC/CLI 分工、镜像 XPC 服务、builder 生命周期）。

---

## 1. image build

### 1.1 `container build` 存在，走 BuildKit

【事实】apple/container 提供 `container build [options] [context-dir]`，基于 BuildKit。关键 flag（docs/command-reference.md）：

- `-t/--tag <name>`（可多次）、`-f/--file <path>`（缺省先找 Dockerfile 再找 Containerfile）、位置参数 context-dir（缺省 `.`）
- `--build-arg k=v`、`--no-cache`、`--target <stage>`、`-l/--label k=v`、`--secret`、`--ssh default`、`--pull`（强制拉新基础镜像）
- `-o/--output type=<oci|tar|local>`，默认 `oci`（构建结果导入本地镜像 store 并打 tag）
- `--progress auto|plain|tty`（默认 auto；`plain` 适合程序化逐行解析；**无 JSON 输出**）
- `-q/--quiet`（成功时只打印 digest）、`--platform/--arch/--os`
- `-c/--cpus`（默认 2）、`-m/--memory`（默认 2048MB）——注意这是 builder 容器的资源参数
- `--vsock-port`（builder shim vsock 端口，默认 8088）

来源：https://github.com/apple/container/blob/main/docs/command-reference.md

### 1.2 builder 不需要手动启动

【事实】`container build` 在构建前**无条件调用 `Builder.start(...)`**（Sources/ContainerCommands/Build/BuildOptions+LinuxBuild.swift 的 `runLinuxBuild()`）：若 builder 未运行则启动，若运行中但 SSH/资源配置不匹配则重启；dial 失败还有重试循环（再次 Builder.start + sleep 5s，总超时 300s）。官方文档明确：「When you first run `container build`, container starts a builder」（docs/resource-usage.md）。orchard 源码注释佐证：「The CLI owns the hard parts (starting or restarting the BuildKit builder, dialing it, unpacking the result), so Orchard shells out」。

来源：
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/Build/BuildOptions+LinuxBuild.swift
- https://github.com/apple/container/blob/main/docs/resource-usage.md
- https://github.com/andrew-waters/orchard/blob/main/Orchard/Services/ImageBuildService.swift

【事实】builder 管理子命令（CLI plugin，Sources/Plugins/ContainerBuilder/）：`container builder start [--cpus][--memory][--dns...]`、`builder status [--format json|table|yaml|toml]`、`builder stop`、`builder delete [--force]`。

【事实】BuildKit 的部署形态 = **容器化 BuildKit + Go shim**：builder 是一个名为 `buildkit` 的容器，镜像默认 `ghcr.io/apple/container-builder-shim/builder:<shim版本>`（config.toml `build.image`）；宿主 Swift 代码经 `ContainerClient().dial(id: "buildkit", port: 8088)`（vsock）连到 shim 的 gRPC 服务。shim 仓库：apple/container-builder-shim（Go，Apache-2.0，自述「Shim for connecting Swift host code to BuildKit running in a container」）。

来源：
- https://github.com/apple/container-builder-shim
- https://github.com/apple/container/blob/main/Sources/ContainerPersistence/ContainerSystemConfig.swift
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/Build/BuildOptions+LinuxBuild.swift

### 1.3 orchard 的 Builds 功能：纯 CLI 路径

【事实】orchard 的 Builds（Orchard/Services/ImageBuildService.swift）**shell out 到 `container` CLI**，命令形态：

```
container build --file <f> --tag <t> --arch <arm64|amd64> --progress plain \
  [--no-cache] [--build-arg k=v...] [--target s] <contextDir>
```

经内部 `CommandRunner.runStreaming` 逐行收 stdout 日志。没有走 XPC（XPC 面没有 build 路由，见 bridge-flutter-apple-container.md）。

来源：https://github.com/andrew-waters/orchard/blob/main/Orchard/Services/ImageBuildService.swift

【事实】构建历史：builder shim 的 gRPC 面只有 `info()` + build stream，**宿主侧没有可枚举的 BuildKit history**；orchard 因此自建持久化构建记录（BuildsPersistence.swift）：phase ∈ {building, succeeded, failed, cancelled, interrupted}，完成记录上限 20 条，transcript 上限 4000 行。取消 = Swift `Task.cancel()` 杀掉 CLI 子进程；App 退出时进行中构建标记为 `interrupted`（镜像可能仍已产出）。并发构建由 BuildKit 自己排队。

来源：https://github.com/andrew-waters/orchard/blob/main/Orchard/Services/BuildsPersistence.swift、Orchard/Services/ImageBuildService.swift

【事实】`container build` 的取消语义（源码级）：CLI 监听 SIGTERM/SIGINT/SIGUSR1/SIGUSR2（AsyncSignalHandler）→ 抛 `.interrupted` → `withThrowingTaskGroup` 的 defer 里 `group.cancelAll()`。**杀 CLI 进程即可取消构建**。

来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/Build/BuildOptions+LinuxBuild.swift

【推断】CLI 被杀后 BuildKit 侧的 solve 会随 gRPC 流断开而取消（BuildKit 标准行为）；构建残留仅可能留在 builder 层缓存中（见 §4 回收方式）。

【事实】已知限制：Dockerfile 超过 16KiB 会被拒（apple/container#735）。

来源：https://github.com/apple/container/issues/735

【事实】构建完成后的导入：默认 oci export → `ClientImage.load` → unpack → 对每个 tag 调 `image.tag(new:)`；export 临时目录在 `appRoot/Builder.builderResourceDir/<buildID>` 下。本地构建镜像带 annotation `com.apple.containerization.image.name`（用于优先本地解析，见 PR #2095）。

来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/Build/BuildOptions+LinuxBuild.swift、https://github.com/apple/container/pull/2095

---

## 2. tag / push

### 2.1 `container image tag`

【事实】存在：`container image tag <source> <target>`，无其他 flag；打新 tag 后**原引用保留**（同一镜像两个引用）。

来源：https://github.com/apple/container/blob/main/docs/command-reference.md

### 2.2 `container image push`

【事实】存在：`container image push [--scheme http|https] [--progress auto|none|ansi|plain|color] [--arch|--os|--platform] <reference>`。**没有 `--insecure` flag；plain HTTP 用 `--scheme http`**。`image pull` 参数同构。

来源：https://github.com/apple/container/blob/main/docs/command-reference.md

【事实】registry 认证：`container registry login [--scheme] [--password-stdin] [-u <user>] <server>`、logout、list（--format json）。凭证存 **macOS 登录 keychain**，securityDomain/keychainID = `com.apple.container.registry`（Sources/Services/ContainerAPIService/Client/Constants.swift）。

来源：https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/Constants.swift

【事实】push 进度可程序化获取：XPC 路径 `ClientImage.push(platform:scheme:auth:containerSystemConfig:progressUpdate:)` 带 `progressUpdate` 回调（与 pull 同构，本仓库此前调研已确认 pull 进度回调可用）。底层 `ImageStore.push/pull` 有 `insecure: Bool` 参数 = plain HTTP（apple/containerization）。

来源：
- https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/ClientImage.swift
- https://github.com/apple/containerization/blob/main/Sources/Containerization/Image/ImageStore/ImageStore.swift
- docs/research/bridge-flutter-apple-container.md

【事实】已知风险：keychain 凭证读取的 `-25308 errSecInteractionNotAllowed` 问题族（#1733/#1253/#816）——镜像操作在 XPC helper（container-core-images）里读 keychain 受 ACL 限制。开放 PR #1874 把凭证读取移到 CLI 进程再经 XPC 转发。main 分支上此问题仍可能影响「GUI（非 CLI 进程）经 XPC 向已登录 registry push」的场景。

来源：https://github.com/apple/container/pull/1874、https://github.com/apple/container/issues/1733

【推断】若 GhostContainerManager 走 XPC 直接 push 且目标 registry 需要认证，可能踩 keychain ACL 问题；规避手段：push 走 CLI（`container image push`，CLI 进程有 keychain 权限），或显式把 `auth` 传给 XPC 调用（取决于 XPC 请求是否支持转发 Authorization——#1874 尚未合并）。本地 plain-HTTP registry 若启用认证也需同样考量；无认证本地 registry 无此问题。

### 2.3 镜像引用解析陷阱（与 push/批量操作强相关）

【事实】`ClientImage._search` 本地查找只比对存储引用字符串与本地构建 annotation，**不比对 descriptor digest**；因此 `name:tag@sha256:digest` 形式会 miss 本地镜像并回退到 docker.io pull（401），裸 `sha256:<digest>` 会被解析成 `docker.io/library/sha256:<digest>`（apple/container#1962，open，1.1.0 复现）。

来源：https://github.com/apple/container/issues/1962

【推断】项目工作流中所有镜像寻址（run/create/delete/push/tag）**必须始终使用 `name:tag` 形式**，不要用 digest 形式；orchard 的 canonicalImageReference() 也踩过类似坑（本地 tag 被补全成 docker.io/library/ 后误 pull）。

---

## 3. 本地 registry（registry:2 容器化运行）

【事实】Docker Hub `library/registry:2` = distribution 2.8.3（Alpine 3.18 base），**多架构含 linux/arm64/v8**（digest `sha256:fa647fc1...`），`EXPOSE 5000/tcp`，`VOLUME /var/lib/registry`。

来源：https://hub.docker.com/v2/repositories/library/registry/tags/2/images（Docker Hub Registry API）

【事实】在 apple container 里跑 registry:2 **已被官方 member 的 issue 复现脚本实际演示**（apple/container#1538）：

```
container run --name issue-auth-registry --detach --publish 127.0.0.1:5056:5000 \
  --mount type=bind,source=<hostdir>,target=/auth,readonly \
  -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=... -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  registry:2
curl http://127.0.0.1:5056/v2/   # → Docker-Distribution-Api-Version: registry/2.0
```

端口发布语义：`-p/--publish [host-ip:]host-port:container-port[/protocol]`，发布到宿主 loopback，宿主 `curl 127.0.0.1:<port>` 可访问（docs/networking.md）。

来源：https://github.com/apple/container/issues/1538、https://github.com/apple/container/blob/main/docs/networking.md

【事实】持久化挂载可用两条路：`--mount type=bind,source=...,target=...`（bind mount 宿主目录）或命名卷 `-v <vol>:/var/lib/registry`（`container volume create`；`volume prune` 只删无容器引用的卷）。

【事实】plain-HTTP 访问：`container registry login --scheme http --password-stdin 127.0.0.1:5056`、`container image push --scheme http 127.0.0.1:5056/repo:tag` 均已验证可行（#1538 复现脚本使用）。**当前 main 分支没有 insecureRegistries 配置**（开放 PR #1768 提议 `[registry] insecureRegistries`，未合并）；HTTPS 自签名证书没有 skip-verify 手段（#731，open）。

来源：https://github.com/apple/container/pull/1768、https://github.com/apple/container/issues/731

【事实】已知小 bug：Basic-auth registry 密码错误时报「missing Bearer challenge in WWW-Authenticate header」误导性错误（#1538，open），不影响正确凭证的使用。

【推断】对「推送镜像到本地 registry 释放磁盘」的环节：registry:2 作为普通容器常驻（`--rm` 不适用，建议固定名字 + 固定端口 + 命名卷持久化），push 前 `tag` 成 `127.0.0.1:<port>/项目/镜像:tag` 再 `push --scheme http`；无认证即可用，若加 htpasswd 认证注意上述 XPC keychain 风险（§2.2）。宿主到容器的访问走 loopback，无需 `.test` DNS。

---

## 4. 清理与磁盘

### 4.1 `container image delete`（别名 rm）

【事实】`container image delete [--all] [--force] [images...]`。语义（Sources/ContainerCommands/Image/ImageDelete.swift）：

- 逐个 `ClientImage.delete(reference:, garbageCollect: false)`，**最后统一 `ClientImage.cleanUpOrphanedBlobs()` 并输出「Reclaimed X in disk space」→ 磁盘空间在 delete 命令内同步回收**（非异步 GC）。
- 「Images currently referenced by running containers cannot be deleted without first removing those containers」（command-reference）；`--force` **只忽略 not-found 错误**，不能强删被引用镜像。
- `--all` 与 list 都会跳过 infra 镜像（builder 镜像、vminit 镜像，Utility.isInfraImage）。

来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/Image/ImageDelete.swift、https://github.com/apple/container/blob/main/docs/command-reference.md

### 4.2 `container image prune`

【事实】存在。默认只删 **dangling（无 tag 引用）** 镜像；`-a/--all` 删除「reference 不在任何容器 `configuration.image.reference` 集合中」的镜像（**按引用字符串匹配，非按 digest**）。删除后统一 `cleanUpOrphanedBlobs()`，逐行输出 untagged/deleted。

来源：https://github.com/apple/container/blob/main/Sources/ContainerCommands/Image/ImagePrune.swift

### 4.3 多 tag 指向同一 digest 的删除行为

【事实】ImageStore（apple/containerization）：`delete(reference:, performCleanup: false)` 只删 reference → index 的映射；`cleanUpOrphanedBlobs()` 收集所有剩余镜像的 `referencedDigests()`，再 `contentStore.delete(keeping:)` 删除未被引用的 blobs。**因此删一个 tag 不释放任何内容；同一 digest 的最后一个引用被删掉 + GC 跑过之后才释放磁盘**。

来源：https://github.com/apple/containerization/blob/main/Sources/Containerization/Image/ImageStore/ImageStore.swift

### 4.4 磁盘占用与存储位置

【事实】`container system df [--format json|table|yaml|toml]`：报告镜像/容器/卷各自的 total、active、size、reclaimable。

【事实】默认数据根目录 appRoot = `~/Library/Application Support/com.apple.container`（Sources/ContainerPersistence/PathUtils.swift，`BaseConfigPath.appRoot`）；可用环境变量 `CONTAINER_APP_ROOT` 或 `container system start --app-root <path>` 覆盖。配置目录 = `~/.config/container`（XDG_CONFIG_HOME 覆盖），内含 config.toml。

来源：https://github.com/apple/container/blob/main/Sources/ContainerPersistence/PathUtils.swift

【事实】其他回收路径（docs/resource-usage.md）：builder 层缓存回收 = `container builder stop` + `container builder delete`；`container prune` 删已停止容器并报告释放空间；容器可写层是 macOS sparse disk image，**容器内删文件不自动缩容**。

来源：https://github.com/apple/container/blob/main/docs/resource-usage.md

【推断】项目工作流的「自动清理」闭环可做成分级：① `container prune`（停掉的测试容器）→ ② `image delete <旧版本 tag>`（同步回收，前提是 digest 不被其他 tag/容器引用）→ ③ `image prune`（dangling）→ ④ 需要时 `builder stop && builder delete`（回收构建缓存，代价是下次构建全量）。`system df --format json` 可做清理前后对比与 GUI 展示。

---

## 5. 项目级批量操作的支撑

### 5.1 label 过滤

【事实】**CLI 层**：`container list` 与 `container image list` 均**无 --filter/--label 过滤 flag**；两者都有 `--format json|table|yaml|toml`（`image list` 另有 `--quiet`/`--verbose`）。

【事实】**XPC 层容器列表支持 label 过滤**：`ContainerClient.list(filters: ContainerListFilters)`，`ContainerListFilters` 含 ids/status/labels 三轴，**label 值按正则匹配**（Sources/ContainerResource/Container/ContainerListFilters.swift）。

【事实】JSON 字段：`container list --format json` 输出 `[ContainerSnapshot]`，`configuration.labels: [String: String]` 在列（另含 image/networks/status/startedDate）。`container image list --format json` 输出 `[ImageResource]`（Codable keys：id/configuration/variants），镜像 label 不在顶层，需从 `variants[].config`（完整 OCI Image 对象）的 `config.labels` 解析；`ImageResource.labels` 属性实际取 descriptor.annotations。

来源：
- https://github.com/apple/container/blob/main/Sources/ContainerResource/Container/ContainerListFilters.swift
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerList.swift（经 ContainerSnapshot）
- https://github.com/apple/container/blob/main/docs/command-reference.md

【推断】「按 label 过滤项目资源」的分工：容器用 XPC（原生支持、正则可配）；镜像只能 `image list --format json` 全量拉取后客户端自行按 name 前缀/label 过滤（无服务端过滤，量小可接受）。

### 5.2 按名字模式批量删

【事实】`container image delete [images...]` 与 `container delete [container-ids...]` 都接受**多个位置参数**，一次调用批量删。

【推断】名字模式（如 `项目名:*`）匹配须客户端自己做：list JSON → 正则/glob 匹配 → 组装多参数 delete。注意 §2.3 陷阱：匹配/引用一律用 `name:tag` 字符串。

### 5.3 多 tag 同 digest

见 §4.3：删单 tag 只删映射，内容在最后引用删除 + `cleanUpOrphanedBlobs` 后释放；CLI 的 delete/prune 都已内置统一 GC 调用。【推断】「构建版本镜像 → 推送后删本地」若 base 镜像与版本镜像共享层，删版本 tag 只释放独占层，符合预期。

---

## 6. 测试容器场景

【事实】`container run` 与 `container create` 均有 `--rm/--remove`：run 侧实现为 `ContainerCreateOptions(autoRemove: managementFlags.remove)`（Sources/ContainerCommands/Container/ContainerRun.swift）——**停止后自动删除容器，等价于 Docker 的 --rm**。

【事实】**退出码透传（CLI 层两条路径都成立）**：

- `container run`（非 -d）：`exitCode = try await io.handleProcess(process:log:)`，结束 `throw ArgumentParser.ExitCode(exitCode)` → **CLI 退出码 = 容器 init 进程退出码**；错误路径兜底 127 并 `client.delete(id:)` 清理（ContainerRun.swift）。
- `container exec`（非 TTY，`-t` 可选）：同样 `throw ArgumentParser.ExitCode(exitCode)` → **CLI 退出码 = exec 命令退出码**，失败默认 127（Sources/ContainerCommands/Container/ContainerExec.swift）。
- 非 TTY 下收到 3 次 SIGINT/SIGTERM 会强制 `Darwin.exit(1)`（SignalThreshold）。

来源：
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerRun.swift
- https://github.com/apple/container/blob/main/Sources/ContainerCommands/Container/ContainerExec.swift

【事实】run/create 均支持 `-l/--label key=value`（多值）、`-v/--volume`、`--mount type=bind,...`、`-p/--publish`、`-e` 环境变量、`-w/--workdir`（Process/Management/Resource flag 组）。`container exec` 支持 `-d/--detach`、`-e`、`-w`、`--user`。

来源：https://github.com/apple/container/blob/main/docs/command-reference.md

【推断】测试容器两种可行模式：①一次性容器：`container run --rm --name <唯一名> -l gcm.project=<p> -l gcm.role=test <镜像:tag> <测试命令>`，读 CLI 退出码即测试结果，容器自动清理；②常驻容器 + `container exec <id> <命令>` 多次取退出码。日志：非 TTY 模式 stdout/stderr 直通 CLI 可捕获；XPC 路径 `ContainerClient.createProcess/logs` 存在但退出码语义需另行验证（建议测试容器一律走 CLI）。

---

## 7. 对项目工作流的影响

### 7.1 各环节支持度

| 环节 | 支持度 | 依据 |
|---|---|---|
| 拉基础镜像 | ✅ XPC 主路径成熟 | ClientImage.pull 带进度回调（既有调研） |
| 构建 base/版本镜像 | ✅ 仅 CLI 路径 | XPC 无 build 路由；`container build` 自动管 builder；orchard 同款做法可直接借鉴 |
| 构建进度/日志 | ⚠️ 半结构化 | 仅 `--progress plain` 文本流，无 JSON；orchard 的逐行解析 + 自建历史（上限 20 条/4000 行）是现成的产品化范式 |
| 构建取消 | ✅ | 杀 CLI 进程即取消；需自标 cancelled/interrupted（无服务端历史可查） |
| tag | ✅ | `image tag` 简单可靠；多 tag 同 digest 语义清晰（§4.3） |
| push 本地 registry | ✅ CLI；⚠️ XPC | CLI `--scheme http` 可用；XPC push 有进度回调但认证场景可能踩 keychain ACL（#1874 未合并）；本地无认证 registry 不受影响 |
| 本地 registry | ✅ 可行 | registry:2 有 arm64；#1538 实证可跑；loopback 发布 + 命名卷持久化 |
| 清理镜像/容器 | ✅ | delete 同步回收 + `Reclaimed` 输出；prune 分 dangling/全部两级；`container prune` 清停止容器 |
| 磁盘观测 | ✅ | `system df --format json`；存储根 ~/Library/Application Support/com.apple.container |
| 项目级 label 过滤 | ⚠️ 容器✅/镜像❌ | 容器 XPC 支持 label 正则过滤；镜像只能客户端过滤 JSON 全量 |
| 测试容器 | ✅ | `run --rm` + 退出码透传；exec 非 TTY + 退出码透传 |

### 7.2 建议的 XPC vs CLI 分工

1. **构建（build）走 CLI**：XPC 无 build 路由，CLI 自带 builder 生命周期管理（无需 GUI 管 builder start/stop），`--progress plain` 逐行解析进 GUI；取消 = 杀子进程；构建历史自建持久化（参考 orchard BuildsPersistence，上限/截断策略自定）。**Dockerfile 需控制在 16KiB 以内**（#735）。
2. **镜像 list/inspect/pull/delete 走 XPC**（既有调研已验证，进度回调可用）；**push 一律走 CLI**（`container image push --scheme http`，规避 XPC helper 的 keychain ACL 风险族 #1733/#1253/#816/#1874）。
3. **容器 list（含 label 过滤）/create/start/stop/delete 走 XPC**；**测试容器的一次性执行与 exec 走 CLI** 以拿到可靠退出码（XPC createProcess 退出码语义未验证）。
4. **批量操作客户端编排**：镜像无服务端过滤，`image list --format json` 后客户端按项目前缀匹配 `name:tag` 组装多参数 `image delete`；容器可直接用 XPC `ContainerListFilters.labels` 正则。
5. **引用一律 `name:tag`**：不用 digest 形式寻址（#1962）；本地 tag 不做 docker.io 补全（orchard 教训）。
6. **本地 registry 作为常驻容器管理**：固定名（如 `gcm-registry`）+ 固定 loopback 端口 + 命名卷挂 `/var/lib/registry`；推前 `image tag` 为 `127.0.0.1:<port>/...`；状态检查用 `curl http://127.0.0.1:<port>/v2/`。
7. **清理闭环分级**：`container prune` → `image delete <旧 tag>` → `image prune` →（需要时）`builder stop && builder delete`；用 `system df --format json` 做前后对比展示「释放磁盘」效果。
8. **关注未合并 PR 作为未来改进**：#1768（insecureRegistries 配置）、#1874（keychain 读取移入 CLI）、#2095（本地镜像 annotation 优先级修正）——合并后可简化上述规避逻辑。

### 7.3 主要阻碍与缺口

- 构建**无 JSON 进度、无服务端构建历史** → GUI 需自建解析与持久化（orchard 已示范可行）。
- 镜像列表**无 label 过滤、label 不在 JSON 顶层** → 项目级镜像管理依赖命名约定（建议统一 `gcm-<project>-<role>:<version>` 前缀）+ 客户端过滤。
- HTTPS 自签名 registry **无 skip-verify**（#731）→ 本地 registry 只能 plain HTTP（loopback 场景可接受）。
- Dockerfile 16KiB 上限（#735）→ 大 Dockerfile 项目需留意。
