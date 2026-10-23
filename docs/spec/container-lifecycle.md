# 容器生命周期状态与操作语义决策（issue #3）

> 决策简报。结构：背景 → 状态机 → 操作语义矩阵 → 并发与线性化 → 与 orchard 差异 → 推荐汇总 → 待用户拍板 → 新术语。
> 证据来源：apple/container 上游源码（main 分支，版本锚 1.6.0）、orchard 源码（andrew-waters/orchard main）、docs/research/bridge-flutter-apple-container.md。

## 背景

v1 范围中 containers 全操作 = list/create/start/stop/restart/delete/logs/exec。UI 与 MCP 共用同一 Service layer，因此状态模型与操作语义在这里定义一次，两处消费。本简报回答三件事：状态机长什么样、每个操作的精确定义、并发来源下如何线性化。

关键事实前提（已取证）：

- 上游运行时状态枚举 `RuntimeStatus`（`Sources/ContainerResource/Container/RuntimeStatus.swift`）只有四个值：`unknown / stopped / running / stopping`。**没有 `created` 态**——`create` 落盘后即 `.stopped`。
- 服务端 `ContainersService`（`Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`）是语义的权威来源，下表所有「上游行为」均出自该文件。
- 容器 id = 小写 UUID；名字校验 `^[a-zA-Z0-9][a-zA-Z0-9_.-]+$` 且 ≤63 字符；创建时内存下限 200 MiB。
- 容器进程退出由 apiserver 的 ExitMonitor 捕获，状态回落 `.stopped`；创建时 `autoRemove: true` 的容器退出后直接删 bundle，从列表消失。

## 1. 状态机

### 1.1 上游原生状态（XPC `ContainerSnapshot.status` 直接可读）

| 状态 | 含义 | 进入方式 |
|---|---|---|
| `stopped` | 已创建未运行，或已退出/已停止 | create 落盘即此态；stop/退出/kill 完成后回落此态；apiserver 重启后一切容器按此态重建（loadAtBoot） |
| `running` | init 进程在跑 | startProcess(init) 成功后设置，同时写入 `startedDate` 与 `networks` |
| `stopping` | 停止进行中 | runtime 在 teardown 期间上报；**此态下 delete 一律报错**（即使 force） |
| `unknown` | 兜底 | 快照无法归类时；实践中罕见 |

### 1.2 需要 Service layer 自行合成的呈现态

上游状态机对 UI/MCP 来说太粗，以下呈现态由我们的 Service layer 在内存中合成，不写入任何上游存储：

| 合成态 | 合成依据 | 用途 |
|---|---|---|
| 拉取镜像中（pulling） | create 流程的 `ClientImage.fetch` 阶段进行中（create 之前必须先拉镜像，这是客户端编排的两步） | create 进度展示；此阶段容器尚不存在，取消=中止拉取，无副作用 |
| 创建中（creating） | 已发起 `client.create` 未返回 | 防止重复 create 同名容器 |
| 启动中（starting） | bootstrap+startProcess 已发起、list 尚未回 `running` | start/restart 的进行中展示 |
| 停止中（stopping，本地强化版） | 本地 stop 调用在飞，或服务端已报 `stopping` | 两种来源合并展示；禁止并发重复 stop |
| 删除中（deleting） | delete 调用在飞 | 防止重复 delete；条目置灰 |
| 退出码（observed exit code） | 仅当 app 运行期间通过 wait/轮询观察到 running→stopped 跳变时可附带；**上游快照不持久化退出码**，app 未运行时的历史退出码不可得 | 详情页 best-effort 展示「上次观察到的退出码」 |

### 1.3 合法转换

```
(无) --create(含拉镜像)--> stopped
stopped --start--> [启动中] --> running
running --stop--> [停止中] --> stopped
running --进程自行退出--> stopped        （ExitMonitor 捕获）
running --kill SIGKILL--> stopped
running --delete(force)--> (SIGKILL 5s 后) 消失
stopped --delete--> 消失
running/stopped(autoRemove) --退出--> 消失
任意态 --apiserver 重启--> stopped       （loadAtBoot 重建）
```

