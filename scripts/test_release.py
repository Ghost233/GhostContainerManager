"""Exercise the release CLI using real local Git refs and fake external auth."""

import os
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parent
REAL_GIT = shutil.which("git")


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ghostcontainermanager-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "workspace"
        self.remote = self.root / "origin.git"
        self.repo.mkdir()
        (self.repo / "scripts").mkdir()
        for name in ("release.sh", "release.py"):
            shutil.copy2(SOURCE / name, self.repo / "scripts" / name)
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Fixture")
        self.git("config", "user.email", "release@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.git("remote", "add", "origin", str(self.remote))
        self.pubspec = self.repo / "pubspec.yaml"
        self.version("0.1.2")
        self.git("add", ".")
        self.git("commit", "-m", "baseline")
        self.git("tag", "-a", "v0.1.2", "-m", "baseline")
        self.git("push", "origin", "main", "v0.1.2")
        self.version("0.1.3")
        self.git("add", "pubspec.yaml")
        self.git("commit", "-m", "manual version")
        self.git("push", "origin", "main")
        self.git("remote", "set-url", "origin", "https://github.com/Ghost233/GhostContainerManager.git")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.wrapper("git", '''import os,sys,subprocess
a=sys.argv[1:]
while a[:1]==['-c']: a=a[2:]
if a==['credential','fill']:
 print('protocol=https\\nhost=github.com\\nusername=Ghost233\\npassword='+os.environ.get('FIXTURE_GIT_TOKEN','fixture-ghost'))
 sys.exit(0)
if a[:1] in (['ls-remote'],['push'],['fetch']):
 a=[os.environ['FIXTURE_REMOTE'] if x=='origin' else x for x in a]
 if a[:1]==['push'] and os.environ.get('FIXTURE_PUSH_FAIL')=='1':
  print('fixture tag push failure',file=sys.stderr);sys.exit(1)
sys.exit(subprocess.call([os.environ['FIXTURE_REAL_GIT']]+a))
''')
        self.wrapper("gh", '''import os,sys
if sys.argv[1:3]==['auth','switch']:sys.exit(0)
if sys.argv[1:2]==['api']:
 print('OtherAccount' if os.environ.get('GH_TOKEN')=='fixture-other' else 'Ghost233');sys.exit(0)
print('unexpected gh operation',file=sys.stderr);sys.exit(2)
''')
        self.env = os.environ.copy()
        self.env.pop("GH_TOKEN", None)
        self.env.pop("GITHUB_TOKEN", None)
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"],
                        FIXTURE_REMOTE=str(self.remote), FIXTURE_REAL_GIT=REAL_GIT,
                        GH_CONFIG_DIR=str(self.root / "gh"))

    def wrapper(self, name, source):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + source)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.run([REAL_GIT, *args], cwd=self.repo, check=True,
                              capture_output=True, text=True).stdout.strip()

    def version(self, value):
        self.pubspec.write_text(f"name: ghost_container_manager\nversion: {value}\n")

    def cli(self, *args, extra_env=None):
        env = self.env.copy()
        env.update(extra_env or {})
        return subprocess.run(["bash", str(self.repo / "scripts/release.sh"), *args],
                              cwd=self.root, env=env, capture_output=True, text=True,
                              timeout=20)

    def snapshot(self):
        return (self.pubspec.read_bytes(), self.git("rev-parse", "HEAD"),
                self.git("show-ref"), self.git("status", "--porcelain"),
                self.git("ls-remote", str(self.remote)))

    def test_dry_run_is_read_only_and_uses_manual_version(self):
        before = self.snapshot()
        result = self.cli("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("发布 tag：v0.1.3", result.stdout)
        self.assertNotIn("下一版本", result.stdout)
        self.assertEqual(self.snapshot(), before)

    def test_publish_pushes_exact_tag_without_changing_main_or_pubspec(self):
        before = self.snapshot()[:2]
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("完成：v0.1.3 已推送", result.stdout)
        self.assertEqual(self.snapshot()[:2], before)
        actual = self.git("ls-remote", str(self.remote), "refs/tags/v0.1.3^{}")
        self.assertEqual(actual.split()[0], before[1])

    def test_push_failure_keeps_tag_for_exact_retry(self):
        result = self.cli(extra_env={"FIXTURE_PUSH_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--retry-tag", result.stderr)
        head = self.git("rev-parse", "HEAD")
        self.assertEqual(self.git("rev-parse", "v0.1.3^{commit}"), head)
        self.assertNotEqual(self.cli("--dry-run").returncode, 0)
        self.assertEqual(self.cli("--dry-run", "--retry-tag").returncode, 0)
        self.assertEqual(self.cli("--retry-tag").returncode, 0)

    def test_wrong_effective_account_and_git_credential_are_rejected(self):
        for env in ({"GH_TOKEN": "fixture-other"}, {"FIXTURE_GIT_TOKEN": "fixture-other"}):
            with self.subTest(env=env):
                before = self.snapshot()
                result = self.cli("--dry-run", extra_env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Ghost233", result.stderr)
                self.assertNotIn("fixture-other", result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_missing_profile_is_rejected_without_changing_refs(self):
        before = self.snapshot()
        result = self.cli("--dry-run", extra_env={"GH_CONFIG_DIR": ""})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GH_CONFIG_DIR", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_dirty_feature_and_wrong_origin_are_rejected(self):
        (self.repo / "untracked.txt").write_text("preserve me")
        self.assertIn("不干净", self.cli("--dry-run").stderr)
        (self.repo / "untracked.txt").unlink()
        self.git("checkout", "-b", "feature")
        self.assertIn("main", self.cli("--dry-run").stderr)
        self.git("checkout", "main")
        self.git("remote", "set-url", "origin", "https://github.com/Ghost233/MacLauncher.git")
        self.assertIn("origin", self.cli("--dry-run").stderr)

    def test_existing_remote_tag_and_bad_manual_version_are_rejected(self):
        self.git("tag", "-a", "v0.1.3", "-m", "existing")
        self.git("push", str(self.remote), "v0.1.3")
        self.assertIn("已推送", self.cli("--dry-run").stderr)
        for value in ("0.0.0", "0.1.3+1", "0.1.10", "01.1.3"):
            self.version(value)
            self.assertIn("版本", self.cli("--dry-run").stderr)

    def test_main_ahead_of_actual_remote_is_rejected(self):
        (self.repo / "new.txt").write_text("unpublished")
        self.git("add", "new.txt")
        self.git("commit", "-m", "local only")
        self.assertIn("实际远端", self.cli("--dry-run").stderr)

    def test_retry_cannot_move_a_tag_and_minor_rollover_is_manual(self):
        self.git("tag", "-a", "v0.1.3", "HEAD~1", "-m", "wrong target")
        self.assertIn("不移动", self.cli("--retry-tag").stderr)
        self.git("tag", "-d", "v0.1.3")
        self.version("0.10.0")
        self.git("add", "pubspec.yaml")
        self.git("commit", "-m", "manual rollover")
        self.git("push", str(self.remote), "main")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        result = self.cli("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("v0.10.0", result.stdout)

    @unittest.skipUnless(os.uname().sysname == "Darwin", "macOS package validation")
    def test_prebuilt_app_version_mismatch_fails_before_packaging(self):
        shutil.copy2(SOURCE / "build-release.sh", self.repo / "scripts/build-release.sh")
        app = self.root / "Ghost Container Manager.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/Ghost Container Manager").write_bytes(b"fixture executable")
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": "com.ghost233.ghostcontainermanager",
                          "CFBundleShortVersionString": "0.1.2"}, file)
        out = self.root / "package-output"
        result = subprocess.run(["bash", str(self.repo / "scripts/build-release.sh"),
                                 "--app-path", str(app), "--output-dir", str(out)],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("应用版本不匹配", result.stderr)
        self.assertFalse(out.exists())

    @unittest.skipUnless(os.uname().sysname == "Darwin", "macOS package validation")
    def test_prebuilt_universal_app_is_rejected_before_packaging(self):
        shutil.copy2(SOURCE / "build-release.sh", self.repo / "scripts/build-release.sh")
        sdk = Path(os.environ.get("GCM_FLUTTER_SDK", "/Users/ghost233/flutter"))
        universal = sdk / "bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework/Versions/A/FlutterMacOS"
        self.assertTrue(universal.is_file(), "fixed SDK native fixture missing")
        app = self.root / "Ghost Container Manager.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        # Reuse the SDK's existing universal binary; compile no Intel artifact.
        shutil.copy2(universal, app / "Contents/MacOS/Ghost Container Manager")
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": "com.ghost233.ghostcontainermanager",
                          "CFBundleShortVersionString": "0.1.3"}, file)
        out = self.root / "package-output"
        result = subprocess.run(["bash", str(self.repo / "scripts/build-release.sh"),
                                 "--app-path", str(app), "--output-dir", str(out)],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("仅提供 macOS arm64", result.stderr)
        self.assertFalse(out.exists())

    @unittest.skipUnless(os.uname().sysname == "Darwin", "macOS package validation")
    def test_arm64_fixture_package_has_matching_manifest_and_checksums(self):
        shutil.copy2(SOURCE / "build-release.sh", self.repo / "scripts/build-release.sh")
        app = self.root / "Ghost Container Manager.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        source = self.root / "fixture.c"
        source.write_text("int main(void) { return 0; }\n")
        executable = app / "Contents/MacOS/Ghost Container Manager"
        subprocess.run(["clang", "-arch", "arm64", str(source), "-o", str(executable)],
                       check=True, capture_output=True, text=True)
        for framework, binary in (("App", "App"), ("FlutterMacOS", "FlutterMacOS")):
            target = app / f"Contents/Frameworks/{framework}.framework/{binary}"
            target.parent.mkdir(parents=True)
            shutil.copy2(executable, target)
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": "com.ghost233.ghostcontainermanager",
                          "CFBundleShortVersionString": "0.1.3"}, file)
        out = self.root / "package-output"
        result = subprocess.run(["bash", str(self.repo / "scripts/build-release.sh"),
                                 "--app-path", str(app), "--output-dir", str(out)],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((out / "manifest.json").read_text())
        self.assertEqual((manifest["version"], manifest["tag"]), ("0.1.3", "v0.1.3"))
        asset = manifest["assets"][0]
        self.assertEqual(asset["name"], "GhostContainerManager-0.1.3.dmg")
        dmg = out / asset["name"]
        self.assertGreater(dmg.stat().st_size, 0)
        self.assertEqual(asset["size"], dmg.stat().st_size)
        self.assertEqual(asset["sha256"], hashlib.sha256(dmg.read_bytes()).hexdigest())
        for line in (out / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split(maxsplit=1)
            self.assertEqual(digest, hashlib.sha256((out / name).read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
