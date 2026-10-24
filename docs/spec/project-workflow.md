# 项目工作流与本地 registry 规格

- 工单：GitHub issue #13（wayfinder 地图 #1 子工单）；MCP 工具域见 docs/spec/mcp-tools.md §3.6/§3.7
- 日期：2026-10-23（v2：按用户终轮拍板全面简化，推翻 v1 的 toml 五节 schema、base/版本两步构建、保留策略与「构建不落盘」）
- 输入：docs/research/container-build-registry.md（#12 调研）、docs/spec/mcp-tools.md（#8）、docs/spec/container-lifecycle.md（#3）、docs/spec/architecture.md（#2）、GLOSSARY.md
- 决策状态：**全部由用户终轮拍板（2026-10-23 晚），无待决问题**；拍板记录见 §7。

---

## 1. 项目模型

### 1.1 识别：label + ghostcontainer.toml（prefix 单字段）

项目 = 一组带 label `com.ghost233.project=<prefix>` 的容器与镜像。GCM 创建的项目资源一律打该 label（E04）；测试容器额外打 `com.ghost233.role=test`；registry 容器不属于任何项目，用固定名 `gcm-registry` 识别。项目发现 = 按 label 聚合（容器走 XPC `ContainerListFilters.labels` 正则；镜像无服务端过滤，`image list --format json` 全量拉取后客户端过滤，量小可接受——#12 §5.1）。

项目目录用 `ghostcontainer.toml` 声明归属，**只存一个字段**：

```toml
prefix = "myapp"
```

唯一作用：声明「这个目录属于哪个项目」。`prefix` 即项目名，同时是 label 值与镜像名前缀。**原 v1 的 [project]/[base]/[build]/[test]/[retain] 各节全部删除，lang 概念消失**；构建与测试参数全部走调用方（§2）。toml 是便利层而非事实源（E07）：无 toml 的目录也可用显式 `project` 参数操作。

- `prefix` 必须匹配 `[a-z0-9][a-z0-9.-]{0,126}`（image 名安全字符集）；非法或缺失报 `INVALID_ARGUMENT`（错误模型见 mcp-tools.md §5）。
- toml 与 label 不一致时以 label 为准，UI 提示修复（E07 单一权威源）。

### 1.2 镜像命名规约

```
{prefix}-{自定义名}:latest
```

- 自定义名由调用方起（如 `myapp-go1`、`myapp-go2`）：不假定语言、不假定镜像数量、不解释名字含义；多语言/多镜像靠自定义名自行区分。
- **无 base/版本镜像之分，无 v{n} 取号逻辑。**
- 一律显式 `:latest` tag：规避上游 digest 寻址缺陷（#1962，digest 寻址会被误解析为 docker.io 并回退 pull）；客户端禁止 docker.io/library 补全（orchard 教训）。
- 「项目内唯一」是管理层约定（label + 前缀约束）；runtime 的镜像名是全局命名空间，跨项目占用同一前缀属故意越权，GCM 按 label 归属管理。

### 1.3 同名构建 = 默认替换

项目内同名镜像重新构建 = **直接替换**，无 replace flag：

- 新构建产物沿用 `{prefix}-{name}:latest` 引用；旧镜像失去 tag 变 dangling，由 `image delete` 的同步 GC（cleanUpOrphanedBlobs）或项目回收兜底。
- 引用旧镜像内容的旧容器不受影响（内容寻址存储）。
- 「想留旧版」= 给它一个独立名字（`myapp-go1` → `myapp-go2`）；不重建同名牌，它就一直在——这是新模型下唯一的「保留版本」方式。

## 2. 工作流

单步构建。不再有 base/版本两步，没有取号。

### 2.1 project_build 构建链

| 步骤 | 动作 | 通道 |
|---|---|---|
| 1 | 解析项目（`path` → toml → prefix，或显式 `project` 参数）；acquire per-project 锁 | Service layer |
| 2 | `container build -t {prefix}-{name}:latest [-f dockerfile] [--build-arg K=V …] --progress plain <context>`（FROM 镜像由 BuildKit 自动拉取） | **CLI** |
| 3 | 逐行解析 `--progress plain` 输出，转发 progress notification / UI | Service layer |
| 4 | （可选，`skipTests=true` 跳过）按 §2.2 跑测试容器 | **CLI** |
| 5 | release 锁；构建结束按 §2.3 落盘（仅失败） | Service layer |

