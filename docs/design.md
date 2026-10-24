# GhostContainerManager 设计基线

版本：2026-10-24（P0，issue #26）。适用范围：全部 9 页与 `lib/ui/` 共享组件。
本文是本项目的**单一设计事实来源**：语义色、间距、字体、组件与页面模板在此定义，
页面实现引用而非各自重定义。通用 macOS 原则见
`~/.agents/skills/macos-ui-standards/references/standard.md`；本文只记录**项目自定度量**
与**语义映射**，并把 Apple 原则与项目默认值分开标注。

---

## 1. 来源与归属

- **Apple 原则**（字体尺度、语义色用途、对比度、控件状态）：来自 macos-ui-standards
  的 `standard.md` / `parameters.json`，本文不复制数值，只在「项目映射」列引用角色名。
- **项目自定度量**（具体色值、组件结构、页面模板）：本文定义，标注为「项目」。
  这些不是 Apple 统一规定，是为容器管理域选定的默认值。

---

## 2. 语义色 tokens

Apple 原则要求「成功/警示/错误/未知分别呈现」「颜色配文字或图标」。项目把容器/镜像/
项目状态映射到一组固定语义色。**禁止**在页面里直接写 `Color(0x...)` 或 `Colors.green`；
一律经 `GcmColors`（`lib/ui/colors.dart`）取用。

| token | 用途 | 浅色（项目值） | 深色（项目值） | 映射的 Apple 语义 |
| --- | --- | --- | --- | --- |
| `stateRunning` | 容器/运行时运行中 | `#1D7A34` | `#30D158` | 成功（systemGreen 系） |
| `stateStopped` | 已停止/已退出 | 次级文本灰（`outline`） | 同左 | secondary label |
| `stateTransition` | starting/stopping/deleting 等合成态 | `#8A6D00` | `#FFD60A` | 警示（systemYellow 系） |
| `stateFailed` | 失败/错误 | `colorScheme.error` | 同左 | 错误（systemRed 系） |
| `stateUnknown` | 未知/未上报 | `outline` | 同左 | secondary label |
| `destructive` | 删除/回收等破坏性操作按钮 | `colorScheme.error` | 同左 | 错误色 |
| `success` | 构建成功、操作完成 | `#1D7A34` | `#30D158` | 成功 |
| `textSecondary` | 辅助信息、label、时间 | `colorScheme.outline` | 同左 | secondary label |
| `surfaceCard` | 卡片/详情面板背景 | `surfaceContainerLowest` | 同左 | 内容层材质 |
| `surfaceSidebar` | 侧栏背景 | `surfaceContainerLow` | 同左 | 导航层材质 |

规则：
- 状态点（●）+ 文字标签成对出现，不单独用颜色传达状态（可访问性）。
- 破坏性操作默认按钮策略：回收/删除用 `destructive` 填充色，但**默认焦点在「取消」**。
- 对比度：正文 ≥ 4.5:1；状态文字在其背景上核验实际合成色。

## 3. 间距 / 圆角 / 卡片 tokens

项目默认值（Flutter logical pixels，与 parameters.json 对齐）：

| token | 值 | 用途 |
| --- | ---: | --- |
| `pagePadding` | 24 | 页面内边距 |
| `narrowPadding` | 16 | 窄内容区/卡片内边距 |
| `sectionGap` | 24 | 区域之间 |
| `controlGap` | 8 | 同行控件之间 |
| `relatedFieldGap` | 12 | 相关字段之间 |
| `cardRadius` | 12 | 内容容器/卡片圆角 |
| `controlRadius` | 8 | 自绘按钮/输入框圆角 |
| `cardPadding` | 16 | 卡片内边距 |
| `headerHeight` | 32 | 表头 |
| `rowHeightSingle` | ≥40 | 单行数据行 |
| `rowHeightDouble` | ≥56 | 双行数据行 |
| `sidebarWidth` | 224 | 侧栏宽（可调 200–280） |
| `dialogWidth` | 480 | 对话框 |

留白按 4 的倍数组织；区域间距 > 行内间距；同级内容对齐。

## 4. 字体 tokens

Apple 官方文本样式（数值见 standard.md），项目映射到 Flutter `TextTheme` 角色，
**用角色而非每处自定字号**：

| 场景 | Apple 样式 | Flutter 映射 |
| --- | --- | --- |
| 窗口/工具栏标题 | Title 2 (17) | `titleMedium` |
| 内容页主标题 | Title 1 (22) | `titleLarge` |
| 区域/卡片标题 | Title 3 (15) | `titleSmall` |
| 正文/名称 | Body (13) | `bodyMedium` |
| 辅助信息 | Callout (12) | `bodySmall` |
| 极次要（label 副行） | Footnote (10) | `labelSmall` |

- **标识值**（容器 id、镜像引用、路径、label、日志）用**系统等宽字体**：
  `monoTextStyle`（`lib/ui/text.dart`），中文回退保留。
