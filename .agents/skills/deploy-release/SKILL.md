---
name: deploy-release
description: 发布 GhostContainerManager 正式版，核验手动版本和 Ghost233 身份，推送发布 tag 并跟踪 DMG 管线。仅在用户明确要求正式发布时使用；编辑此流程不触发发布。
---

# deploy-release

发布 GhostContainerManager 正式版。执行前读取 `docs/agents/release.md` 与 `docs/release-versioning.md`。唯一执行入口是 `scripts/release.sh`；版本选择、失败恢复和完成条件以这两份文档为准。

## 步骤

1. 确认工作区是 Ghost233/GhostContainerManager，且用户明确要求正式发布。沿用已有授权；编辑 skill 或脚本只完成编辑与验证。
2. 按版本规则由人手动确定 `pubspec.yaml` 的版本，完成相关本地门禁，并将已审查的发布内容合入 main、同步本地。脚本不自动 bump，也不提交未完成的改动。
3. 运行 `scripts/release.sh --dry-run`，展示当前版本、tag 与完整提交。检查通过后，在明确发布授权内执行 `scripts/release.sh`；失败按发布文档恢复，保留原错误。
4. 脚本输出「完成：vX.Y.Z 已推送」只代表发布受理。按脚本给出的 commit 跟踪对应 release.yml：

   ```sh
   gh run list -R Ghost233/GhostContainerManager --workflow release.yml --commit <发布提交>
   ```

5. 按仓库 Ghost233 护栏核验每个认证命令，依照 `docs/agents/release.md` 的“完成验证”核对远端发布结果。通过后给出 Release 与 Actions 链接并结束发布；缺少远端证据时保持未完成。发布后的本地资产下载、哈希校验、安装和运行仅在用户另行明确要求时执行。