非法转换（上游直接报错，Service layer 应前置校验给出友好错误）：

- start 一个 `running` 容器：上游 startProcess 幂等返回（视为成功 no-op）；
- stop 一个 `stopped` 容器：上游幂等返回（视为成功 no-op）；
- delete `running` 且无 force：报错 "container is running and can not be deleted"；
- delete `stopping`：一律报错（force 也不行）；
- exec/stats/copyIn/copyOut/clean 非 `running` 容器：报错 invalidState；
- create 同名容器：报错 exists。

## 2. 操作语义矩阵

| 操作 | 上游路径 | 精确定义（v1 语义） | 参数与默认值 | 幂等性 |
|---|---|---|---|---|
| list | `ContainerClient.list()` | 全量快照（含 config+status+networks+startedDate）。**资源全可见**：不做 orchard 的 machine backing 过滤（见 §4 差异点） | 无 | 只读 |
| create | `ClientImage.fetch` → `client.create` | 拉镜像（缺时）→ 落盘配置。落盘后状态=stopped，不启动 | autoRemove 默认 false（对应 `container run --rm` 的反面；UI 暴露为「退出后自动删除」开关）；内存下限 200 MiB 由上游校验 | 同名报错，非幂等 |
| start | `bootstrap` + `startProcess` | 注册 launchd runtime 服务并拉起 init 进程；stdio 全 nil（后台容器语义） | 无参数 | 上游幂等（running 时 no-op） |
| stop | `client.stop(id, opts)` | 向 init 发停止信号，等待优雅超时后 runtime 升级 SIGKILL；完成后清理 runtime 服务，状态回 stopped | `timeoutInSeconds` 默认 **5**（=`ContainerStopOptions.default` 与 CLI `--time` 默认）；`signal` 默认 nil → 用容器配置 `stopSignal` → 再缺省 SIGTERM | 上游幂等 |
| restart | **上游无此命令**（CLI 与 orchard 均无） | Service layer 合成：`stop(默认参数)` 成功后 `start`。非原子；stop 幂等所以 restart 一个 stopped 容器 = 纯 start | 参数继承 stop | 合成操作，可安全重试 |
| delete | `client.delete(id, force)` | stopped：直接删 bundle+注销 launchd；running 且 force=true：上游先 SIGKILL(5s) 再删；running 且无 force：前置拒绝 | `force` 默认 false；UI 对运行中容器给「强制停止并删除」复选项（不设破坏性门控是已定决策，此处仅做语义透明） | 删后重发=notFound 报错，Service layer 吞掉视为成功 |
| logs | `client.logs(id)` → 两个 FileHandle | fhs[0]=容器 stdio 日志，fhs[1]=bootlog（VM 引导日志）。任意状态可读，无文件时读作空。**XPC 独有**（CLI 的 `logs -f` 是裸文本不可用） | 默认：初始加载末尾 500 行 + follow 开；bootlog 作为可切换来源 | 只读 |
| exec | `createProcess` + `start` | **v1 = 一次性命令**：非 TTY（terminal=false），stdout/stderr 分管道捕获，返回退出码。继承容器 env，调用方可覆盖 env/工作目录/user。交互式 TTY 不在 v1（需要 stdin 流 + resize  plumbing，orchard 也未做） | MCP 侧加 `timeoutSeconds`（默认 30）超时后 kill 进程组；注意上游已知 bug apple/container#1941（kill 信号类型不匹配），kill 可能失败 → 超时语义=放弃等待并报告，进程可能残留 | 每次 exec 是独立进程，天然安全 |

补充语义细节：

