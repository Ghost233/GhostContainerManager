# 基础配置验证

验证日期：2026-10-23。当前仅完成工程与发布基础配置，尚未开始功能开发。

## 输入版本

- 当前仓库 HEAD：`e4255d92f1f2d2eb228f19cd35c19094d18d65a2`。本次验证覆盖其上的未提交配置和脚本，HEAD 本身不包含这些新增文件。
- GhostModelDeck 来源提交：`445b764e54d28647d834f491fe80420604b964aa`。只迁移选定的通用配置与工具。
- Flutter 3.47.7：`abaf9c523780a608bd46686fd5e53740a07077f8`；Dart 3.13.5；macOS arm64 宿主机。
- MacLauncher SDK：`268f88ef5ff47dbafe88200d5cddd090983ad313`，依赖声明和 lockfile 的 resolved-ref 一致。

## 实际结果

| 检查 | 退出码与结果 |
| --- | --- |
| `bash -n scripts/release.sh scripts/build-release.sh scripts/test-host.sh` | 0，语法通过。 |
| `scripts/test-host.sh prepare` | 0，在线解析依赖，生成 lockfile，记录 SDK、Python、源码和依赖指纹。 |
| `python3 -B scripts/test_release.py` | 0，12 项通过，包含本地 Git 发布保护与临时 arm64 DMG 打包。 |
| `skill-creator/scripts/quick_validate.py .agents/skills/deploy-release` | 0，skill 格式通过；验证器的 PyYAML 6.0.3 安装在任务临时目录。 |
| YAML、workflow 内 shell、文档相对引用和 Python 语法检查 | 0。SDK 锁定、账号目录保护和 skill 显式调用策略也已核对。 |
| Flutter 测试报告校验器 | 4 个输入场景符合预期：成功、进程失败、报告失败和缺少完成标记。 |
| `scripts/test-host.sh check` | 1，明确报告尚无 `lib/` 和 `test/`；应用检查未执行。 |
| `git diff --check` | 0。新增文档另行核对换行、行尾空白和引用。 |

宿主机准备使用 `GCM_FLUTTER_SDK=/Users/ghost233/flutter` 和 `GCM_TEST_PYTHON=/opt/homebrew/bin/python3.14`。完整准备记录位于忽略的 `.tooling/host-tests/run-ckLc3h/`。

首次临时 DMG 检查在沙箱内退出 1，原始错误为 `hdiutil: create failed - 设备未配置`。允许系统磁盘映像设备后，同一定点检查退出 0，完整回归随后也退出 0。原失败按环境限制记录。

## 验证边界

DMG 检查使用编译出的测试程序和临时框架路径，只核对打包、架构保护、manifest 与校验和。它不是 Flutter 应用构建。

本次没有初始化 `lib/`、`test/` 或 `macos/` 应用工程，没有执行容器管理、SDK 业务联调或正式 Release。上述能力在后续开发任务中按规格实现和验收。
