#!/bin/bash
# ============================================================
# 编译 jq (Android, 自包含二进制)
#
# 方法参考:
#   - jqlang/jq 官方构建方式 (--with-oniguruma=builtin, 静态链接)
#   - termux-packages/packages/jq (Android 交叉编译参考)
# 产出可在普通 Android (无需 termux) 上直接运行的静态 jq
#
# 用法:
#   ./build.sh                        # 最新 release, arm64
#   JQ_VERSION=1.8.2 ./build.sh       # 指定版本
#   TARGET_ARCH=arm ./build.sh        # 指定架构 (arm64|arm|x64|ia32)
#
# 环境变量:
#   JQ_VERSION          latest(默认, 自动检测最新 release) / 完整版本(如 1.8.2)
#   TARGET_ARCH         目标架构: arm64|arm|x64|ia32 (默认 arm64)
#   ANDROID_SDK_VERSION Android API 级别 (默认 24)
#   ANDROID_NDK_HOME    NDK 路径 (未设置时自动查找 Actions 预装 / 常见路径)
#   OUT_DIR             输出目录 (默认 ./out)
# ============================================================
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
PATCHES="$REPO_DIR/patches"
OUT_DIR="${OUT_DIR:-$(pwd)/out}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
ANDROID_SDK_VERSION="${ANDROID_SDK_VERSION:-24}"
DEFAULT_JQ_VERSION="1.8.2"

info() { echo "[*] $1"; }
warn() { echo "[!] $1"; }
die()  { echo "[Error] $1"; exit 1; }

# ---------- 解析版本 ----------
# latest = jq 最新 release (GitHub API); API 失败回退默认版本
resolve_version() {
  local v="${JQ_VERSION:-latest}"
  case "$v" in
    ""|latest)
      local ver
      ver=$(curl -fsSL --max-time 30 "https://api.github.com/repos/jqlang/jq/releases/latest" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name","").lstrip("jq-"))' 2>/dev/null || true)
      if [ -z "$ver" ]; then
        warn "解析最新 jq 版本失败, 回退 $DEFAULT_JQ_VERSION"
        ver="$DEFAULT_JQ_VERSION"
      fi
      echo "$ver"
      ;;
    *)
      echo "$v" | sed 's/^jq-//; s/^v//'
      ;;
  esac
}

VER=$(resolve_version)
info "jq 版本: $VER"

# ---------- 按版本线选补丁集 ----------
# patches/<版本线>/termux: 每个 jq 小版本线 (1.8.x) 一套补丁
LINE="${VER%.*}"
PATCH_DIR="$PATCHES/$LINE"
if [ ! -d "$PATCH_DIR" ]; then
  PATCH_DIR=$(ls -d "$PATCHES"/[0-9]* 2>/dev/null | sort -V | tail -n 1 || true)
  if [ -z "$PATCH_DIR" ] || [ ! -d "$PATCH_DIR" ]; then
    die "未找到任何补丁目录: 需要 $PATCHES/$LINE 或任意 patches/<版本线>"
  fi
  warn "jq $LINE 没有专属补丁集, 回退使用 $(basename "$PATCH_DIR") 版 (可能部分失效, 见下方警告)"
fi
info "补丁集: $(basename "$PATCH_DIR") (jq ${LINE}.x)"

# ---------- 架构 ----------
# clang 前缀与 autoconf host triple 分开 (arm 的 clang 前缀是 armv7a-, --host 用 arm-)
case "$TARGET_ARCH" in
  arm64|aarch64) DEST_CPU="arm64"; TOOLCHAIN_PREFIX="aarch64-linux-android";     HOST_TRIPLE="aarch64-linux-android" ;;
  arm|armv7)     DEST_CPU="arm";   TOOLCHAIN_PREFIX="armv7a-linux-androideabi"; HOST_TRIPLE="arm-linux-androideabi" ;;
  x64|x86_64)    DEST_CPU="x64";   TOOLCHAIN_PREFIX="x86_64-linux-android";     HOST_TRIPLE="x86_64-linux-android" ;;
  ia32|x86)      DEST_CPU="ia32";  TOOLCHAIN_PREFIX="i686-linux-android";       HOST_TRIPLE="i686-linux-android" ;;
  *) die "不支持的架构: $TARGET_ARCH (arm64|arm|x64|ia32)" ;;
esac
info "目标架构: $DEST_CPU"

mkdir -p "$OUT_DIR"
echo "$VER" > "$OUT_DIR/version.txt"

# ---------- CI: 该版本已发布过则跳过 ----------
# release 按版本线归档: jq-android-<arch>-<line> (如 jq-android-arm64-1.8),
# 每个版本一个 asset (jq-android-<arch>-<version>.tar.xz), 历史全部保留
skip_if_released() {
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    local tag="jq-android-${DEST_CPU}-${LINE}"
    local asset="jq-android-${DEST_CPU}-${VER}.tar.xz"
    if curl -fsSL --max-time 20 "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/${tag}" 2>/dev/null \
      | grep -q "\"name\": \"${asset}\""; then
      info "$asset 已存在于 release $tag, 跳过构建"
      exit 0
    fi
  fi
}
skip_if_released

