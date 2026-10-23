"""Guard and push the manually selected GhostContainerManager release tag."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit


REPOSITORY = "Ghost233/GhostContainerManager"
ROOT = Path(__file__).resolve().parent.parent


class ReleaseError(Exception):
    pass


class Release:
    def __init__(self):
        self.env = os.environ.copy()
        self.token = None
        self.git_command = ["git"]

    def run(self, command, *, env=None, input_text=None):
        result = subprocess.run(command, cwd=ROOT, env=env or self.env,
                                input=input_text, capture_output=True, text=True)
        if result.returncode:
            message = result.stderr.strip() or "命令失败：" + command[0]
            if self.token:
                message = message.replace(self.token, "<REDACTED>")
            raise ReleaseError(message)
        return result.stdout.strip()

    def git(self, *args):
        return self.run(self.git_command + list(args))

    def check_account(self, env):
        switch_env = env.copy()
        switch_env.pop("GH_TOKEN", None)
        switch_env.pop("GITHUB_TOKEN", None)
        self.run(["gh", "auth", "switch", "--hostname", "github.com",
                  "--user", "Ghost233"], env=switch_env)
        login = self.run(["gh", "api", "--hostname", "github.com", "user",
                          "--jq", ".login"], env=env)
        if login != "Ghost233":
            raise ReleaseError("有效 GitHub 身份必须是 Ghost233")

    def authenticate_git(self):
        if not self.env.get("GH_CONFIG_DIR"):
            raise ReleaseError("请先加载本仓库的 GH_CONFIG_DIR；发布不切换默认 gh 账号")
        self.check_account(self.env)
        self.git_command = ["git", "-c", "credential.https://github.com.helper=",
                            "-c", "credential.https://github.com.helper=!gh auth git-credential"]
        self.env["GIT_TERMINAL_PROMPT"] = "0"
        wire = self.run(self.git_command + ["credential", "fill"], input_text=
                        "protocol=https\nhost=github.com\npath=Ghost233/GhostContainerManager.git\n\n")
        credential = dict(line.split("=", 1) for line in wire.splitlines() if "=" in line)
        self.token = credential.get("password")
        if not self.token:
            raise ReleaseError("无法核验实际 Git 凭据")
        self.env.pop("GITHUB_TOKEN", None)
        self.env["GH_TOKEN"] = self.token
        self.check_account(self.env)

    def prepare(self, retry):
        pubspec = (ROOT / "pubspec.yaml").read_text()
        if not re.search(r"^name:\s*ghost_container_manager\s*$", pubspec, re.M):
            raise ReleaseError("当前工作区不是 GhostContainerManager")
        versions = re.findall(r"^version:\s*([^\s#]+)\s*$", pubspec, re.M)
        if len(versions) != 1 or not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.([0-9])", versions[0]):
            raise ReleaseError("pubspec.yaml 必须使用无 +build 的 x.y.z 版本，patch 为 0–9")
        version = versions[0]
        if version == "0.0.0":
            raise ReleaseError("0.0.0 是基础配置占位；由人确定正式版本后再发布")
        if self.git("rev-parse", "--show-toplevel") != str(ROOT):
            raise ReleaseError("发布脚本必须位于 GhostContainerManager 仓库根下")
        if self.git("symbolic-ref", "--short", "HEAD") != "main":
            raise ReleaseError("必须在 main 分支执行")
        if self.git("status", "--porcelain"):
            raise ReleaseError("工作树不干净；先审查并提交改动，不自动 stash 或覆盖文件")
        origin = urlsplit(self.git("remote", "get-url", "origin"))
        if (origin.scheme != "https" or origin.hostname != "github.com"
                or origin.path.rstrip("/").removesuffix(".git") != "/" + REPOSITORY
                or origin.password is not None):
            raise ReleaseError("origin 必须是 Ghost233/GhostContainerManager 的 HTTPS 地址")
        self.authenticate_git()
        head = self.git("rev-parse", "HEAD")
        remote_heads = self.git("ls-remote", "origin", "refs/heads/main").splitlines()
        if len(remote_heads) != 1 or remote_heads[0].split()[0] != head:
            raise ReleaseError("本地 main 与实际远端不同，先 fast-forward 同步再发版")
        if self.git("rev-parse", "origin/main") != head:
            raise ReleaseError("origin/main 缓存过期，先 git fetch origin main")
        tag = "v" + version
        remote_tags = self.git("ls-remote", "--tags", "origin")
        tags = {line.split()[1]: line.split()[0] for line in remote_tags.splitlines()}
        if "refs/tags/" + tag in tags:
            raise ReleaseError(f"{tag} 已推送；跟踪既有 release.yml，不重用版本或重推 tag")
        published_versions = [tuple(map(int, name[11:].split("."))) for name in tags
                              if re.fullmatch(r"refs/tags/v\d+\.\d+\.\d+", name)]
        if published_versions and tuple(map(int, version.split("."))) <= max(published_versions):
            raise ReleaseError("版本必须高于已发布 tag；按 docs/release-versioning.md 手动修改")
        local_tags = self.git("tag", "--list", tag).splitlines()
        if local_tags:
            if not retry:
                raise ReleaseError(f"本地 {tag} 已存在；若是上次 push 失败，用 --retry-tag")
            if self.git("rev-parse", "--verify", tag + "^{commit}") != head:
                raise ReleaseError("本地 tag 未指向当前 main，不移动或重建 tag")
        elif retry:
            raise ReleaseError("--retry-tag 仅用于重试已存在的本地 tag")
        print(f"release: 仓库：{REPOSITORY}\nrelease: 版本：{version}\nrelease: 发布 tag：{tag}")
        print(f"release: 提交：{head}")
        return tag, head, bool(local_tags)

    def publish(self, tag, head, local_tag):
        if not local_tag:
            self.git("tag", "-a", tag, head, "-m", "GhostContainerManager " + tag)
        try:
            self.git("push", "origin", "refs/tags/" + tag)
        except ReleaseError as error:
            raise ReleaseError(f"{error}\n本地 tag 已保留。先核对远端；若未推送，使用 scripts/release.sh --retry-tag") from error
        actual = self.git("ls-remote", "origin", "refs/tags/" + tag + "^{}")
        if not actual or actual.split()[0] != head:
            raise ReleaseError("远端 tag 提交核验失败；停止并核对，不移动 tag")
        main = self.git("ls-remote", "origin", "refs/heads/main")
        if not main or main.split()[0] != head:
            raise ReleaseError("tag 已推送，但远端 main 已变化；先 fast-forward 同步本地，再跟踪既有管线")
        print(f"release: 完成：{tag} 已推送")
        print(f"release: 跟踪：gh run list -R {REPOSITORY} --workflow release.yml --commit {head}")


def main():
    parser = argparse.ArgumentParser(description="发布 GhostContainerManager 当前手动版本；不 bump、不提交、不推 main")
    parser.add_argument("--dry-run", action="store_true", help="只检查和显示计划，不创建或推送 tag")
    parser.add_argument("--retry-tag", action="store_true", help="重试尚未推送且指向当前 main 的本地 tag")
    args = parser.parse_args()
    release = Release()
    try:
        tag, head, local_tag = release.prepare(args.retry_tag)
        if args.dry_run:
            print("release: [dry-run] " + ("复用本地 tag" if local_tag else "创建附注 tag") + f" {tag}")
            print(f"release: [dry-run] 推送 {tag}，触发 GhostContainerManager release.yml 构建 DMG 与两份清单")
        else:
            release.publish(tag, head, local_tag)
    except (ReleaseError, OSError) as error:
        print("release: 错误：" + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
