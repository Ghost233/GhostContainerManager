# 项目工作流规格（Project workflow + 本地 registry）

- 工单：GitHub issue #13（wayfinder 地图 #1 子工单）；MCP 工具域回填见 docs/spec/mcp-tools.md §3.6/§3.7
- 日期：2026-10-23
- 输入：docs/research/container-build-registry.md（#12）、docs/spec/container-lifecycle.md（#3）、docs/spec/architecture.md（#2）、docs/spec/mcp-tools.md（#8）、GLOSSARY.md
- 决策状态：全部拍定（issue #13「已定决策」+ 地图 #1）。本文不再提问；真正分叉的实现选择集中在文末「遗留问题」。

---

## 1. 项目模型

**项目（Project）** = 三元约定，无任何上游新资源类型：

1. **Label 约定**：一切项目成员资源（容器、镜像）打 `com.ghost233.project=<name>` label。容器另可加 `com.ghost233.role=test` 标记测试容器。项目发现 = 按该 label 聚合（容器走 XPC `ContainerListFilters.labels` 正则；镜像无服务端过滤，`image list --format json` 全量拉取后客户端过滤，量小可接受——#12 §5.1）。
2. **镜像命名规约**：
   - base 镜像：名 `{lang}-{project}-base`
   - 版本镜像：名 `{lang}-{project}-v{n}`，`n` 从 1 递增，取号 = 现有最大版本号 + 1（在 per-project 锁内完成，见 §6）
   - **一切寻址必须 `name:tag` 形式**（#12 §2.3：digest 寻址会被误解析为 docker.io 并回退 pull，上游 bug #1962 未修）。规约中的名字统一配 `:latest` tag，即完整引用为 `{lang}-{project}-base:latest` / `{lang}-{project}-v{n}:latest`。客户端禁止 docker.io/library 补全（orchard 教训）。
3. **可选配置文件** `ghostcontainer.toml`（项目根目录）：

```toml
[project]
name = "myapp"            # 可选；缺省 = 目录名。合法性同容器名校验：^[a-zA-Z0-9][a-zA-Z0-9_.-]+$，≤63 字符
lang = "node"             # 必填；镜像命名前缀，自由字符串（见遗留问题 L3）

[base]
image = "node:22-alpine"  # 必填；上游基础镜像，必须带 tag
dockerfile = "Dockerfile.base"  # 可选；缺省 Dockerfile.base，不存在则跳过 base 构建、直接用 base.image 作为构建基底
context = "."             # 可选

[build]
dockerfile = "Dockerfile" # 可选；缺省 Dockerfile
context = "."             # 可选
args = { MODE = "release" }  # 可选；映射 --build-arg
target = ""               # 可选；映射 --target

[test]
command = ["npm", "test"] # 必填（无测试的项目显式写 command = ["true"]）
workdir = "/app"          # 可选
env = {}                  # 可选

[retain]
keepVersions = 3          # 可选；默认 3。回收时保留最近 N 个版本镜像
keepBase = true           # 可选；默认 true。base 镜像不参与回收
```

配置文件是**便利层而非事实源**：项目存在与否以 label 聚合结果为准（toml 被删而资源还在，项目仍在列表中）；toml 缺失时 `project_build`/`project_test` 不可用并提示先 `project_init`。

## 2. 工作流各步骤语义与底层通道

通道分工依据 #12 §7.2：**build/push/测试容器走 CLI；list/inspect/delete/pull 走 XPC**。通道对 UI/MCP 消费者完全不可见（issue #13：MCP 是策展封装层）。

`project_build`（项目构建）的标准操作链：

| # | 步骤 | 通道 | 语义要点 |
|---|---|---|---|
| 1 | 拉基础镜像 | **XPC** `ClientImage.pull` | 带进度回调（~10Hz 节流，架构 §5）；已存在且未指定 `--pull` 语义时跳过（v1 总是条件拉取：本地缺失才拉） |
| 2 | 构建 base 镜像 | **CLI** `container build` | 仅当 toml 存在 `[base].dockerfile` 且文件存在时执行；`-t {lang}-{project}-base:latest -l com.ghost233.project=<name> --progress plain`；builder 生命周期由 CLI 自管（无需 GUI 干预，#12 §1.2） |
| 3 | 构建版本镜像 | **CLI** `container build` | 取号 n（锁内）→ `-t {lang}-{project}-v{n}:latest -l com.ghost233.project=<name> --progress plain`；`--build-arg`/`--target`/`--no-cache` 从 toml 与调用参数映射 |
| 4 | 跑测试容器 | **CLI** `container run --rm` | 见 §2.1；`skipTests=true` 时跳过 |
| 5 | 清理旧版本 | **XPC** delete + GC | 按 §3 释放判定算法；默认只释放超出保留策略且无人使用的旧版本 |
| 6 | （可选）推送 registry | **CLI** tag + push | 见 §5；构建流程默认不自动推送，由 `project_publish` 显式触发 |