- **取消 = 杀 CLI 构建子进程**（XPC 无构建取消 API；#12 §1.3）。
- builder 生命周期（`builder start`、buildkit 容器）由 CLI 自管；GCM 不代管、不暴露 builder 管理工具。
- Dockerfile 内容上限 16KiB（上游 #735）；超限报 `INVALID_ARGUMENT`（hint 说明上游限制）。
- `buildArgs` 经 `--build-arg` 透传；`dockerfile`/`context` 缺省为项目目录下 `Dockerfile` 与项目目录本身。

### 2.2 测试容器（project_test）

- `container run --rm {prefix}-{name}:latest <command…>`：**`command` 为必传参数**（toml 已无 [test] 节），`--rm` 必带（一次性自清理）。
- 退出码透传：CLI 退出码 = init 退出码；测试失败（非零退出）**不是工具错误**，输出 `{exitCode, testsPassed: false}`，由 agent 决策。
- 测试容器打 `com.ghost233.role=test` label，回收与 UI 可按 role 过滤。
- stdout/stderr 各上限 64 KiB，超出截断并标 `truncated: true`（与 mcp-tools.md §4 有界性规则一致）。

### 2.3 构建日志落盘（只落盘失败）

照搬 orchard BuildsPersistence 已验证的参数与模式：

- **只落盘失败构建**（含 cancelled / interrupted）：日志尾部 **1000 行** + 构建元数据（project、name、dockerfile、时间、失败阶段、退出原因）。
- 保留最近 **20 条**；**成功构建不落盘**。
- **只在构建结束时写一次盘**（构建过程零文件 I/O）。
- 目录：`~/Library/Application Support/<app bundle id>/build-logs/`。

### 2.4 推送与拉回（project_publish / project_restore）

- 推送：`container image push --scheme http 127.0.0.1:5056/{prefix}-{name}:latest`——**一律 CLI**（XPC push 有 keychain ACL 风险族 #1733/#1874）。`--scheme http` 是 plain HTTP 的唯一开关（无 `--insecure`；HTTPS 自签无 skip-verify，#731）。
- `deleteLocal?: bool`：推送成功后删本地镜像（同步 GC 释放磁盘），默认 false。
- 拉回：`container image pull --scheme http 127.0.0.1:5056/{prefix}-{name}:latest` → `image tag` 回 `{prefix}-{name}:latest`。
- 归属：拉回的镜像无构建期 label，**按命名前缀归入项目**——label 优先、前缀兜底（前缀约定是项目归属的最终兜底事实）。
- 回收边界（审查后补记）：`project_reclaim` 的释放判定**只用 label 归属**（`allowFallback: false`），不覆盖前缀兜底的镜像——restore 拉回的无 label 镜像不会被回收（保守取舍，防误删外部同名前缀镜像）；如需清理须显式 `image_delete`。

## 3. 释放判定算法

触发时机：项目回收（`project_reclaim`）与构建前后（操作触发重估），非定时扫描。

1. acquire per-project 锁（防并发同名构建冲突，保留决策）。
2. **内存引用快照**（Service layer 维护的容器→镜像引用表）给出即时初判：保证 UI 即时性与并发窗口内的安全。
3. **CLI/XPC 查询为终审事实**：`container list --format json`（含 stopped，XPC 支持 label 正则过滤）+ `image list --format json`（镜像只能客户端过滤）。
4. 判定（新规则，无保留策略、无版本号排序）：
   - 项目内镜像**未被任何容器引用** → **可释放**；
   - 被**本项目**容器引用 → 保留（报告 reason `inUse.project`）；
   - 被**项目外**容器引用 → 跳过并列报告（`skippedExternal`，附引用方容器名）。
5. `image delete` 同步触发 GC（cleanUpOrphanedBlobs）；多 tag 同 digest 时最后一个引用删除才释放内容。

## 4. 项目回收报告（销毁清单）

```json
{
  "project": "myapp",
  "containers": {
    "stopped": ["web"],
    "deleted": ["web"],
    "failed": []
  },
  "images": {
    "deleted": ["myapp-go1:latest"],
    "retained": [{"reference": "myapp-go2:latest", "reason": "inUse.project"}],
    "skippedExternal": [{"reference": "myapp-db:latest", "usedBy": ["other-app-db"]}]
  },
  "disk": {"beforeBytes": 0, "afterBytes": 0, "reclaimedBytes": 0},
  "errors": []
}
```

