# Docker 请求终止确认：可行性核查

本文记录对现有设计的有限核查，不代表实现或完整的 Docker 兼容运行时保证。源码观察固定在 Moby v27.5.1，不推论其他版本或引擎具有相同行为。

## 一手证据

- Moby v27.5.1 的容器 [create 路由](https://github.com/moby/moby/blob/v27.5.1/api/server/router/container/container_routes.go#L667-L679)先调用后端创建，成功返回后才写入 HTTP 201 与结果；[start 路由](https://github.com/moby/moby/blob/v27.5.1/api/server/router/container/container_routes.go#L199-L224)先调用后端启动，成功返回后才写入 HTTP 204。因此响应丢失不能区分请求尚未完成与副作用已发生但响应未送达。
- 该版本的 [start 实现](https://github.com/moby/moby/blob/v27.5.1/daemon/start.go#L209-L239)对创建和启动 task 使用 `context.WithoutCancel`。至少在此实现中，不能假定客户端取消或连接断开会撤销、终止整个启动操作。该观察不是其他引擎的协议承诺。
- 本仓库 [运行时桥接](../lib/bridge/docker_container_bridge.dart)在身份查询命令超时后终止本地 CLI；这不是引擎侧终止证明。[身份查询](../lib/services/container_runtime_identity.dart)也明确说明完整查询无法排除并发变更或仍在途的创建。现有接缝没有已验证的、跨应用重启的引擎请求终态查询。

## 结论和未验证项

现有证据支持继续采用未知即待核对；不支持把 CLI 退出、响应丢失或一次查询作为终止证明。没有发现或验证可直接用于当前适配器的持久操作终态协议，但这不是对所有 Docker 兼容实现的穷举证明。独立执行进程可在它存活并可靠保存完整响应时覆盖应用单独退出，不能证明执行进程或主机在引擎副作用与结果落盘之间崩溃后的结果。

[设计提案](container-request-completion-design.md)列出所需协议、保守退路及验证范围。尚未执行真实在途故障注入，也未证明进程崩溃或断电下的持久性；因此不能以本核查宣布 [#61](https://github.com/Ghost233/GhostContainerManager/issues/61) 自动恢复可用。
