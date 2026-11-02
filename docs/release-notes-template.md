# Ghost Container Manager {{VERSION}}

发布 tag：`{{TAG}}`。

## 更新内容

- 后端统一使用 Docker 兼容接口与标准 Docker Compose，保留依赖复用与按项目确认清理的规则。
- 关闭主窗口后隐藏 Dock、保留菜单栏；从菜单栏、Finder 或 Launcher 重新打开时恢复 Dock。
- 接入 MacLauncher SDK 的窗口与版本查询回调，提供更新包地址及 SHA-256；Docker 离线时也可打开窗口和检查更新。

## 安装

下载本 Release 的 `GhostContainerManager-{{VERSION}}.dmg`，打开后将应用拖入 Applications。

运行环境为 macOS 26 或更新版本、Apple Silicon，以及已安装的 Docker 兼容端点。

当前打包流程未配置开发者证书签名和公证。正式分发方式以本次发布说明为准。

## Docker 连接

沿用当前 Docker context、DOCKER_HOST、TLS 和凭据配置，不绑定底层引擎。引擎启停与数据目录由引擎自身管理。

## 完整性

同一 Release 提供 `manifest.json` 和 `SHA256SUMS`。下载到同一目录后运行 `shasum -a 256 -c SHA256SUMS`。
