#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$task_root"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'This check entry requires a native macOS arm64 host.' >&2
  exit 1
}
: "${GCM_FLUTTER_SDK:?Set GCM_FLUTTER_SDK to the fixed Flutter SDK directory}"
: "${GCM_TEST_PYTHON:?Set GCM_TEST_PYTHON to the verified Python executable}"
[[ "$GCM_FLUTTER_SDK" == /* && -x "$GCM_FLUTTER_SDK/bin/flutter" ]]
[[ "$GCM_TEST_PYTHON" == /* && -x "$GCM_TEST_PYTHON" ]]
GCM_FLUTTER_SDK="$(cd "$GCM_FLUTTER_SDK" && pwd -P)"
GCM_TEST_PYTHON="$("$GCM_TEST_PYTHON" -c 'import os,sys; print(os.path.realpath(sys.executable))')"
task_tmp_dir="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}"
task_tmp_dir="$(cd "$task_tmp_dir" && pwd -P)"
export GCM_FLUTTER_SDK GCM_TEST_PYTHON
export TMPDIR="$task_tmp_dir/" CI=true FLUTTER_SUPPRESS_ANALYTICS=true
host_mode="${1:-check}"
if [[ $# -gt 0 ]]; then shift; fi
case "$host_mode" in prepare|check|format|analyze|test) ;; *) echo "Unknown check mode: $host_mode" >&2; exit 1 ;; esac
if [[ ( "$host_mode" == prepare || "$host_mode" == check ) && $# -ne 0 ]]; then
  echo 'prepare/check do not accept extra arguments; use test/analyze/format for targeted checks.' >&2
  exit 1
fi
if [[ "$host_mode" != prepare && ( ! -d lib || ! -d test ) ]]; then
  echo '基础配置阶段尚无 lib/ 和 test/；Flutter 应用检查未执行。' >&2
  exit 1
fi
mkdir -p .tooling/host-tests
lock_dir="$task_root/.tooling/host-tests/.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "Another host check owns $lock_dir; inspect its PID before retrying." >&2
  exit 1
fi
printf '%s\n' "$$" > "$lock_dir/pid"
run_dir="$(mktemp -d "$task_root/.tooling/host-tests/run-XXXXXX")"
finish() {
  local check_exit=$?
  trap - EXIT
  if [[ "$check_exit" != 0 && -f "$run_dir/environment.log" ]]; then
    cat "$run_dir/environment.log" >&2
  fi
  if [[ -f "$run_dir/input.json" ]]; then
    local fingerprint_exit=0
    "$GCM_TEST_PYTHON" - "$run_dir" <<'PYEND' || fingerprint_exit=$?
import hashlib, json, pathlib, sys
run = pathlib.Path(sys.argv[1])
before = json.loads((run / 'input.json').read_text())['source_files']
after = {name: hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() if pathlib.Path(name).is_file() else None for name in before}
for directory in ('lib', 'test'):
    for path in pathlib.Path(directory).rglob('*'):
        if path.is_file() and '.git' not in path.parts and '__pycache__' not in path.parts and path.name != '.DS_Store' and str(path) not in after:
            after[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
(run / 'output.json').write_text(json.dumps({'source_files_after': after, 'source_unchanged': before == after}, indent=2) + '\n')
if before != after:
    raise SystemExit('Check source content changed during the command; do not reuse this result')
PYEND
    if [[ "$check_exit" == 0 && "$fingerprint_exit" != 0 ]]; then check_exit="$fingerprint_exit"; fi
  fi
  printf '%s\n' "$check_exit" > "$run_dir/exit"
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" || echo "Host check lock cleanup failed: $lock_dir" >&2
  echo "Evidence: $run_dir"
  exit "$check_exit"
}
trap finish EXIT
prepared="$task_root/.tooling/host-tests/prepared.json"
# A preparation binds the actual runtime and immutable dependency inputs once.
# Checks only reuse this manifest; changed inputs explicitly require preparation.
"$GCM_TEST_PYTHON" - "$host_mode" "$run_dir" "$prepared" > "$run_dir/environment.log" 2>&1 <<'PY'
import hashlib, json, os, pathlib, platform, subprocess, sys
mode, run_dir, prepared = sys.argv[1:]
root = pathlib.Path.cwd()
def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
def command(args):
    result = subprocess.run(args, text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).strip()
sdk = pathlib.Path(os.environ['GCM_FLUTTER_SDK'])
icons = sdk / 'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Native macOS arm64 Python is required'
assert sys.version_info >= (3, 11), 'Python -P requires at least Python 3.11'
assert icons.is_file(), 'The fixed SDK MaterialIcons font must exist'
identity = {
    'platform': platform.system(), 'architecture': platform.machine(),
    'flutter_sdk': str(sdk), 'sdk_head': command(['git', '-C', str(sdk), 'rev-parse', 'HEAD']),
    'python': os.environ['GCM_TEST_PYTHON'], 'python_version': platform.python_version(),
    'python_sha256': digest(os.environ['GCM_TEST_PYTHON']),
    'dart_sha256': digest(sdk / 'bin/cache/dart-sdk/bin/dart'),
    'material_icons': str(icons), 'material_icons_sha256': digest(icons),
    'tmpdir': os.environ['TMPDIR'], 'pubspec_sha256': digest(root / 'pubspec.yaml'),
    'lock_sha256': digest(root / 'pubspec.lock') if (root / 'pubspec.lock').is_file() else None,
}
assert identity['sdk_head'] == 'abaf9c523780a608bd46686fd5e53740a07077f8', 'Use the repository fixed Flutter 3.47.7 commit'
if mode == 'prepare':
    old = pathlib.Path(prepared)
    if old.exists():
        pathlib.Path(run_dir, 'previous-prepared.json').write_bytes(old.read_bytes())
    old.write_text(json.dumps({'ready': False}) + '\n')
    flutter = command([str(sdk / 'bin/flutter'), '--suppress-analytics', '--version', '--machine'])
    actual = json.loads(flutter)
    assert actual['frameworkVersion'] == '3.47.7' and actual['dartSdkVersion'].split()[0] == '3.13.5', 'Flutter/Dart versions differ from the repository toolchain'
    identity['flutter_version'] = actual
    identity['dart_version'] = command([str(sdk / 'bin/cache/dart-sdk/bin/dart'), '--version'])
    assert 'macos_arm64' in identity['dart_version'], 'The Dart runtime must be macOS arm64'
    pathlib.Path(run_dir, 'prepare-candidate.json').write_text(json.dumps(identity, indent=2) + '\n')
else:
    assert pathlib.Path(prepared).is_file(), 'Run scripts/test-host.sh prepare once before checks'
    saved = json.loads(pathlib.Path(prepared).read_text())
    assert saved.get('ready') is True, 'Environment preparation did not finish successfully; run prepare again online'
    assert all(saved.get(key) == value for key, value in identity.items()), 'The prepared SDK/Python/dependency inputs changed; run prepare again online'
    identity = saved
source = {}
for directory in ('lib', 'test'):
    for path in sorted((root / directory).rglob('*')):
        if path.is_file() and '.git' not in path.parts and '__pycache__' not in path.parts and path.name != '.DS_Store':
            source[str(path.relative_to(root))] = digest(path)
for name in ('pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', 'scripts/test-host.sh', 'scripts/verify_flutter_test_result.py'):
    source[name] = digest(root / name) if (root / name).is_file() else None
record = {
    'environment': identity, 'head': command(['git', 'rev-parse', 'HEAD']),
    'branch': command(['git', 'branch', '--show-current']), 'mode': mode, 'source_files': source,
}
pathlib.Path(run_dir, 'input.json').write_text(json.dumps(record, indent=2) + '\n')
PY
run_check() {
  local step="$1"
  shift
  printf '%q ' "$@" > "$run_dir/$step.command"
  printf '\n' >> "$run_dir/$step.command"
  local step_exit=0
  "$@" > "$run_dir/$step.log" 2>&1 || step_exit=$?
  printf '%s\n' "$step_exit" > "$run_dir/$step.exit"
  tail -n 20 "$run_dir/$step.log"
  printf 'Step %s exit %s. Full log: %s\n' "$step" "$step_exit" "$run_dir/$step.log"
  if [[ "$step" == test ]]; then
    "$GCM_TEST_PYTHON" scripts/verify_flutter_test_result.py \
      "$run_dir/$step.log" "$step_exit" "$run_dir/test-outcome.json" || return 1
  fi
  return "$step_exit"
}
if [[ "$host_mode" == prepare ]]; then
  run_check pub-get "$GCM_FLUTTER_SDK/bin/flutter" --suppress-analytics pub get
  "$GCM_TEST_PYTHON" - "$run_dir/prepare-candidate.json" "$prepared" "$run_dir/input.json" <<'PY'
import hashlib, json, pathlib, sys
candidate = json.loads(pathlib.Path(sys.argv[1]).read_text())
lock_digest = hashlib.sha256(pathlib.Path('pubspec.lock').read_bytes()).hexdigest()
if candidate['lock_sha256'] is not None:
    assert lock_digest == candidate['lock_sha256'], 'Online pub get changed pubspec.lock; preserve and review the change before preparing again'
else:
    record = json.loads(pathlib.Path(sys.argv[3]).read_text())
    record['source_files']['pubspec.lock'] = lock_digest
    record['lockfile_created'] = True
    pathlib.Path(sys.argv[3]).write_text(json.dumps(record, indent=2) + '\n')
candidate['lock_sha256'] = lock_digest
candidate['ready'] = True
pathlib.Path(sys.argv[2]).write_text(json.dumps(candidate, indent=2) + '\n')
PY
elif [[ "$host_mode" == check ]]; then
  run_check format "$GCM_FLUTTER_SDK/bin/cache/dart-sdk/bin/dart" format --output=none --set-exit-if-changed lib test
  run_check analyze "$GCM_FLUTTER_SDK/bin/flutter" --suppress-analytics analyze --no-pub
  run_check test "$GCM_FLUTTER_SDK/bin/flutter" --suppress-analytics test --no-pub --concurrency=1
elif [[ "$host_mode" == format ]]; then
  run_check format "$GCM_FLUTTER_SDK/bin/cache/dart-sdk/bin/dart" format --output=none --set-exit-if-changed "$@"
else
  run_check "$host_mode" "$GCM_FLUTTER_SDK/bin/flutter" --suppress-analytics "$host_mode" --no-pub "$@"
fi
