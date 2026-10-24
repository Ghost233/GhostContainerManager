# MacLauncher 集成决策简报

- 工单：GitHub issue #10 / 团队任务 task-5（wayfinder 地图 #1 子工单）
- 日期：2026-10-23
- 输入：`docs/integration/maclauncher-sdk.md`（SDK 固定提交 `268f88ef`，回调 onStart/onRecycle/onStatus/onLogs）、`docs/engineering.md`（E04/E06/E07）、`docs/project-scope.md`、`GLOSSARY.md`、onboarding 简报（task-4 同期产出）
- 性质：决策简报——给出选项、权衡与推荐；结论待用户在末尾编号问题清单中拍板后转入实施规格。

## 1. v1 注册哪些能力

固定 SDK 支持服务级回调 `onStart` / `onRecycle` / `onStatus` / `onLogs` 与应用级 `AppCallbacks`（窗口、入口接管、版本查询）。规范要求**只注册已实现的能力**。

**推荐 v1 注册面**：

| 对象 | 注册内容 | 依据 |
| --- | --- | --- |
| 应用级 | `AppCallbacks` 全量（窗口接管、入口接管、版本查询） | 由 SDK 框架承担，无业务语义风险 |
| 服务级 onStatus | ✅ 注册 | 只读，映射到管理入口的实际观测状态（§3.3） |
| 服务级 onLogs | ✅ 注册 | 只读批次，按 `LogQuery` 返回最近 N 条；底层映射容器日志读取（XPC FileHandle 路径） |
| 服务级 onStart | ✅ 注册 | 映射到容器 start；语义简单明确 |
| 服务级 onRecycle | ✅ 注册，语义按 §2 推荐方案 | SDK 无 onStop 回调，启动器侧的"重启"诉求由 recycle 承载 |

**服务粒度推荐：一个容器 = 一个 MacLauncher 服务**。服务 ID 用容器名（Apple container 的容器标识），显示名直接用容器名。Compose 项目不注册为服务（其成员容器各自注册）；镜像、网络、挂载不是可"启动"的对象，不注册。

**注册范围推荐：只注册 App 创建的资源**（带 `com.ghost233.*` label 的容器）。用户已有的容器默认不出现在启动器里——理由：E04 资源所有权（启动器的 start/recycle 是写操作，对用户既有资源应由用户显式请求而非默认暴露）；同时避免启动器被几十个旧容器淹没。设置中提供"把此容器加入 MacLauncher"的逐容器开关作为逃生门。

**maclauncher.json**：`services` 列表由应用运行时动态上报（当前 SDK 的发现机制经 `projectName` + `SdkEntry.currentAppBundle() ?? SdkEntry.currentExecutable()`），仓库内静态 `services: []` 保持为空，直到首个能力实现后再按实际填写。

## 2. onRecycle 的语义方案（核心待定项）

SDK 文档明确 recycle 的业务含义"由规格确定"。三个候选语义：

- **方案 A：recycle = 重启（stop + start 同一容器）**。保留容器内全部状态（可写层、挂载、网络身份）。实现直接复用管理入口的 stop/start。
- **方案 B：recycle = 重建（delete + 按原配置 create + start）**。回到镜像初始状态，丢弃可写层，保留挂载。接近"回收"字面义，但对有状态容器是破坏性的。
- **方案 C：v1 不注册 onRecycle**。等真实使用场景出现再定语义（E10 按需抽象）。

权衡：

| | A 重启 | B 重建 | C 不注册 |
| --- | --- | --- | --- |
| 用户预期（启动器里点"回收"） | 温和：服务短暂中断后恢复 | 激进：容器内数据丢失（仅挂载保留） | 无预期，按钮不存在 |
| 实现成本 | 低（现成 stop/start） | 中（需完整保存/回放 create 配置；依赖 #2 架构的配置模型） | 零 |
| 风险 | 低 | 高（误点即丢状态，不可逆） | 低 |
| 与"容器管理器"定位的一致性 | 好（restart 是通用语义） | 弱（重建是 CI 语义，不是桌面管理语义） | 中 |

➡️ **推荐方案 A（recycle = 重启）**，附加两条约束：①仅对运行中容器可触发，停止态容器 recycle 等价于 start；②recycle 期间 onStatus 如实上报过渡态（stopping → starting），不谎报 ready。方案 B 作为远期选项记入迷雾（如未来出现"重置开发环境"诉求再以独立动作提供），方案 C 仅在 A 的实现受阻时回退。

## 3. 四个回调到生命周期模型的语义映射

统一前提：**SDK 回调不做任何容器逻辑**（E06）——回调只是 MacLauncher 协议与本应用管理入口之间的适配层；所有操作、并发控制、状态权威来源都在管理入口（Service layer）。

### 3.1 onStart

- 语义：启动指定容器（幂等——已 running 则直接回报成功）。
- 映射：管理入口 `containers.start(name)`。
- 前置：就绪检测非 Ready 时（见 onboarding 简报），拒绝并返回携带当前状态的明确错误（不尝试隐式启动 apiserver——system start 是用户可见决策，不经启动器侧悄悄触发）。➡️ 此为推荐，列入拍板问题。

### 3.2 onRecycle

- 语义：按 §2 推荐方案 A = 重启。
- 映射：管理入口 `containers.restart(name)`（内部 stop→start 线性化，与 UI/MCP 发起的同容器操作互斥，依赖 #3 生命周期工单的并发线性化结论对齐）。

### 3.3 onStatus