- `retained.reason` 枚举只剩 `inUse.project`（`inUse.external` 走 `skippedExternal`，二者不重叠）；**retention.\* 字段全部删除**。
- 磁盘差值：`container system df --format json` 前后对比。
- 同一 schema 供 UI 确认页与 MCP structuredContent 共用（E06）；`dryRun=true` 返回同构预演报告。
- `project_reclaim` 默认 force（先 stop 后 delete 项目容器），destructive ✓ 注解。

## 5. 本地 registry 最小形态

- 单例 app 托管容器 `gcm-registry`，镜像 `registry:2`（arm64 可用，loopback 发布有上游实证 #1538）。
- 仅 loopback：发布 `127.0.0.1:5056:5000`，plain HTTP，push/pull 一律 `--scheme http`。
- 数据 bind mount 到 `~/Library/Application Support/<app bundle id>/registry/`，容器重建不丢数据。
- 一键起停：`registry_start`（缺失时 create+pull，幂等）/ `registry_stop`（数据保留）/ `registry_status`（GET /v2/ 探活）。
- **三条循环依赖风险（UI 与 MCP 描述必须提示）**：
  1. `system_stop` 会波及 registry 容器——推送/拉回会被打断；
  2. 推送 ≠ 释放：本地副本仍在，释放靠 `deleteLocal` 或项目回收；
  3. 删除 registry 数据目录 = 已推送内容全部丢失，无备份。

## 6. 错误与边界

- **并发**：无队列；per-project 锁使同项目构建/测试/回收/发布互斥，跨项目并行允许。锁冲突报 `CONFLICT`（hint：另一项目操作进行中）。
- **上限**：Dockerfile 16KiB；exec/测试输出 64KiB/流；寻址必须 name:tag（schema pattern 强制，禁 digest）。
- **退出码透传**：测试容器非零退出不是工具错误（§2.2）。
- 错误模型遵循 mcp-tools.md §5（isError + 结构化 code/message/hint/source）；项目域典型 code：`NOT_FOUND`（项目/镜像不存在）、`CONFLICT`（项目锁、toml 已存在）、`INVALID_ARGUMENT`（prefix 非法、Dockerfile 超限、digest 寻址）、`RUNTIME_UNAVAILABLE`（apiserver 未运行）、`INTERNAL`（兜底，保留原始错误文本）。

## 7. 终轮拍板记录（2026-10-23 晚）

用户 grilling 终轮拍板，项目模型大幅简化，原遗留问题 L1–L5 全部关闭：

1. **toml 极简化**：仅存 `prefix` 单字段；其余各节删除；lang 概念消失（消解原 L3）。
2. **命名 = `{prefix}-{自定义名}:latest`**：无 base/版本镜像区分、无 v{n} 取号（消解原 L4）；同名构建默认替换，旧镜像 dangling 由 GC 兜底（消解原 L5 的 base 原地重建之争）。
3. **构建/测试参数走调用方**：`project_build(project|path, name, dockerfile?, context?, buildArgs?)`、`project_test(project|path, name, command)`。
4. **释放判定新规则**：项目内未被任何容器引用的镜像回收时都可释放；`inUse.project` 保留；项目外引用跳过并列报告；retention.\* 删除。内存快照 + CLI 终审的算法主干不变。
5. **per-project 锁保留**。
6. **构建日志改为失败落盘**（推翻原 L2「不落盘」）：失败（含 cancelled/interrupted）落盘尾部 1000 行 + 元数据、保留最近 20 条、构建结束一次写盘、`Application Support/build-logs/`。
7. **registry 独立工具域已定**（原 L1）：`registry_status/start/stop` 不并入 `project_`。

## 8. GLOSSARY 更新建议（不在本任务 write scope，请 lead 安排）

- **项目（Project）** 词条需改写：识别 = label + toml 的 prefix 单字段；命名 = `{prefix}-{自定义名}:latest`；同名替换语义。
- **项目回收（Reclaim）**：释放判定改为「未引用即可释放」，无保留策略。
- 建议新增 **前缀（Prefix）**：toml 唯一字段，项目名 = label 值 = 镜像名前缀。
- 删除或改写涉及 base 镜像 / 版本号 / keepVersions 的旧表述。
