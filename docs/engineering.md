# 工程规范

通用要求迁移自 GhostModelDeck，已按 Apple container 管理工具调整。适用于 Dart、Flutter、原生桥接和检查脚本。产品方向见 [项目说明](project-scope.md)，具体行为由后续确认的规格和工单确定。

## 编码与模块边界

| 规则 | 强度 | 要求与核验方式 |
| --- | --- | --- |
| E01 语言基线 | 必须 | 遵循 Effective Dart；使用 `dart format`，静态规则以根 `analysis_options.yaml` 为准。 |
| E02 类型与外部数据 | 必须 | 接口声明明确类型；在 I/O 边界校验 JSON、原生响应和 CLI 输出，再形成业务数据。 |
| E03 异步归属 | 必须 | 等待需要完成的工作；后台执行用 `unawaited` 表达，并处理错误、取消和晚到结果。 |
| E04 资源所有权 | 必须 | 进程、连接、订阅和临时文件有明确创建者与释放入口。操作用户既有资源须符合规格和明确请求。 |
| E05 界面边界 | 必须 | Widget 负责展示和交互；容器操作、状态观察及原生通信由业务模块承担。 |
| E06 共用业务入口 | 必须 | 桌面和 MacLauncher SDK 共用管理入口；原生桥接只作平台适配。 |
| E07 状态归属 | 必须 | 每种业务状态有一个权威来源。局部状态可用 `State`，共享状态使用现有 `Listenable` 或流。 |
| E08 依赖传入 | 建议 | 从组装入口通过构造参数传入依赖，由明确的所有者维护共享状态。 |
| E09 按职责拆分 | 建议 | UI 按页面或功能组织，业务与 I/O 按职责组织；按实际修改需要拆分文件。 |
| E10 增加抽象 | 按需 | 重复业务逻辑或实际替换需求出现后，再提取模块或接口。 |
| E11 性能措施 | 按需 | 先测量，再采用惰性列表、isolate 或重绘隔离，并在相同场景对比。 |
| E12 依赖变更 | 必须 | 说明用途和兼容性；联网解析依赖，保留 lockfile，Git 依赖固定完整提交。 |

## 工具链与平台

本仓库固定 Flutter **3.47.7**（`abaf9c523780a608bd46686fd5e53740a07077f8`）、Dart **3.13.5**。本机已核实该工具链，CI 使用同一版本。来源项目的 3.47.6 在本次迁移中提升至本机已安装版本。

产品基线为 macOS 26、Apple Silicon，只构建和提供 arm64 产物。原生 API、Apple container 版本及系统权限须在实现桥接时按实际能力核验。框架支持的最低系统版本不能代替产品运行时要求。

应用、App.framework 和 FlutterMacOS.framework 均核对实际 Mach-O 架构。构建使用命令级开关：

```sh
FLUTTER_MACOS_ARM64_ONLY=true "$GCM_FLUTTER_SDK/bin/flutter" build macos --release --no-pub
```

## 准备与检查

本机检查使用 macOS arm64 宿主机。应用管理 Apple container 不代表 Flutter 构建和测试需要容器；本次配置不创建或启动容器。

```sh
export GCM_FLUTTER_SDK="$HOME/flutter"
export GCM_TEST_PYTHON="$(command -v python3.14)"
./scripts/test-host.sh prepare
```

`prepare` 核对 SDK 提交、Flutter/Dart 版本、Python 和临时目录，联网执行 `pub get` 并记录证据。依赖清单变化后重新准备；lockfile 的变化须保留并审查。Python 要求 3.11 或更新版本。

应用初始化后，按改动运行定点检查。失败先修复首个原始错误，通过后检查受影响模块；提交和推送前完成受影响的完整测试及必需检查。

```sh
./scripts/test-host.sh test test/<受影响测试>.dart
./scripts/test-host.sh check
```

`check` 执行格式检查、分析和完整 Flutter 测试。当前基础配置阶段没有 `lib/` 和 `test/`，应用检查会停止并说明缺少应用工程。

## 脚本与完成证据

- 修改 shell 脚本后先执行 `bash -n`。发布工具通过 `python3 -B scripts/test_release.py` 回归；使用临时本地 Git 和测试包，不连接正式发布流程。
- 打包等有副作用的脚本使用受控输入完成实际干跑，核对产物。测试用的 `.app` 不计为产品构建。
- 记录源码 HEAD、待测内容指纹、命令、环境、日志和真实退出码。保留业务错误与清理错误；中断或超时不能记为通过。
- Flutter 测试同时核对进程退出码与标准成功完成标记。`format` 模式只检查格式；改写代码另行使用固定 Dart SDK。
- 原生桥接、真实容器操作和窗口交互各自验收。基础配置、替身测试和打包检查不能代替这些证据。

## 依据

- [Effective Dart](https://dart.dev/effective-dart)。
- [Flutter 架构建议](https://docs.flutter.dev/app-architecture/recommendations)。
- [flutter_lints](https://pub.dev/packages/flutter_lints)。
- [GitHub macOS runner 标签](https://github.com/actions/runner-images#available-images)：发布 workflow 固定使用 `macos-26`。
