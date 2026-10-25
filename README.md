# Ghost Container Manager

面向 Apple Silicon Mac 的 Apple container 管理工具，参考 [Orchard](https://github.com/andrew-waters/orchard)。当前处于基础配置阶段，尚未实现应用界面、原生桥接或容器管理功能。

## 基础配置

- [项目方向与待确认事项](docs/project-scope.md)。
- [Flutter 工程规范与工具链](docs/engineering.md)。
- [MacLauncher SDK 接入规范](docs/integration/maclauncher-sdk.md)。
- [发布流程](docs/agents/release.md)与[版本规则](docs/release-versioning.md)。

`pubspec.yaml` 固定 Flutter 3.47.7、Dart 3.13.5 和 MacLauncher SDK Git 提交。`version: 0.0.0` 是基础配置占位，正式版本由人另行确定。`maclauncher.json` 预留项目身份；服务列表为空，后续按实际实现填写。

## 当前可执行的检查

```sh
bash -n scripts/release.sh scripts/build-release.sh scripts/test-host.sh
python3 -B scripts/test_release.py
```

发布流程回归使用临时 Git 仓库和本地裸仓库。打包回归使用测试用的 arm64 程序与临时 DMG，不能代替 Flutter 应用构建或真实容器验收。

依赖与宿主机检查的准备方式见工程规范。当前没有 `lib/`、`test/` 和 `macos/` 应用工程，完整应用检查会明确停止。后续开发任务再初始化这些目录。实际检查结果见[基础配置验证](docs/verification/foundation.md)。

## 迁移来源

通用规范和发布工具迁移自本机 `GhostModelDeck`，来源提交为 `445b764e54d28647d834f491fe80420604b964aa`。本仓库使用独立的项目名称、bundle ID、GitHub 仓库和产物名称。
