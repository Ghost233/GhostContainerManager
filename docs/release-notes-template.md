# Ghost Container Manager {{VERSION}}

发布 tag：`{{TAG}}`。

## 安装

下载本 Release 的 `GhostContainerManager-{{VERSION}}.dmg`，打开后将应用拖入 Applications。

运行环境为 macOS 26 或更新版本、Apple Silicon，以及已安装的 Apple container 运行时。

当前打包流程未配置开发者证书签名和公证。正式分发方式以本次发布说明为准。

## 运行时数据目录

应用支持设置 Apple container 的运行时数据目录。更改目录不会迁移已有数据。
部分外置磁盘环境下，Apple container 可能无法启动；本次外置盘启动尚未通过实机验收。

## 完整性

同一 Release 提供 `manifest.json` 和 `SHA256SUMS`。下载到同一目录后运行 `shasum -a 256 -c SHA256SUMS`。