- **stop 的升级路径**：`ContainerStopOptions{timeoutInSeconds, signal}` 交给 runtime 执行「signal → 等 timeout → SIGKILL」。这与 Docker 语义一致，只是默认 5s 而非 Docker 的 10s。
- **kill**：v1 操作清单未列 kill，但 XPC 有 `kill(id, signal)`。建议 Service layer 内部保留能力（stop 超时升级、exec 超时清理都用得到），UI/MCP 不暴露独立 kill 操作。
- **autoRemove 容器消失**：list 轮询时条目会无预警消失。UI 需要把「条目消失」当正常事件处理（从列表移除+轻提示），不当错误。
- **stats**：单次快照（cpuUsageUsec/memoryUsageBytes/memoryLimitBytes/networkRx/Tx/blockRead/Write/numProcesses），流式=Service layer 轮询（列表页 2s，详情页 10s——与 bridge 调研建议一致）。仅 running 容器可取。

## 3. 并发与线性化

来源：UI 按钮、MCP 工具调用、菜单栏快捷操作，三路同打 Service layer。

**推荐模型：Service layer 内 per-container 操作互斥 + 操作去抖。**

1. **互斥粒度**：每个容器 id 一把异步锁。写操作（create/start/stop/restart/delete/exec）在锁内串行；只读操作（list/logs/stats）不进锁。
2. **同操作去抖**：锁被同类型操作占用时，新到的同类型写操作不排队，直接合并为「跟随在飞操作的结果」（start+start=一次 start）。不同类型操作按到达顺序排队。
3. **进行中呈现**：在飞操作把 §1.2 的合成态挂到该容器条目上，所有订阅方（UI/MCP 长连接）看到同一份。
4. **跨重启一致性**：app 重启后合成态清零，以上游快照为准——上游 apiserver 重启同理（一切回 stopped）。
5. **超时与取消**：
   - stop：UI 侧等待上限 = timeoutInSeconds + 10s 余量（默认即 15s）；超时后操作不取消（服务端仍在执行），转为「后台继续」并继续轮询状态。理由：stop 在上游不可中途取消，假取消只会造成状态不一致。
   - create（拉镜像阶段）：可取消（中止 fetch，容器未落盘无副作用）；落盘阶段不可取消。
   - exec：MCP 侧默认 30s 超时放弃等待（见矩阵）。
6. **stopping 窗口**：上游在 stopping 态拒绝一切 delete；Service layer 在本地「停止中」合成态期间同样前置拒绝 delete（force 也不行），错误信息指明「等待停止完成」。

### 候选方案对比

| 方案 | 说明 | 权衡 |
|---|---|---|
| A. per-container 锁 + 同操作去抖（推荐） | 上节模型 | 语义简单、三路来源行为一致；全局吞吐不受限（不同容器并行） |
| B. 全局操作队列 | 所有写操作一个队列 | 实现最简单，但 stop 容器 A 会卡住无关容器 B 的 start，不可接受 |
| C. 无锁，直接透传上游错误 | 并发冲突交给 apiserver 报错 | 上游部分幂等部分报错，错误信息面向开发者；UI 会出现闪烁的竞态失败 |

## 4. 与 orchard 的行为差异

| 维度 | orchard | 本方案（v1） | 说明 |
|---|---|---|---|
| 容器列表过滤 | 过滤 machine backing 容器（label `com.apple.container.plugin=machine`） | **不过滤，全部可见**（已定决策「资源全部可见」）；该 label 在 UI 标记为「由 machine 插件管理」 | 管理完整性优先 |
| stop 参数 | 不暴露，永远默认 5s | 暴露超时与信号（高级选项），默认同为 5s | 与 CLI `--time/--signal` 对齐 |
| restart | 无 | 有（合成 stop+start） | 操作清单已定 |
| exec | 一次性命令、行回调（runProcess） | 同为一次性命令；差异=我们 MCP 侧暴露同一能力并加超时 | orchard 的做法验证了非 TTY 路径可行 |
| logs | 走 XPC FileHandle（与 CLI 解耦） | 相同路径，另把 bootlog 显式建模为可切换日志源 | bootlog 对排障（内核/启动失败）重要 |
| delete force | UI 语义「强制」透传上游 force | 相同；另前置拦截 stopping 态的 delete | 上游报错信息不友好 |
| 状态呈现 | 直接用上游四态 | 四态 + 本地合成进行中态 + best-effort 退出码 | 上游快照不含退出码，需明说限制 |

