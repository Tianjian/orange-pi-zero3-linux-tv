#!/usr/bin/env bash
# build_kernel.sh - 独立复现 Orange Pi Zero 3 (H618) 的官方 Linux 6.1 内核构建
#
# 不运行 orangepi-build 的完整镜像流程，只做内核：Image + modules + dtbs。
# 使用与官方 SDK 相同的源码分支、.config 与交叉工具链，便于快速迭代驱动/DTS。
#
# 用法:
#   ./scripts/build_kernel.sh                      # 默认 6.1 / 官方 next 配置
#   ./scripts/build_kernel.sh --jobs 8
#   ./scripts/build_kernel.sh --branch 5.4         # current 分支（BSP 5.4）
#   ./scripts/build_kernel.sh --config ~/my.config # 自定义 .config
#   ./scripts/build_kernel.sh --clean              # 先 make clean
#   ./scripts/build_kernel.sh --image Image        # 官方 arm64 用 Image（zImage 是 armhf 默认）
#
# 产物:
#   kernel/out/6.1/Image  modules/  sun50i-h618-orangepi-zero3.dtb  .config  System.map
#
# 前置: scripts/setup_toolchain.sh（工具链）、scripts/setup_kernel_deps.sh（flex/bison/m4/mkimage）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="6.1"
JOBS="$(nproc)"
CONFIG=""
IMAGE="Image"
DO_CLEAN=0
OUT="$ROOT/kernel/out"

while [ $# -gt 0 ]; do
	case "$1" in
	--branch) BRANCH="$2"; shift 2 ;;
	--jobs | -j) JOBS="$2"; shift 2 ;;
	--config) CONFIG="$2"; shift 2 ;;
	--image) IMAGE="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	--clean) DO_CLEAN=1; shift ;;
	-h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

case "$BRANCH" in
6.1)
	SRC="$ROOT/kernel/src/linux-6.1"
	REPO_BRANCH="orange-pi-6.1-sun50iw9"
	DEFCONFIG_NAME="linux-6.1-sun50iw9-next"
	;;
5.4)
	SRC="$ROOT/kernel/src/linux-5.4"
	REPO_BRANCH="orange-pi-5.4-sun50iw9"
	DEFCONFIG_NAME="linux-sun50iw9-current"
	;;
*) echo "branch 只支持 6.1 / 5.4" >&2; exit 2 ;;
esac

if [ -z "$CONFIG" ]; then
	CONFIG="$ROOT/vendor/orangepi-build/external/config/kernel/$DEFCONFIG_NAME.config"
fi
[ -f "$CONFIG" ] || { echo "找不到 .config: $CONFIG" >&2; exit 2; }

TOOLCHAIN="$ROOT/tools/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu"
CROSS="$TOOLCHAIN/bin/aarch64-none-linux-gnu-"
[ -x "${CROSS}gcc" ] || { echo "缺少工具链，先运行 scripts/setup_toolchain.sh" >&2; exit 2; }

# 本地免 root 依赖（flex/bison/m4/mkimage）
export PATH="$ROOT/tools/local/usr/bin:$PATH"
if [ -d "$ROOT/tools/local/usr/share/bison" ]; then
	export BISON_PKGDATADIR="$ROOT/tools/local/usr/share/bison"
fi
for t in flex bison m4 mkimage; do
	command -v "$t" >/dev/null || { echo "缺少构建依赖: $t（运行 scripts/setup_kernel_deps.sh）" >&2; exit 2; }
done

# 按需浅克隆源码（约 1.9GB）
if [ ! -d "$SRC/.git" ]; then
	echo "==> 克隆 $REPO_BRANCH 到 $SRC"
	mkdir -p "$(dirname "$SRC")"
	git clone --depth 1 -b "$REPO_BRANCH" https://github.com/orangepi-xunlong/linux-orangepi.git "$SRC"
fi

cd "$SRC"
echo "==> 源码: $SRC"
echo "==> HEAD: $(git log -1 --format='%h %cd %s' --date=short)"
echo "==> 工具链: $("${CROSS}gcc" --version | head -1)"

[ "$DO_CLEAN" = 1 ] && { echo "==> make clean"; make ARCH=arm64 CROSS_COMPILE="$CROSS" clean >/dev/null; }

echo "==> 应用 .config: $CONFIG"
cp "$CONFIG" .config
make -s ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig

mkdir -p "$OUT/$BRANCH"
cp .config "$OUT/$BRANCH/.config"

echo "==> 编译 Image/modules/dtbs（-j$JOBS，目标 $IMAGE）"
LOG="$OUT/$BRANCH/build.log"
mkdir -p "$OUT/$BRANCH"
{
	echo "=== $(date -Is) branch=$BRANCH image=$IMAGE jobs=$JOBS ==="
	time make -j"$JOBS" ARCH=arm64 CROSS_COMPILE="$CROSS" \
		LOCALVERSION=-sun50iw9 "$IMAGE" modules dtbs
} >"$LOG" 2>&1 || {
	echo "编译失败，见 $LOG" >&2
	tail -30 "$LOG" >&2
	exit 1
}

# 收集产物
cp "arch/arm64/boot/$IMAGE" "$OUT/$BRANCH/"
cp System.map "$OUT/$BRANCH/" 2>/dev/null || true
cp arch/arm64/boot/dts/allwinner/sun50i-h618-orangepi-zero3.dtb "$OUT/$BRANCH/" 2>/dev/null || true
rm -rf "$OUT/$BRANCH/modules"
make -s ARCH=arm64 CROSS_COMPILE="$CROSS" INSTALL_MOD_PATH="$OUT/$BRANCH/modules" \
	LOCALVERSION=-sun50iw9 modules_install >/dev/null 2>&1 || true

echo
echo "==> 完成"
ls -lh "$OUT/$BRANCH/$IMAGE" "$OUT/$BRANCH/sun50i-h618-orangepi-zero3.dtb" 2>/dev/null
echo "    modules: $(find "$OUT/$BRANCH/modules" -name '*.ko' 2>/dev/null | wc -l) 个"
echo "    config : $OUT/$BRANCH/.config"
echo "    log    : $LOG"
