#!/usr/bin/env bash
# build-release.sh — 构建 GhostContainerManager 发布 DMG 与清单
#
# 流程：读取 pubspec.yaml 版本（semver 部分）→ flutter build macos --release →
# 校验 .app（非空、bundle id 匹配）→ 组装 DMG 内容（.app + 中文 README +
# /Applications 符号链接）→ hdiutil 生成 DMG → 写 manifest.json 与 SHA256SUMS
# 到 dist/（dist/ 已在 .gitignore 中）。
#
# 用法：
#   scripts/build-release.sh                  完整构建并打包（需要 macOS 与 Flutter）
#   scripts/build-release.sh --app-path PATH  跳过 flutter build，直接打包已构建的 .app
#   --output-dir PATH                       指定本地预检产物目录（默认 dist）
#
# 环境变量：
#   FLUTTER_BIN        flutter 可执行文件路径，缺省为 PATH 中的 flutter。
#   GCM_BUILD_NUMBER   可选；构建号（写入 CFBundleVersion）。CI 发布由
#                      release.yml 注入 github.run_number；本地构建缺省不传，
#                      由 Flutter 以版本号兜底。
#
# 每步失败即停（set -euo pipefail），任何错误以非零退出。

set -euo pipefail

APP_NAME="GhostContainerManager"
EXPECTED_BUNDLE_ID="com.ghost233.ghostcontainermanager"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
PREBUILT_APP=""
DIST_DIR="dist"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-release.sh [--app-path PATH] [--output-dir PATH]
  --app-path PATH   跳过 flutter build，打包指定的已构建 .app（用于仅测试打包环节）
  --output-dir PATH 指定产物目录，默认 dist；本地预检可选独立目录
  -h, --help        显示本说明
EOF
}

die() {
  echo "build-release: 错误: $*" >&2
  exit 1
}