- **构建进度**：CLI `--progress plain` 逐行文本（无 JSON，#12 §1.1）；桥接层逐行解析为阶段事件（step N/M、当前指令），经 EventChannel → UI，同时折叠为 MCP progress notification（mcp-tools.md §6）。**取消 = 杀 CLI 子进程**（上游 SIGTERM → `.interrupted` → cancelAll，#12 §1.3）；构建残留仅可能留在 builder 层缓存。
- **构建失败**：CLI 非零退出 → 工作流中止，已产出的中间 tag（base）保留，版本 tag 不落（`-o oci` 默认仅在成功时导入打 tag，#12 §1.1/§1.4）。错误码 `INTERNAL`，message 附最后 50 行构建输出。
- **v1 不持久化构建历史**（issue #13：无独立构建页面、无构建历史管理；完整 Builds 归 v2）。构建输出仅经 progress 与最终结果返回，不落盘。见遗留问题 L2。

### 2.1 测试容器语义（`project_test`，也是 build 第 4 步）

- 形态：`container run --rm --name gcm-test-<project>-<unixts> -l com.ghost233.project=<name> -l com.ghost233.role=test [-w workdir] [-e k=v...] {lang}-{project}-v{n}:latest <test.command...>`
- **退出码透传**：CLI 退出码 = 容器 init 进程退出码（#12 §6 源码级确认）；桥接层原样透传为结果的 `exitCode` 字段。
- **测试失败不是工具错误**：`exitCode != 0` 时工具正常返回（`isError: false`），由调用方（UI 标红 / agent 判断）解释。只有容器无法创建、镜像不存在等执行失败才走错误模型。
- **清理**：`--rm` 停止后自动删除（autoRemove 语义）；app 崩溃残留的下一次同项目操作前按 `com.ghost233.role=test` label 扫描清理（best-effort）。
- **输出**：stdout/stderr 各上限 64 KiB，超出截断 + `truncated: true`（与 container_exec 同规则）。

## 3. 释放判定算法

决策（issue #13）：**不激进**——旧镜像无人使用才释放或明确保留；同项目操作在内存记引用快照、由操作触发重估，**事实以 CLI 查询为准**；被项目外资源引用的镜像跳过并列报告。

```
触发点：project_build 第 5 步、project_reclaim 执行时
输入：项目名、保留策略（keepVersions=N, keepBase）
─────────────────────────────────────────────
1. 重估（事实采集，CLI 为准）：
   a. `container image list --format json` 全量 → 客户端过滤出本项目镜像
      （base + v{*}，按命名规约匹配）
   b. `container list --format json`（或 XPC list）全量容器 →
      每个容器的 configuration.image.reference 构成「真实引用集」
      （按引用字符串匹配——上游 prune 同款语义，#12 §4.2）
   c. 内存引用快照（见下）仅用于并发窗口提示与 UI 预展示；
      与 a/b 冲突时一律以 a/b 覆盖内存快照
2. 判定（对每面项目镜像，按版本号从旧到新）：
   - base 镜像且 keepBase → 保留（reason: "retention.base"）
   - 版本号在最近 N 个之内 → 保留（reason: "retention.keepVersions"）
   - 引用出现在真实引用集中：
     · 引用容器带本项目 label → 保留（reason: "inUse.project"）
     · 引用容器无本 label 或属其他项目 → **跳过，列入外部引用报告**
       （reason: "inUse.external"，referencedBy 列出容器 id/名）
   - 其余 → 释放
3. 释放执行：XPC `ClientImage.delete(reference:)` 逐个删（name:tag 寻址），
   全部完成后 `cleanUpOrphanedBlobs()` 统一 GC（同步回收磁盘，#12 §4.1/§4.3）
4. 前后各取 `container system df --format json`，差值写入报告
```

**内存引用快照**的职责边界：Service layer 对同项目操作（build/reclaim/delete）维护 `{project → {imageRef → 引用计数, 引用者}}`，用于①并发窗口内的快速判定（两个连续 build 之间不必等 CLI）、②UI 详情页「使用中」标记的即时性。它**永不作为释放依据的终审**——任何实际 delete 之前必须经步骤 1 重估。

