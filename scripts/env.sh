#!/usr/bin/env bash
# env.sh - 设置 Orange Pi Zero 3 交叉编译环境（source 本文件，不要执行）
#
#   source scripts/env.sh
#   aarch64-none-linux-gnu-gcc --version
#
# 也可在 Makefile 里直接引用 $(OPIZ3_ROOT)/tools/...。

OPIZ3_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OPIZ3_ROOT

# Arm GNU Toolchain 11.2 (aarch64-none-linux-gnu)，由 scripts/setup_toolchain.sh 安装
export TOOLCHAIN="${TOOLCHAIN:-$OPIZ3_ROOT/tools/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu}"
export CROSS_COMPILE="aarch64-none-linux-gnu-"
export PATH="$TOOLCHAIN/bin:$OPIZ3_ROOT/tools/local/usr/bin:$PATH"

# 本地解包的 dtc / qemu-user（无需 root），路径存在才加入
if [ -x "$OPIZ3_ROOT/tools/local/usr/bin/dtc" ]; then
	export DTC="$OPIZ3_ROOT/tools/local/usr/bin/dtc"
fi
if [ -x "$OPIZ3_ROOT/tools/local/usr/bin/qemu-aarch64-static" ]; then
	export QEMU_AARCH64="$OPIZ3_ROOT/tools/local/usr/bin/qemu-aarch64-static"
fi

if [ ! -x "$TOOLCHAIN/bin/${CROSS_COMPILE}gcc" ]; then
	echo "警告: 交叉工具链不存在，请先运行: $OPIZ3_ROOT/scripts/setup_toolchain.sh" >&2
else
	echo "OPIZ3_ROOT=$OPIZ3_ROOT"
	echo "CC=${CROSS_COMPILE}gcc ($("$TOOLCHAIN/bin/${CROSS_COMPILE}gcc" -dumpversion 2>/dev/null))"
fi
