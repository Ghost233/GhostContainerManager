# 仓库代理指南

## 当前阶段

当前只建立基础配置、工程规范、SDK 接入说明和发布工具。功能开发须在后续任务中明确范围；配置文件和工具回归不表示容器管理能力已经实现或通过验收。

## GitHub 账号

本机 GitHub 操作使用 Ghost233。认证命令显式选择项目的 `GH_CONFIG_DIR`，清除 `GH_TOKEN`、`GITHUB_TOKEN` 覆盖后核验实际登录。账号配置见本机 `.codex/config.toml`；普通终端须显式设置账号目录。Git 远端操作还须核验实际凭据。账号切换只作用于项目账号目录。GitHub Actions 的发布步骤使用本仓库作用域的 `GITHUB_TOKEN`。

## Agent skills

### Issue 跟踪器

Issue 和规格保存在本仓库的 GitHub Issues 中。读写前参见 `docs/agents/issue-tracker.md`。

### 分类标签

分类使用五个默认角色的同名标签。分类前参见 `docs/agents/triage-labels.md`。

### 领域文档

领域文档采用单上下文布局。探索代码前参见 `docs/agents/domain.md`。

### 发布流程

正式发布或修改发布入口前，读取 `docs/agents/release.md` 和 `docs/release-versioning.md`。入口为 `scripts/release.sh`；仓库级 skill 位于 `.agents/skills/deploy-release/SKILL.md`。修改发布工具只完成编辑和验证。

## 工程规范

- 修改 Dart、Flutter、原生桥接或检查脚本前，读取 `docs/engineering.md`。
- 接入 MacLauncher 前，读取 `docs/integration/maclauncher-sdk.md`；固定 SDK 提交，只注册已实现的能力。
- 修改容器管理行为前，读取 `docs/project-scope.md`；运行时采用 Apple container。涉及原生 API 与 CLI 的具体分工，在对应开发任务中确认。
- 修改前定义可验证的成功标准。缺陷先复现；验证使用真实退出码并记录源码版本和检查范围。
- 提交或推送前，完成受影响的完整测试及仓库必需检查。当前尚无 Flutter 应用，不得把基础配置检查记为应用验收。
- Git 远端集成在当前本地分支完成，默认只作 fast-forward 同步。完成前核对工作区、本地与实际远端提交；保留用户未提交和未跟踪文件。
