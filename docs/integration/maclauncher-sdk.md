# MacLauncher SDK 接入规范

沿用 GhostModelDeck 的 Git 依赖方式，由根 `pubspec.yaml` 和 `pubspec.lock` 固定实际版本。当前提交为 `268f88ef5ff47dbafe88200d5cddd090983ad313`，包路径为 `packages/maclauncher_sdk`。本仓库尚未实现 SDK 业务接入。

## 项目身份与能力

项目 ID 为 `com.ghost233.ghostcontainermanager`，显示名为 `GhostContainerManager`。`maclauncher.json` 的入口预留为发布 `.app` 路径，当前文件尚不存在。服务列表为空，服务粒度在开发任务中确定。

只为已实现的能力注册 `ServiceCallbacks`。当前固定版本支持 `onStart`、`onRecycle`、`onStatus` 和 `onLogs`；应用级 `AppCallbacks` 支持窗口、入口接管和版本查询。能力由实际回调决定。

## 生命周期与业务边界

- SDK 负责通信、重连和入口协作；容器操作与资源回收由本应用的管理入口负责。`dispose()` 关闭通信并归还入口。
- 桌面和 SDK 的操作共用状态、并发控制和资源所有权。单个 SDK 回调不能形成第二套容器管理逻辑。
- 启动器未运行时，应用应能独立工作。断连、启动器退出和应用退出分别处理。
- 运行时发现使用 `projectName` 和 `SdkEntry.currentAppBundle() ?? SdkEntry.currentExecutable()`。`pending-approval` 表示等待用户批准，保留重试并控制日志频率。
- 状态与日志报告实际观测结果。命令受理、连接成功和业务就绪分别表达；查询失败保留错误原因。
- 容器、镜像及用户已有资源的停止和删除策略由规格确定。后续再定义 `recycle` 的业务含义。

## 接入验收

开发阶段至少验证固定依赖可构建、应用独立运行、批准与重连、窗口与入口恢复、真实状态、错误和取消、重复操作，以及 SDK 断开后的资源行为。当前只检查依赖与配置，不宣称这些行为已经通过。

## 固定源码

- [SDK 公共接口](https://github.com/Ghost233/MacLauncher/blob/268f88ef5ff47dbafe88200d5cddd090983ad313/packages/maclauncher_sdk/lib/src/client.dart)。
- [入口自报](https://github.com/Ghost233/MacLauncher/blob/268f88ef5ff47dbafe88200d5cddd090983ad313/packages/maclauncher_sdk/lib/src/entry_report.dart)。

升级 SDK 时同时更新固定 ref、lockfile 和受影响的验收。来源项目较早版本的研究与测试记录只作历史参考。