# ---------- NDK ----------
find_ndk() {
  [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ] && { echo "$ANDROID_NDK_HOME"; return; }
  [ -n "${ANDROID_NDK_ROOT:-}" ] && [ -d "$ANDROID_NDK_ROOT" ] && { echo "$ANDROID_NDK_ROOT"; return; }
  [ -d /usr/local/lib/android/sdk/ndk ] && ls -d /usr/local/lib/android/sdk/ndk/* 2>/dev/null | sort -V | tail -n 1 && return
  [ -d "$HOME/Android/Sdk/ndk" ] && ls -d "$HOME/Android/Sdk/ndk"/* 2>/dev/null | sort -V | tail -n 1 && return
  echo ""
}
NDK=$(find_ndk)
[ -n "$NDK" ] || die "未找到 Android NDK, 请设置 ANDROID_NDK_HOME"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
[ -d "$TOOLCHAIN" ] || die "NDK 缺少 llvm 工具链: $TOOLCHAIN"
info "NDK: $NDK"

# ---------- 下载源码 ----------
SRC_DIR="$OUT_DIR/jq-${VER}"
if [ ! -d "$SRC_DIR" ]; then
  info "下载 jq 源码 (${VER}) ..."
  curl -fL --connect-timeout 10 --max-time 300 --retry 3 \
    "https://github.com/jqlang/jq/releases/download/jq-${VER}/jq-${VER}.tar.gz" \
    -o "$OUT_DIR/jq-${VER}.tar.gz"
  tar -xf "$OUT_DIR/jq-${VER}.tar.gz" -C "$OUT_DIR"
fi
cd "$SRC_DIR"

# ---------- 打补丁 ----------
# termux-packages (packages/jq) 移植的 Android 修复; 第一版预计极少或不需要
# 新版本个别失效时告警, 不中断构建
info "应用补丁 ..."
for f in "$PATCH_DIR"/termux/*.patch; do
  [ -f "$f" ] || continue
  if patch -f -p1 -t --dry-run < "$f" >/dev/null 2>&1; then
    if patch -f -p1 -t --no-backup-if-mismatch < "$f" >/dev/null 2>&1; then
      info "  应用 $(basename "$f")"
    else
      warn "$(basename "$f") 应用失败"
    fi
  elif patch -f -p1 -t -R --dry-run < "$f" >/dev/null 2>&1; then
    info "  已应用, 跳过 $(basename "$f")"
  else
    warn "$(basename "$f") 未生效 (新版本可能已修复/不再需要)"
  fi
done
find . -name "*.rej" -delete 2>/dev/null || true

# ---------- 交叉编译环境 ----------
export PATH="$PATH:$TOOLCHAIN/bin"
export CC="${TOOLCHAIN_PREFIX}${ANDROID_SDK_VERSION}-clang"
export CXX="${TOOLCHAIN_PREFIX}${ANDROID_SDK_VERSION}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"

# ---------- 配置 & 编译 ----------
# --with-oniguruma=builtin: oniguruma 内置进 jq, 不需要额外 libonig.so (官方支持的静态构建方式)
info "配置 ..."
./configure \
  --host="$HOST_TRIPLE" \
  --prefix=/usr \
  --disable-docs \
  --disable-maintainer-mode \
  --with-oniguruma=builtin

info "编译 (静态链接, 通常几分钟) ..."
# -all-static: jq 用 libtool, -static 只优先静态库不会真全静态; -all-static 才是完全静态
# (jq 官方 README: make LDFLAGS=-all-static)
make -j"$(nproc)" LDFLAGS="-all-static -s"

# ---------- 安装 & 打包 ----------
STAGE="$OUT_DIR/jq-${VER}-android-${DEST_CPU}"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin"
cp jq "$STAGE/bin/jq"
chmod 0755 "$STAGE/bin/jq"

info "验证 ..."
file "$STAGE/bin/jq"
if command -v readelf >/dev/null 2>&1; then
  if readelf -d "$STAGE/bin/jq" | grep -q NEEDED; then
    warn "jq 有动态依赖:"
    readelf -d "$STAGE/bin/jq" | grep NEEDED
  else
    info "jq 无动态依赖 (静态链接)"
  fi
fi

tar -C "$OUT_DIR" -cJf "$OUT_DIR/jq-android-${DEST_CPU}-${VER}.tar.xz" \
  "jq-${VER}-android-${DEST_CPU}"

echo
info "完成: $OUT_DIR/jq-android-${DEST_CPU}-${VER}.tar.xz"
ls -lh "$OUT_DIR/jq-android-${DEST_CPU}-${VER}.tar.xz"
