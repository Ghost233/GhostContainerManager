# 发布版本号规则

本文件是 GhostContainerManager 的版本发布约定。当前 `0.0.0` 仅作基础配置占位，发布和打包入口均拒绝该版本；首个正式版本由人确定。

## 版本权威

版本号取自根 `pubspec.yaml` 的 `version:`，使用不带 `+build` 的 `x.y.z`。构建号由 CI 的 `github.run_number` 注入。应用内版本在开发时读取打包信息。

版本由人手动修改。CI 和脚本只校验版本，不推导、不 bump、不替用户提交。

## 递增规则

沿用来源项目的 patch 进位约定：`z` 为 0 至 9，每次普通发布加 1。`0.1.9` 的下一版为 `0.2.0`；`0.9.9` 的下一版为 `0.10.0`。minor 不作二次进位，major 的变更由人另行确定。

tag 为 `v<x.y.z>`，必须与 `pubspec.yaml` 严格一致。新版本高于已有发布 tag，版本号不得重用或对应不同的发布资产。

## 发布与恢复

1. 手动确定版本，完成对应本地门禁、真实 Mac 构建和包预检，审查后合入并同步本地 main。
2. 只有用户明确要求正式发布时，才执行 `scripts/release.sh --dry-run`，核对版本与完整提交，再执行正式入口。
3. 脚本只创建和推送附注 tag。普通 main push 不发布，tag 触发 `.github/workflows/release.yml`。
4. 按[发布流程](agents/release.md)核对 Actions、正式 Release、资产及本地和远端 refs。

push 失败时保留本地 tag，核对远端后只重试同一提交。版本已正式发布后发生错误，先明确授权撤回对应 Release 和 tag，将版本作废，再使用下一个手动版本；不覆盖原版本资产。

## 构建约定

CI 使用 `macos-26` 和固定 Flutter 3.47.7。tag 提交须属于 main 历史。只提供 macOS arm64；校验 bundle ID、应用版本、主程序及两份框架的实际架构。

资产为 `GhostContainerManager-<版本>.dmg`、`manifest.json` 和 `SHA256SUMS`。打包入口支持 `--app-path`，用于已有 `.app` 的本地预检。当前脚本沿用未签名、未公证的分发方式；正式分发要求在发布任务中确认。
