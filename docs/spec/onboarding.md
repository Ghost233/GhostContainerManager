# Docker 连接检查

启动时先查找 Docker CLI，再读取 `docker version` 和 `docker info`。连接状态分为 `notInstalled`、`serviceNotRunning`、`ready`，不以固定引擎品牌或版本门槛判定。

CLI 缺失时展示安装与 context/DOCKER_HOST 配置说明，支持重新检查和跳过进入设置。端点不可达时保留主界面并显示连接诊断，提供重新检查。版本、资源数量来自端点真实响应；不相等的 CLI 和 Engine 版本本身不表示错误。

GCM 不安装内核，不修改引擎数据目录，不执行品牌专用启停命令。设置页说明外部连接配置；运行时页展示连接、版本、路径和资源计数。

为兼容已存在的 MCP 调用名，`system_start` 检查连接，端点不可达则返回明确错误；`system_stop` 返回不支持的说明，调用方使用引擎自己的管理入口。上述行为也适用于 UI 与启动器复用的服务层。
