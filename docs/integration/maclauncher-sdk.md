# MacLauncher SDK 接入

根 `pubspec.yaml` 与 `pubspec.lock` 固定 SDK 提交 `268f88ef5ff47dbafe88200d5cddd090983ad313`，包路径为 `packages/maclauncher_sdk`。当前固定版本已支持窗口与版本回调，本次接入不升级依赖。

## 能力与边界

项目身份为 `com.ghost233.ghostcontainermanager`。`MacLauncherBridge` 将带 `com.ghost233.*` 标签的容器注册为服务；启动、重启、状态和日志都复用 `ContainerService`。

应用级注册两个回调：

- `onOpenWindow`：调用同一原生窗口入口，恢复普通激活策略、Dock 图标并显示主窗口。菜单栏操作、Finder 重开和 Launcher 打开窗口使用相同行为。
- `onVersionStatus`：调用 `AppUpdateService` 查询本项目 GitHub 最新正式 Release，返回当前版本、最新版本、是否可更新、匹配版本的 DMG 地址和 SHA-256。优先使用资产 digest，缺失时读取版本、文件名和大小一致的 manifest。失败回报 failure 与原始原因，不伪造“没有更新”。并发查询复用在途请求，失败后可重试。

下载与打开更新包由 Launcher 完成，安装沿用 Launcher 的用户手动替换流程。SDK 本身不下载、不替换应用，也不发布版本。本地试用包尚未发布的变更不会成为 Release 更新；开发构建没有可比较版本时如实返回查询失败。

菜单栏由本应用维护；本次不注册入口接管回调。关闭主窗口隐藏 Dock，保留菜单栏恢复入口；重新打开时恢复用户原有菜单栏显示设置。关闭窗口、SDK 断连、应用退出与业务容器停止分别处理。

## 验证

更新源解析、版本比较、清单一致性、失败与并发重试由单元测试覆盖；SDK 窗口和版本回调由接入测试覆盖。真实 AppKit 测试验证关闭窗口后 Dock 隐藏、菜单栏保留，以及重新打开恢复。Launcher 未运行或未批准关联时，应用继续独立运行，SDK 保持原有重试策略。

SDK 契约见固定提交中的 `AppCallbacks`、`VersionStatus`；Launcher 下载与安装边界见其 `docs/adr/0002-updates-stop-at-the-door.md`。