- 语义：报告**实际观测**状态（SDK 规范：命令受理、连接成功、业务就绪分别表达；查询失败保留错误原因）。
- 映射：管理入口 `containers.get(name)` 的实时状态；容器不存在时如实返回 not-found 而非缓存假象。
- 状态枚举建议：`starting / running / stopping / stopped / failed / unknown`，与 #3 生命周期工单的状态机对齐（两工单结论冲突时以 #3 为准并回改本文档）。

### 3.4 onLogs

- **固定 SDK 实施校正**：`268f88ef` 的实际签名是 `Future<LogBatch> Function(LogQuery)`，语义为“查询最近日志批次”，不是持续 follow 流。
- 映射管理入口的日志读取，按 `LogQuery.limit` 返回最近 N 条（SDK 默认 200、最大 500），`LogBatch.entries` 按 oldest-first 排列。
- 如实填写 `truncated` 与 `observedAt`；`instanceId` 没有可靠来源时保持 null，不伪造运行代次。
- 读到 EOF、SDK 取消或适配层 dispose 时取消上游订阅并释放 fd；不把一次批次响应伪装成持续流。
- v1 不承诺历史完整性；日志页的本地回看仍由容器日志能力承担。

### 3.5 AppCallbacks

- 窗口接管：唤起/聚焦主窗口（菜单栏常驻形态下从菜单栏图标或 Dock 恢复窗口）。
- 入口接管与版本查询：按 SDK 固定版本的默认实现接入；版本查询返回 `pubspec.yaml` 的实际版本（当前 0.0.0 占位，正式版本由发布流程确定）。

## 4. E06 共用管理入口的对接面

```
MacLauncher ──SDK(固定 268f88ef)──► MacLauncherBridge（Dart 适配层，唯一懂 SDK 类型）
                                        │  只做：参数校验、回调→方法翻译、状态枚举映射
                                        ▼
                                 管理入口 Service layer（容器/镜像/系统…唯一业务入口）
                                        │  同一层同时服务：Flutter UI、内置 MCP server
                                        ▼
                                 Swift 桥接（XPC 主 / CLI 补，仅平台适配）
```

- **新增模块**：`MacLauncherBridge`（Dart），是 SDK 与管理入口之间唯一的适配层；SDK 类型不外泄到 Service layer（E02：I/O 边界先校验转换）。
- **Service layer 对 SDK 暴露的接口**：与 UI/MCP 完全相同的公开面——`start/restart/get/logs` 等；不允许 SDK 走旁路。
- **状态权威**：容器状态的唯一权威来源是 Service layer 的观测流（E07）；MacLauncherBridge 订阅转发，不持有副本。
- **dispose()**：关闭 SDK 通信并归还入口；不影响 Service layer 与其他消费者（UI/MCP）继续工作。

## 5. 降级与断连行为

| 场景 | 行为 |
| --- | --- |
| 启动器未运行 | 应用完全独立工作（窗口、菜单栏、MCP 全部正常）；SDK 侧静默等待发现，不弹错 |
| pending-approval（等待用户在启动器批准） | 保留重试；日志节流；UI 设置页显示"等待 MacLauncher 批准"状态，不阻塞主功能 |
| 运行中 SDK 断连 | 已注册服务从启动器消失；应用侧资源**不动**（容器继续运行）；自动重连，恢复后重新注册 |
| 启动器退出 | 同上（断连语义）；不触发任何容器操作 |
| 应用退出 | 容器处置按 #3 生命周期工单结论；SDK `dispose()` 归还入口；不因退出回收用户资源 |
| 就绪检测非 Ready | onStatus 如实上报不可用；onStart/onRecycle 拒绝并携带状态（§3.1）；onLogs 返回空流 + 错误 |

## 6. 待用户拍板的问题清单

- **Q1 - recycle 语义**：是否采用方案 A（recycle = 重启，stop+start 同一容器）？
  ➡️ 推荐：A。重建（B）破坏性太强且依赖配置回放模型，不注册（C）则浪费启动器的重启入口。
- **Q2 - 注册范围**：MacLauncher 服务是否只默认注册 App 创建的容器（`com.ghost233.*` label），用户已有容器靠设置页逐容器开关加入？
  ➡️ 推荐：是。符合 E04 资源所有权，避免启动器被历史容器淹没。
- **Q3 - 服务粒度**：一个容器 = 一个服务（compose 项目不注册、成员容器各自注册）？
  ➡️ 推荐：是。粒度与操作语义一一对应；未来若要"项目级启停"再立项。
- **Q4 - 非就绪时启动器操作的处理**：onStart/onRecycle 在 runtime 未就绪时拒绝，还是尝试自动 `container system start`？
  ➡️ 推荐：拒绝并携带状态。system start 是有用户可见副作用的决策（可能触发内核下载），不应被启动器静默触发。
- **Q5 - onLogs 历史语义**：已定。固定 SDK `268f88ef` 是批式最近 N 条查询，而非纯 follow；按 `LogQuery.limit` 返回 oldest-first 的 `LogBatch`，并保留截断与观测时间信息。

## 7. GLOSSARY 新术语建议

- **MacLauncher 服务（Launcher service）**：应用向 MacLauncher 注册的可管理单元；v1 中一个容器对应一个服务，服务 ID 为容器名。
- **回收（Recycle）**：MacLauncher 对已注册服务的重启语义（v1 定义 = stop + start 同一容器，保留状态）；不是删除重建。
- **入口自报（Entry report）**：应用经 `SdkEntry` 向 MacLauncher 声明自身 bundle/可执行文件与能力的机制。
- **待批准（Pending approval）**：应用在 MacLauncher 侧等待用户批准的连接状态；期间保留重试，不影响应用独立工作。