info() {
  echo "build-release: $*"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app-path)
      [ $# -ge 2 ] || { usage; die "--app-path 需要一个路径参数"; }
      PREBUILT_APP="$2"
      shift 2
      ;;
    --output-dir)
      [ $# -ge 2 ] && [ -n "$2" ] || { usage; die "--output-dir 需要非空路径"; }
      DIST_DIR="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "本脚本仅支持 macOS（当前: $(uname -s)）"
command -v hdiutil >/dev/null 2>&1 || die "未找到 hdiutil"

# 定位仓库根目录，保证从任意目录调用行为一致。
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
[ -f pubspec.yaml ] || die "未找到 pubspec.yaml（请确认仓库布局）"

# ---- 版本读取与校验 ----

full_version="$(awk '/^version:/{print $2; exit}' pubspec.yaml)"
[ -n "$full_version" ] || die "无法从 pubspec.yaml 读取 version 字段"
# 正式版本与本地发布入口采用同一格式；不接受 +build。
[[ "$full_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.[0-9]$ ]] \
  || die "版本号必须是无 +build 的 x.y.z，patch 为 0–9"
VERSION="$full_version"
[ "$VERSION" != "0.0.0" ] || die "0.0.0 是基础配置占位；由人确定正式版本后再打包"

DMG_NAME="GhostContainerManager-${VERSION}.dmg"
STAGING_DIR=""
APP_PATH=""

cleanup() {
  # 显式保留触发 trap 时的退出码，避免清理逻辑把失败掩盖成成功。
  local rc=$?
  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
  exit "$rc"
}
trap cleanup EXIT

info "版本: ${full_version}（semver: ${VERSION}）"

# ---- 构建或接收 .app ----

if [ -n "$PREBUILT_APP" ]; then
  APP_PATH="$PREBUILT_APP"
  info "跳过 flutter build，使用预构建产物: $APP_PATH"
else
  command -v "$FLUTTER_BIN" >/dev/null 2>&1 \
    || die "未找到 flutter（可通过 FLUTTER_BIN 指定路径）"
  # 构建号由调用方注入（CI 传 github.run_number）；缺省不传，Flutter 以版本号兜底。
  build_args=(build macos --release)
  if [ -n "${GCM_BUILD_NUMBER:-}" ]; then
    build_args+=(--build-number "$GCM_BUILD_NUMBER")
  fi
  info "执行 flutter ${build_args[*]} …"
  FLUTTER_MACOS_ARM64_ONLY=true "$FLUTTER_BIN" "${build_args[@]}"
  APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"
fi

# ---- 校验 .app ----

[ -d "$APP_PATH" ] || die "构建产物不存在: $APP_PATH"
plist="$APP_PATH/Contents/Info.plist"
[ -f "$plist" ] || die "缺少 Info.plist: $plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" \
  || die "无法读取 $plist 的 CFBundleIdentifier"
[ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] \
  || die "bundle id 不匹配：期望 ${EXPECTED_BUNDLE_ID}，实际 ${bundle_id}"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
[ "$app_version" = "$VERSION" ] \
  || die "应用版本不匹配：pubspec 为 ${VERSION}，实际 .app 为 ${app_version}"
exe="$APP_PATH/Contents/MacOS/$APP_NAME"
[ -s "$exe" ] || die "可执行文件缺失或为空: $exe"
for binary in "$exe" \
  "$APP_PATH/Contents/Frameworks/App.framework/App" \
  "$APP_PATH/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS"; do
  architectures="$(/usr/bin/lipo -archs "$binary" 2>/dev/null)" \
    || die "无法验证二进制架构: $binary"
  [ "$architectures" = "arm64" ] \
    || die "仅提供 macOS arm64；产物架构为 ${architectures}: $binary"
done
info "已校验 .app: ${APP_PATH}（bundle id: ${bundle_id}）"

# ---- 组装 DMG 内容 ----

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ghostcontainermanager-dmg.XXXXXX")"
cp -R "$APP_PATH" "$STAGING_DIR/"

cat > "$STAGING_DIR/README.txt" <<EOF
${APP_NAME} ${VERSION}
=========================

安装方法
--------
将 ${APP_NAME}.app 拖入本窗口中的 Applications 文件夹
（或拖入访达中的「应用程序」），即完成安装。

首次打开
--------
本应用未使用 Apple 开发者证书签名，也未经过公证。
首次打开时，请在访达中右键点击 ${APP_NAME}.app 并选择「打开」，
在弹出的对话框中再次点击「打开」。
若系统提示「无法打开，因为 Apple 无法检查其是否包含恶意软件」，
同样通过右键「打开」绕过 Gatekeeper 检查。

系统要求
--------
macOS 26 或更高版本（Apple Silicon）。
安装并启动 Apple container 运行时；本安装包不安装或启动运行时。

完整性校验
----------
发布页同时提供 manifest.json 与 SHA256SUMS，可用
  shasum -a 256 -c SHA256SUMS
核对本 DMG 的完整性。
EOF

ln -s /Applications "$STAGING_DIR/Applications"

# ---- 生成 DMG ----

mkdir -p "$DIST_DIR"
info "生成 $DIST_DIR/$DMG_NAME …"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DIST_DIR/$DMG_NAME" >/dev/null

rm -rf "$STAGING_DIR"
STAGING_DIR=""

# ---- 清单 ----

dmg_sha="$(shasum -a 256 "$DIST_DIR/$DMG_NAME" | awk '{print $1}')"
case "$dmg_sha" in
  *[!0-9a-f]*) die "DMG sha256 异常: $dmg_sha" ;;
esac
[ "${#dmg_sha}" -eq 64 ] || die "DMG sha256 长度异常: $dmg_sha"
dmg_size="$(stat -f %z "$DIST_DIR/$DMG_NAME")"

# manifest.json 结构固定（见 docs/release-versioning.md ），
# 用 printf 生成以保证格式逐字节可控。
printf '{"version":"%s","tag":"v%s","assets":[{"name":"%s","sha256":"%s","size":%s}]}\n' \
  "$VERSION" "$VERSION" "$DMG_NAME" "$dmg_sha" "$dmg_size" \
  > "$DIST_DIR/manifest.json"

# SHA256SUMS 覆盖 DMG 与 manifest.json。
(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" manifest.json > SHA256SUMS)

info "完成："
info "  ${DIST_DIR}/${DMG_NAME}（${dmg_size} 字节，sha256: ${dmg_sha}）"
info "  $DIST_DIR/manifest.json"
info "  $DIST_DIR/SHA256SUMS"
