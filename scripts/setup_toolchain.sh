#!/usr/bin/env bash
# setup_toolchain.sh - 下载并解包 aarch64 交叉编译工具链（无需 root）
#
# 工具链: Arm GNU Toolchain 11.2-2022.02 x86_64 -> aarch64-none-linux-gnu
#         （与 orangepi-build 为 H618 linux5.4/6.1 使用的版本一致）
# 镜像:   清华 TUNA / armbian-releases/_toolchain（国内推荐）
#
# 用法:
#   ./scripts/setup_toolchain.sh              # 安装工具链
#   ./scripts/setup_toolchain.sh --with-tools # 同时解包 dtc / qemu-user（apt-get download，无需 root）
#   ./scripts/setup_toolchain.sh --check      # 只检查是否已安装
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu"
TOOLCHAIN="$ROOT/tools/$NAME"
BASE_URL="${OPIZ3_TOOLCHAIN_URL:-https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/_toolchain}"
TARBALL="$NAME.tar.xz"
WITH_TOOLS=0

for arg in "$@"; do
	case "$arg" in
	--with-tools) WITH_TOOLS=1 ;;
	--check)
		if [ -x "$TOOLCHAIN/bin/aarch64-none-linux-gnu-gcc" ]; then
			echo "工具链已安装: $TOOLCHAIN ($("$TOOLCHAIN/bin/aarch64-none-linux-gnu-gcc" -dumpversion))"
			exit 0
		fi
		echo "工具链未安装: $TOOLCHAIN"
		exit 1
		;;
	-h | --help)
		sed -n '2,12p' "$0"
		exit 0
		;;
	*)
		echo "未知参数: $arg" >&2
		exit 2
		;;
	esac
done

mkdir -p "$ROOT/tools"
cd "$ROOT/tools"

if [ ! -x "$TOOLCHAIN/bin/aarch64-none-linux-gnu-gcc" ]; then
	echo "==> 下载 $BASE_URL/$TARBALL"
	if ! command -v curl >/dev/null 2>&1; then
		echo "缺少 curl，请先安装" >&2
		exit 1
	fi
	curl -fL --retry 3 --retry-delay 2 -o "$TARBALL" "$BASE_URL/$TARBALL"
	echo "==> 解包（约 500MB）"
	tar -xf "$TARBALL"
	rm -f "$TARBALL"
else
	echo "==> 工具链已存在，跳过下载"
fi

"$TOOLCHAIN/bin/aarch64-none-linux-gnu-gcc" --version | head -1
echo "==> 安装完成: $TOOLCHAIN"

if [ "$WITH_TOOLS" = 1 ]; then
	echo "==> 安装本地 dtc / qemu-user-static（apt-get download + dpkg-deb -x，无需 root）"
	mkdir -p "$ROOT/tools/deb" "$ROOT/tools/local"
	(
		cd "$ROOT/tools/deb"
		apt-get download device-tree-compiler qemu-user-static
	)
	for deb in "$ROOT"/tools/deb/*.deb; do
		dpkg-deb -x "$deb" "$ROOT/tools/local"
	done
	LD_LIBRARY_PATH="$ROOT/tools/local/usr/lib/x86_64-linux-gnu" \
		"$ROOT/tools/local/usr/bin/dtc" --version
	"$ROOT/tools/local/usr/bin/qemu-aarch64-static" --version | head -1
	echo "==> dtc/qemu 已解包到 tools/local"
fi

cat <<EOF

下一步:
  source scripts/env.sh
  make -C examples check
EOF