- 长路径/标识省略后必须能查看全文（tooltip 或 CopyValue）。
- 保留系统字号变化与 200% 文本放大的可读性。

## 5. 组件清单（lib/ui/）

P0 交付的共享组件，API 小而稳（P1 详情页重做复用）：

| 组件 | 职责 | 关键 API |
| --- | --- | --- |
| `SectionCard` | 语义卡片：标题 + 内容区 + 可选操作行 | `title`, `child`, `actions?` |
| `CopyValue` | 标识值 + 悬浮 Copy 按钮 + 复制反馈 | `value`, `display?`, `mono=true` |
| `MaskedValue` | 敏感值默认打码 ⦿⦿⦿ + Show/Copy 切换 | `value`, `masked=true` |
| `StateDot` | 状态点（语义色 + 可访问标签） | `state`, `size=10` |
| `SidebarSection` | 侧栏分组标题 | `title` |
| `CountBadge` | 侧栏计数徽章 | `count`, `tone?` |

现有 `monoTextStyle`/`formatBytes`/`formatDuration`/`formatDateTime` 从
`containers_page.dart` 上移到 `lib/ui/text.dart`，全页面统一引用。

## 6. 页面模板

### 标准管理页（容器/镜像/挂载/网络/Compose/项目列表）
```
工具栏（页面标题 + 搜索 + 高频操作 + 刷新）
  └─ 表头（32 高，列名）
  └─ 数据行（单行≥40 / 双行≥56）
  └─ 空/加载/失败三态
```
高频动作在工具栏就地呈现；破坏性动作用 `destructive` 色。

### 详情面板（三列工作台内）
```
标题栏（返回 + 名称 + 标识 + 操作组）
  └─ SectionCard 组（镜像列表 / 成员容器 / 配置 / 回收报告…）
  └─ 底部日志/终端面板（可关闭）
```
卡片化组织，卡片间距 `sectionGap`，卡片内 `cardPadding`。

### 属性/运行弹窗
```
标题 → 按标签对齐字段（label 右对齐，值 mono）→ 就地提示 → 确认/取消（macOS 顺序）
```
宽 480，距窗口边缘 ≥24，高按可用空间滚动。

## 7. 侧栏信息架构（P0 分组）

224 宽侧栏按职责分三组，计数徽章显示活跃数：

- **工作**：容器（运行中数徽章）、项目、Compose 项目
- **资源**：镜像、挂载、网络
- **系统**：运行时、设置、MCP

分组标题用 `SidebarSection`，徽章用 `CountBadge`。MCP 当前是设置页内区块，
侧栏项保留入口（选中即跳设置页）。

---

## 8. 现状差距清单（对照 Orchard 模式）

走查 9 页（2026-10-24）发现的可验证差距，P0/P1 修复对照：

| # | 页面 | 差距 | 对照模式 | 严重度 |
| --- | --- | --- | --- | --- |
| G1 | 全局 | 主题仅 `colorSchemeSeed: blue`，无语义色 tokens；状态色硬编码 `0xFF1D7A34`/`Colors.green`/`errorContainer` 混用 | 语义色 tokens（§2） | P0 |
| G2 | 容器/挂载/网络 | 0 卡片，裸列表直接铺内容，无卡片组层次 | Orchard 卡片组 | P0 |
| G3 | 全局 | 无共享 `SectionCard`/`CopyValue`/`MaskedValue`；标识值不可一键复制 | 两列 label-value + Copy | P0 |
| G4 | 侧栏 | 9 项平铺无分组、无计数徽章 | 分组 + 徽章（§7） | P0 |
| G5 | 容器/项目 | 状态点色值散落各页，无统一 `StateDot` 语义 | 语义色 §2 | P0 |
| G6 | 镜像/设置 | 破坏性按钮色不统一（`error` vs `errorContainer`） | destructive token | P1 |
| G7 | 各页 | 辅助信息字号/颜色不统一（`outline` 用对但字号 10/11/12 混用） | 字体角色 §4 | P1 |
| G8 | 详情 | 配置/环境变量无明文/打码区分，敏感值裸显 | MaskedValue | P1 |
| G9 | 日志面板 | 无自动跟随滚动、无状态色标题 | 日志面板模板 | P1 |
| G10 | 空态 | 部分页空态无直接操作按钮 | 空态给直接操作 | P1 |

> 本清单随 P1 走查持续更新；每项修复后在对应页面验证记录截图。

---

## 9. 验收

1. 涉及页核对字体角色、语义色 token、间距 token、控件状态，记录例外。
2. 检查最小/常用窗口、长中文、长路径、键盘全流程、200% 文本放大。
3. 每个语义色核验正常/选中/禁用/错误及对比度。
4. 截图存 `docs/design-evidence/`（同尺寸同主题），记录运行版本。