## 5. 推荐汇总

1. 状态模型 = 上游四态（unknown/stopped/running/stopping）+ Service layer 合成态（pulling/creating/starting/stopping-local/deleting）+ best-effort 观察退出码。
2. stop 默认 5s 优雅超时，信号默认沿用容器 `stopSignal`（缺省 SIGTERM），超时 runtime 自动升级 SIGKILL。
3. delete 语义=上游 force 语义；UI 对运行中容器提供「强制停止并删除」选项，默认关。
4. restart = 合成 stop+start，非原子，幂等可重试。
5. exec v1 = 一次性非 TTY 命令；交互式 TTY 显式推迟到 v2 并写入 not-yet-specified。
6. logs 默认 tail 500 + follow；bootlog 可切换。
7. 并发 = per-container 异步锁 + 同操作去抖 + 只读不进锁；stop 不可取消、create 拉镜像阶段可取消。
8. 列表不过滤 machine backing 容器，仅打标。

## 6. 待用户拍板

1. **stop 默认优雅超时**：推荐 5s（与上游 `ContainerStopOptions.default`、CLI `--time` 默认一致）；备选 10s（Docker 习惯）。→ 推荐：**5s**。
2. **delete 对运行中容器的默认交互**：推荐 点击删除运行中容器时弹出选项「强制停止并删除（SIGKILL 5s 后删）」，默认不勾选；备选 不允许 force，必须先手动 stop（更安全但多一步，且与「不设破坏性门控」决策相悖）。→ 推荐：**提供 force 选项，默认不勾选**。
3. **exec 交互式 TTY 推迟**：推荐 v1 只做一次性命令，TTY（需要 stdin 流式 + resize 通道）进 v2。→ 推荐：**推迟**。
4. **logs 初始加载量与 follow 默认**：推荐 末尾 500 行 + follow 默认开。→ 推荐：**500 行 + follow 开**。
5. **退出码展示限制**：推荐 仅展示 app 运行期间观察到的退出码，详情页标注「退出码仅在 App 运行期间可见」（上游不持久化）。备选 轮询 wait 常驻追踪所有容器（成本高、重启仍丢失）。→ 推荐：**best-effort 观察**。
6. **machine backing 容器**：推荐 可见且可操作，但标注来源插件。→ 推荐：**可见+打标**（已定「资源全可见」的推论，列出仅作确认）。
7. **kill 是否作为独立用户操作**：推荐 不暴露独立 kill（stop 的超时升级已覆盖强杀需求；exec 超时清理由内部使用）。→ 推荐：**不暴露**。

## 7. GLOSSARY 新术语（建议追加）

- **运行时状态（RuntimeStatus）**：上游 `RuntimeStatus` 枚举的原生四态：unknown/stopped/running/stopping。XPC 快照直读。
- **合成态（synthetic presentation state）**：Service layer 在内存中合成的进行中呈现态（拉取中/创建中/启动中/停止中/删除中），不落盘、不写入上游。
- **优雅停止（graceful stop）**：先发停止信号（默认取容器 stopSignal，缺省 SIGTERM），等待优雅超时（默认 5s）后由 runtime 升级 SIGKILL 的 stop 语义。
- **强制删除（force delete）**：对运行中容器先 SIGKILL(5s) 再删 bundle 的 delete(force: true) 语义。
- **合成操作（composite operation）**：由 Service layer 编排多个上游操作构成的用户级操作，如 restart = stop + start。非原子，幂等可重试。
- **Bootlog**：容器 VM 引导日志（`client.logs` 返回的第二个 FileHandle），与容器 stdio 日志并列的独立日志源。
- **观察退出码（observed exit code）**：仅在 App 运行期间通过状态跳变观察到的容器退出码；上游快照不持久化退出码。
- **逐容器操作锁（per-container operation lock）**：Service layer 对同一容器写操作串行化、同操作去抖的并发机制。
