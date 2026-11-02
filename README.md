# Ghost Container Manager

面向 macOS arm64 的 Docker 兼容容器管理工具。界面、MCP 和 MacLauncher 共用服务层；通过标准 Docker CLI 连接当前 context 或 `DOCKER_HOST`，编排使用 `docker compose`，不绑定底层引擎。

- [项目范围](docs/project-scope.md)
- [后端架构](docs/spec/architecture.md)
- [MCP 接入](docs/agents/mcp.md)与[工具契约](docs/spec/mcp-tools.md)
- [项目工作流与资源清理](docs/spec/project-workflow.md)
- [工程检查](docs/engineering.md)与[发布流程](docs/agents/release.md)

项目容器以 Compose 文件固定运行参数。复用工具链、依赖镜像和编译缓存，SDK 提前准备；最终镜像组装和启动时不下载 SDK。临时数据默认放在容器内，取回结果后随容器销毁。清理按项目生成计划，经 agent 确认后只执行获批范围。

```sh
export GCM_FLUTTER_SDK="$HOME/flutter"
export GCM_TEST_PYTHON="$(command -v python3.14)"
./scripts/test-host.sh prepare
./scripts/test-host.sh check
```

固定 Flutter 3.47.7、Dart 3.13.5；MacLauncher SDK 使用锁定的 Git 提交。发布仅在明确授权后执行，测试与构建不自动发布。
