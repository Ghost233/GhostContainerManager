# Docker 后端迁移验证

生产后端使用标准 Docker CLI 与 Docker Compose；共享服务层、项目资源登记、依赖复用及获批清理规则保留。旧平台桥接插件和对应原生依赖已移除。

真实端点验证使用独立 Compose 项目及本机已有工具链镜像，不下载依赖或 SDK，不挂载宿主测试目录。已验证 Compose config/up/down、容器 inspect、exec 双流和非零退出码、统计、镜像内容 ID，以及运行中保留、停止后计划和获批删除。临时资源已清理。

测试记录位于 `.tooling/host-tests/`；完整验收以最终候选的测试、分析和构建真实退出结果为准，旧批次的成功结果不替代本轮验证。

## 本轮验证结果

- 工作区完整 Flutter 测试：425 项通过，日志 `.tooling/host-tests/run-4RHs8M/test.log`。
- 格式：114 个文件，无需改写；全仓 `dart analyze --fatal-infos` 通过。
- macOS arm64 调试应用在独立 DerivedData 目录构建成功；未安装或发布。
- 真实 Docker/Compose 验证覆盖配置、后台启动、inspect、exec 双流与退出码、统计、空间查询和获批清理；测试资源已清理。
- 发布工具回归：12 项通过。

组合检查中的 `flutter analyze` 因固定 SDK 的 LSP initialize 消息在中文路径下截断而退出 255；该项未记为通过，改用同一 SDK 的严格 Dart 分析完成检查，未修改 SDK。