**多 tag 同 digest 语义**（#12 §4.3）：删单个 tag 只删映射，内容在最后一个引用删除 + GC 后才释放。base 与版本镜像共享层时，删旧版本只释放独占层——报告的 `reclaimedBytes` 以 `system df` 差值为准，不以被删 tag 的名义大小求和。

## 4. 项目回收（`project_reclaim`）与销毁清单

语义：按项目粒度停止并删除成员容器 + 按 §3 释放旧版本镜像的组合操作。**默认 force**（与手动 UI 删除的 force 语义分叉是已定决策：手动删除默认不勾 force；项目自动化回收默认 force 并附销毁清单）。

执行顺序：

1. 列出成员容器（label 过滤）→ 全部 stop（运行中的走优雅停止，默认 5s）→ delete（force）
2. 按 §3 算法释放镜像（keepVersions 可被调用参数覆盖；`dryRun: true` 时只算不删，直接返回报告）
3. 生成回收报告

**回收报告（销毁清单）格式**——同时是 UI 确认页与 MCP `structuredContent` 的 schema：

```json
{
  "project": "myapp",
  "dryRun": false,
  "startedAt": "2026-10-23T21:00:00+08:00",
  "finishedAt": "2026-10-23T21:00:12+08:00",
  "containers": {
    "stopped": [{"id": "…", "name": "myapp-dev"}],
    "deleted": [{"id": "…", "name": "myapp-dev"}],
    "failed":  [{"id": "…", "name": "…", "error": "…"}]
  },
  "images": {
    "deleted": [{"reference": "node-myapp-v1:latest", "version": 1}],
    "retained": [
      {"reference": "node-myapp-v3:latest", "reason": "retention.keepVersions"},
      {"reference": "node-myapp-base:latest", "reason": "retention.base"}
    ],
    "skippedExternal": [
      {"reference": "node-myapp-v2:latest",
       "reason": "inUse.external",
       "referencedBy": [{"id": "…", "name": "someone-elses-container"}]}
    ]
  },
  "disk": {"beforeBytes": 0, "afterBytes": 0, "reclaimedBytes": 0},
  "errors": [{"step": "…", "code": "…", "message": "…"}]
}
```

原则：**凡是跳过的必须列名，凡是删除的必须留痕**。外部引用跳过不是错误（`errors` 为空、`skippedExternal` 有内容是合法结果）。

## 5. 本地 registry 最小形态

定位：项目镜像的「冷存储」——推送后可删本地镜像释放磁盘，需要时拉回恢复（issue #13 决策）。

- **形态**：常驻普通容器，固定名 `gcm-registry`，镜像 `registry:2`（linux/arm64 可用，#12 §3），端口固定 `127.0.0.1:5056:5000`（默认可配），bind mount 持久化：`--mount type=bind,source=~/Library/Application Support/com.ghost233.ghostcontainermanager/registry,target=/var/lib/registry`。打 label `com.ghost233.managed=registry`（属「App 创建的资源」，UI 正常可见）。
- **协议**：**仅 plain HTTP loopback**。推送/拉回一律 `container image push|pull --scheme http`（CLI 路径，规避 XPC helper 的 keychain ACL 风险族 #1733/#1874——本地无认证本不触发，但统一 CLI 少一条分支）。上游无 insecureRegistries 配置、HTTPS 自签名无 skip-verify（#731），故 v1 不支持 HTTPS registry。
- **推送**（`project_publish`）：`container image tag {lang}-{project}-v{n}:latest 127.0.0.1:5056/{project}/{lang}-{project}-v{n}:latest` → `container image push --scheme http <target>` → 成功后可选删本地 tag（tag 语义：原引用保留，#12 §2.1；registry tag 作为额外引用，释放本地内容仍需删全部本地 tag + GC）。
- **拉回恢复**（`project_restore`）：`container image pull --scheme http 127.0.0.1:5056/...` → `container image tag` 回本地规约名。
- **起停**：`registry_start` = create（缺失时，含拉镜像）+ start，幂等；`registry_stop` = stop（数据保留在 bind mount）。健康检查：`GET http://127.0.0.1:5056/v2/` 期待 `Docker-Distribution-Api-Version` 头（#12 §3 实证）。
- **循环依赖风险提示**（UI 与 MCP hint 必须呈现）：
  1. registry 自身是 container runtime 上的容器——`system_stop` 会停掉 registry，推送/拉回期间不可停 runtime；
  2. 「推送释放磁盘」的释放发生在**删本地镜像 + GC** 之后，registry 数据目录本身占同一块磁盘——推送不等于释放；
  3. 删除 registry 容器不丢数据（bind mount），但删除数据目录 = 丢失全部已推送镜像，UI 对数据目录不提供一键删除入口。

