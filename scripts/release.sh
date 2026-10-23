#!/usr/bin/env bash
# GhostContainerManager 正式发布入口；版本由人手动修改，脚本不 bump 或提交。
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$task_root/scripts/release.py" "$@"
