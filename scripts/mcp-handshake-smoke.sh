#!/bin/bash
# MCP 握手探测 smoke（issue #33 / 里程碑 #28 T5）。
#
# 对一个正在运行的 Ghost Container Manager MCP server 分别在
# Streamable HTTP 通道与 stdio 通道各做一次真实 initialize 握手，断言：
#   - serverInfo.version 非空且 != "0.0.0"
#   - 协议版本声明存在
#   - tools/list 恰好为 {gcm_help, gcm_call}
# 输出 ACCEPT/RESULT 结构化行；退出码 0=通过，1=失败，2=用法/环境错误。
#
# 用法：
#   scripts/mcp-handshake-smoke.sh [--port N]
# 环境变量：
#   GCM_MCP_PORT  MCP 端口（默认 35731）
#   GCM_DART      Dart 可执行文件（缺省依次尝试 PATH 上的 dart、
#                 $GCM_FLUTTER_SDK、$HOME/flutter 的内置 dart-sdk）
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

port="${GCM_MCP_PORT:-35731}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) port="${2:?--port 需要端口号}"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

dart_bin="${GCM_DART:-}"
if [[ -z "$dart_bin" ]]; then
  if command -v dart >/dev/null 2>&1; then
    dart_bin="$(command -v dart)"
  else
    sdk="${GCM_FLUTTER_SDK:-$HOME/flutter}"
    dart_bin="$sdk/bin/cache/dart-sdk/bin/dart"
  fi
fi
[[ -x "$dart_bin" ]] || { echo "找不到可执行的 dart：$dart_bin（可设 GCM_DART）" >&2; exit 2; }

exec "$dart_bin" scripts/mcp_acceptance.dart smoke --port "$port" --repo "$repo_root"