## 6. 错误与边界

- **多项目并发**：不做队列（已定决策）。项目级操作（build/test/reclaim/publish）持 **per-project 异步锁**（复用 container-lifecycle.md §3 的 per-container 锁机制，键 = 项目名）；锁内完成版本取号，杜绝并发 build 撞号。容器/镜像粒度的并发仍由既有 per-container 锁兜底。锁冲突返回 `CONFLICT`，message 指明进行中的操作。
- **Dockerfile 16KiB 上限**（上游 #735）：Service layer 前置校验 `[base].dockerfile` 与 `[build].dockerfile` 文件大小，超限返回 `INVALID_ARGUMENT`，hint 说明上游限制并建议拆分多阶段。
- **寻址必须 name:tag**：所有镜像引用参数在 schema 层用 pattern 校验（必须含 `:tag`、禁止 `@sha256:` 与裸 digest），Service layer 再复核一次（E02 I/O 边界校验）。违规返回 `INVALID_ARGUMENT`，hint 引用 #1962 陷阱说明。
- **退出码透传**：`project_test` 的 `exitCode` = 测试命令退出码（§2.1）；非零不构成工具错误。
- **构建/测试输出有界**：progress 流无限但逐行；最终结果内嵌输出 stdout/stderr 各 ≤64 KiB，截断标记 `truncated`。
- **XPC/CLI 错误统一映射**到 mcp-tools.md §5 错误码；CLI 步骤的失败 message 附末 50 行输出。
- **runtime 未运行**：build/test 依赖 apiserver（容器运行）与 CLI；前置 `system_status` 检查，未运行返回 `RUNTIME_UNAVAILABLE`，hint 引导 `system_start`（builder 由 CLI 自管，不需单独启动）。

## 7. 遗留问题（真正分叉的实现选择，实施前需拍板）

- **L1 registry 工具域归属**：本文档与 mcp-tools.md 采用独立 `registry_` 域（`registry_start/stop/status` 三工具）；备选并入 `project_` 域（`project_registry_*`，名字冗长）或并入 `system_`（语义不纯：registry 不是 runtime 自身）。倾向独立域，待确认。
- **L2 构建历史**：v1 决策「无构建历史管理」，构建输出仅经 progress/结果返回、不落盘。orchard 的持久化范式（20 条记录/4000 行 transcript，BuildsPersistence.swift）是 v2 Builds 的现成参照。确认 v1 不做任何落盘（含最后一次构建输出）。
- **L3 `lang` 字段**：自由字符串（当前方案）还是枚举校验（node/python/go/rust…）？自由字符串灵活但拼写漂移会制造孤儿命名前缀；枚举可扩展性差。倾向自由字符串 + init 时给常用建议。
- **L4 版本号形态**：`v{n}` 纯递增整数（当前方案）vs 时间戳/语义版本。整数与人类时间线对齐最好，但无法表达源码版本；如需可在 tag 之外用 label 记录 git sha（`com.ghost233.revision`），v1 未纳入，待确认。
- **L5 base 镜像的 tag 策略**：base 固定 `:latest` 原地重建（当前方案，旧 base 内容变 dangling 由 `image prune` 级别清理）vs base 也版本化（`{lang}-{project}-base-v{n}`，磁盘代价大、收益不明）。倾向原地重建。

## 8. GLOSSARY 校验与新增建议

已有术语（项目/项目工作流/项目回收/本地 registry）与本文一致，无需修订。建议新增：

- **引用快照（reference snapshot）**：Service layer 在内存中维护的「项目 → 镜像引用 → 引用者」映射，用于并发窗口快速判定与 UI 即时展示；永不作为释放判定的终审，事实以 CLI 查询为准。
- **外部引用（external reference）**：项目镜像被不带本项目 label 的容器引用的情形；回收时跳过并在销毁清单的 `skippedExternal` 中列名。
- **销毁清单（reclaim manifest）**：项目回收的结构化报告，记录停止/删除/保留/外部跳过的全部条目与磁盘差值；UI 确认页与 MCP 结构化输出共用同一 schema。
- **测试容器（test container）**：以 `--rm` 一次性运行、打 `com.ghost233.role=test` label 的短生命周期容器；CLI 退出码透传为测试结果。
