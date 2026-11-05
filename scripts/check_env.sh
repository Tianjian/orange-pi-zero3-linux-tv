#!/usr/bin/env bash
# check_env.sh - 开发主机环境自检（不修改系统，只读）
#
#   ./scripts/check_env.sh            # 人读报告
#   ./scripts/check_env.sh --json     # 机器可读
#   ./scripts/check_env.sh --strict   # 有 FAIL 时返回非 0
#
# 检查项: OS/架构、交叉工具链、dtc、qemu-aarch64、串口工具、镜像烧写工具、
#         示例构建能力、磁盘空间。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN="$ROOT/tools/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu"
CROSS="$TOOLCHAIN/bin/aarch64-none-linux-gnu-"
JSON=0
STRICT=0
FAILS=0
WARNS=0

for arg in "$@"; do
	case "$arg" in
	--json) JSON=1 ;;
	--strict) STRICT=1 ;;
	-h | --help) sed -n '2,9p' "$0"; exit 0 ;;
	esac
done

pass() { [ "$JSON" = 1 ] || printf '  \033[32m[ OK ]\033[0m %s\n' "$*"; }
warn() { WARNS=$((WARNS + 1)); [ "$JSON" = 1 ] || printf '  \033[33m[WARN]\033[0m %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); [ "$JSON" = 1 ] || printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
info() { [ "$JSON" = 1 ] || printf '  [INFO] %s\n' "$*"; }

[ "$JSON" = 1 ] || { echo "== Orange Pi Zero 3 开发主机环境自检 =="; echo; }

# --- 主机 ---
[ "$JSON" = 1 ] || echo "[1] 主机"
ARCH="$(uname -m)"
info "内核: $(uname -sr)  架构: $ARCH"
if [ "$ARCH" = "x86_64" ]; then
	pass "x86_64 主机（orangepi-build 要求 Ubuntu 22.04 x64）"
else
	warn "非 x86_64 主机，orangepi-build 官方仅支持 x86_64"
fi
if [ -r /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	info "发行版: ${PRETTY_NAME:-unknown}"
	case "${ID:-}:${VERSION_ID:-}" in
	ubuntu:22.04) pass "Ubuntu 22.04（与 orangepi-build 官方环境一致）" ;;
	ubuntu:24.04) warn "Ubuntu 24.04：orangepi-build 官方只测过 22.04，建议用 22.04 容器/虚拟机编译完整镜像" ;;
	*) warn "非 Ubuntu 22.04，编译 orangepi-build 可能遇到依赖差异（示例程序开发不受影响）" ;;
	esac
fi

# --- 工具链 ---
[ "$JSON" = 1 ] || echo
[ "$JSON" = 1 ] || echo "[2] 交叉编译工具链"
if [ -x "${CROSS}gcc" ]; then
	pass "aarch64-none-linux-gnu-gcc $("${CROSS}gcc" -dumpversion)"
else
	fail "未安装工具链，请运行 scripts/setup_toolchain.sh"
fi

# --- 辅助工具 ---
[ "$JSON" = 1 ] || echo
[ "$JSON" = 1 ] || echo "[3] 辅助工具"
if [ -x "$ROOT/tools/local/usr/bin/dtc" ]; then
	pass "dtc (本地解包)"
elif command -v dtc >/dev/null 2>&1; then
	pass "dtc $(dtc --version 2>&1 | head -1)"
else
	warn "没有 dtc，设备树 overlay 编译不可用（scripts/setup_toolchain.sh --with-tools）"
fi
if [ -x "$ROOT/tools/local/usr/bin/qemu-aarch64-static" ]; then
	pass "qemu-aarch64-static（本地）"
elif command -v qemu-aarch64-static >/dev/null 2>&1; then
	pass "qemu-aarch64-static"
else
	warn "没有 qemu-aarch64，无法在 x86 上冒烟运行 aarch64 程序（可选）"
fi
if command -v python3 >/dev/null 2>&1; then
	pass "python3 $(python3 -V 2>&1 | cut -d' ' -f2)"
else
	warn "没有 python3，hardware/ 资产校验脚本不可用"
fi

# --- 串口 ---
[ "$JSON" = 1 ] || echo
[ "$JSON" = 1 ] || echo "[4] 串口/USB"
SERIAL_OK=0
for t in picocom minicom screen; do
	if command -v "$t" >/dev/null 2>&1; then
		pass "串口工具: $t"
		SERIAL_OK=1
	fi
done
[ "$SERIAL_OK" = 1 ] || warn "没有 picocom/minicom/screen，可用 scripts/serial_console.sh 的裸 stty 回退模式"
PORTS=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true)
if [ -n "$PORTS" ]; then
	pass "检测到 USB 串口: $(echo "$PORTS" | tr '\n' ' ')"
	info "USB-TTL 接线: 模块 TXD->板 DEBUG 第2脚(RX)，RXD->第3脚(TX)，GND->第1脚(GND)；3.3V 电平，不要接 5V"
else
	info "未检测到 USB 串口（插上 CH340/CP2102/FT232 后再看）"
fi

# --- 烧写 ---
[ "$JSON" = 1 ] || echo
[ "$JSON" = 1 ] || echo "[5] 镜像烧写"
for t in lsblk blockdev dd sha256sum; do
	if command -v "$t" >/dev/null 2>&1; then
		pass "$t"
	else
		fail "缺少 $t"
	fi
done
if command -v sudo >/dev/null 2>&1; then
	info "烧写脚本会用 sudo（需要输入密码）"
fi

# --- 构建冒烟 ---
[ "$JSON" = 1 ] || echo
[ "$JSON" = 1 ] || echo "[6] 示例构建"
if [ -x "${CROSS}gcc" ] && command -v make >/dev/null 2>&1; then
	if make -s -C "$ROOT/examples" -j4 >/dev/null 2>&1; then
		pass "交叉编译 6 个示例成功"
	else
		fail "示例交叉编译失败，运行 make -C examples 查看错误"
	fi
else
	warn "跳过（缺工具链或 make）"
fi

# --- 磁盘 ---
[ "$JSON" = 1 ] || echo
[ "$JSON" = 1 ] || echo "[7] 磁盘空间"
AVAIL_GB=$(df -BG --output=avail "$ROOT" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "${AVAIL_GB:-}" ]; then
	if [ "$AVAIL_GB" -ge 60 ]; then
		pass "剩余 ${AVAIL_GB}GB（orangepi-build 全量编译建议 ≥60GB）"
	elif [ "$AVAIL_GB" -ge 10 ]; then
		warn "剩余 ${AVAIL_GB}GB：够本仓库开发，不够完整 SDK 编译（建议 ≥60GB）"
	else
		fail "剩余 ${AVAIL_GB}GB，空间不足"
	fi
fi

if [ "$JSON" = 1 ]; then
	printf '{"fails":%d,"warns":%d}\n' "$FAILS" "$WARNS"
else
	echo
	echo "== 结果: FAIL=$FAILS WARN=$WARNS =="
	[ "$FAILS" -eq 0 ] && echo "环境可以开始 Orange Pi Zero 3 开发。"
fi

if [ "$STRICT" = 1 ] && [ "$FAILS" -gt 0 ]; then
	exit 1
fi
exit 0
