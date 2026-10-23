# GhostContainerManager 标准发布流程

当前仓库处于基础配置阶段，尚无可发布的 Flutter 应用。先由人确定正式版本、完成应用和本地门禁，再使用以下流程。

仅在用户明确要求正式发布时执行 `scripts/release.sh`。编辑发布 skill、脚本或 workflow 只完成编辑与验证。版本规则的唯一来源是 [发布版本号规则](../release-versioning.md)。

## 发布前

只构建和提供 macOS arm64（Apple Silicon）应用及运行时。不提供 Intel/x64、Linux、Windows 或通用双架构包。`build-release.sh` 强制 ARM-only 构建，并对主程序、App.framework 和 FlutterMacOS.framework 验证实际架构；预构建包同样接受这一检查。

1. 由人手动确定并修改根 `pubspec.yaml` 的版本，按规则递增；不带 `+build`。完成对应改动的本地门禁、Mac 构建和发布包预检，再提交并合入 main。
2. 当前工作区切到 main，保留并妥善处理用户未提交文件。只采用 fast-forward 同步，本地 main、origin/main 与实际远端必须相同。脚本不会 stash、提交、切换分支、bump 或推送 main。
3. 显式设置本仓库的 `GH_CONFIG_DIR`，GitHub 业务身份和实际 Git 凭据均为 Ghost233。脚本核验 HTTPS origin 为 Ghost233/GhostContainerManager，并为每次 Git 远端调用使用已核验的 gh credential helper；不修改其他账号的凭据。

## 入口

```sh
GH_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gh-profiles/Ghost233" scripts/release.sh --dry-run
GH_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gh-profiles/Ghost233" scripts/release.sh
```

空跑显示仓库、已手动选定的版本、tag 与完整 main 提交，不创建或推送 tag、不改工作区文件、不 fetch。身份切换仅用于仓库账号护栏。

正式执行为当前 main 创建附注 `vX.Y.Z` tag 并推送，随后验证实际远端 tag 提交。tag 触发 [release.yml](../../.github/workflows/release.yml)，由现有 [build-release.sh](../../scripts/build-release.sh) 生成 `GhostContainerManager-X.Y.Z.dmg`、`manifest.json`、`SHA256SUMS`。普通 push 到 main 不再触发正式发布。

脚本输出「完成：vX.Y.Z 已推送」代表受理，不代表 DMG 已发布。

## 失败恢复

| 失败点 | 保留状态与下一动作 |
| --- | --- |
| 分支、工作树、账号、版本或同步检查 | 不创建 tag。按错误解决；不自动暂存或覆盖用户文件。 |
| tag push 失败 | 本地 tag 保留。先核对远端是否已有 tag；若没有，运行 `scripts/release.sh --dry-run --retry-tag`、再运行 `scripts/release.sh --retry-tag`。只重推指向当前 main 的同一 tag，不移动 tag、不再次 bump。 |
| tag 已在远端 | 不重新推送或创建版本，跟踪该提交的既有管线。 |
| workflow 构建失败，尚无正式资产 | 定位原错误，在本地完成对应验证。输入未变的临时故障可重跑原 run；代码修复使用下一个手动版本，保留原失败。 |
| Release 创建失败或资产不完整 | 先核对已有 Release/资产，不能把管线重试或 exit 0 当成完整发布；不覆盖同版本 DMG。按版本文档撤回并作废该版本，再发布下一个版本。 |

## 完成验证

发布完成以 GitHub Actions 和 GitHub Release 的远端证据为准。发布前的本地门禁、Mac 构建和打包预检仍按“发布前”执行。

本机认证 gh 命令显式选择项目账号目录，按 AGENTS.md 核验 Ghost233；业务命令显式指定本仓库。CI 发布使用本仓库作用域的 `GITHUB_TOKEN`。

```sh
gh run list -R Ghost233/GhostContainerManager --workflow release.yml --commit <发布提交>
gh run watch <run-id> -R Ghost233/GhostContainerManager --exit-status
gh release view vX.Y.Z -R Ghost233/GhostContainerManager --json tagName,isDraft,isPrerelease,assets,url
```

完成前核对：

- Actions：选择发布 tag 和完整提交对应的 `release.yml` run，确认已完成且结论为 `success`。
- Release：对应版本已正式发布，非草稿、非预发布，tag 与发布提交中根 `pubspec.yaml` 的版本一致。
- 远端资产：Release 列表含 `GhostContainerManager-<版本>.dmg`、`manifest.json` 和 `SHA256SUMS`，大小均大于零。应用版本与 arm64 架构检查、清单生成以成功的 Actions 构建记录为依据。
- Git 同步：本地 main、origin/main 与实际远端 main 一致；本地 tag 与实际远端 tag 指向同一发布提交。

以上条件满足即完成发布，报告版本、发布提交、Release 和 Actions 链接。网络瞬态故障重试同一读取，不创建第二次发布；失败或缺少证据时保持未完成。

发布后默认只读取远端状态和资产元数据。下载资产到本地、重新计算哈希、安装或运行应用，仅在用户另行明确要求时执行，不作为默认发布完成条件。

本地流程回归：`python3 -B scripts/test_release.py` 使用临时 Git 仓库与本地裸仓库，在外部 Git/gh CLI 接缝模拟身份；不访问 GitHub，不发正式版。Shell 入口需通过 `bash -n scripts/release.sh scripts/build-release.sh`。真实包预检可用 `scripts/build-release.sh --app-path <本次已构建的.app> --output-dir .tooling/release-precheck`，只产出忽略的本地文件，避免覆盖既有 dist。
