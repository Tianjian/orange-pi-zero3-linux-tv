#!/usr/bin/env bash
# verify_all.sh - 一键复现本仓库的全部自动化验证，并输出 PASS/FAIL 汇总
#
#   ./scripts/verify_all.sh            # 全量
#   ./scripts/verify_all.sh --quick    # 跳过 qemu 冒烟与资产校验（只构建）
#
# 退出码: 0 = 全部通过；1 = 有 FAIL
# 设计: 不依赖开发板；所有“必须上板”的项目不在本脚本范围内（见 docs/06_验证报告.md）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

ok() {
	PASS=$((PASS + 1))
	printf '  \033[32m[PASS]\033[0m %s\n' "$*"
}
bad() {
	FAIL=$((FAIL + 1))
	FAILED_NAMES+=("$*")
	printf '  \033[31m[FAIL]\033[0m %s\n' "$*"
}
skip() {
	SKIP=$((SKIP + 1))
	printf '  \033[33m[SKIP]\033[0m %s\n' "$*"
}
section() { printf '\n== %s ==\n' "$*"; }

cd "$ROOT"
TOOLCHAIN="$ROOT/tools/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu"
CROSS="$TOOLCHAIN/bin/aarch64-none-linux-gnu-"
QEMU="$ROOT/tools/local/usr/bin/qemu-aarch64-static"
SYSROOT="$TOOLCHAIN/aarch64-none-linux-gnu/libc"
DTC="$ROOT/tools/local/usr/bin/dtc"
[ -x "$DTC" ] || DTC="$(command -v dtc || true)"

section "1. 工具链"
if [ -x "${CROSS}gcc" ]; then
	ok "aarch64 工具链: $("${CROSS}gcc" --version | head -1)"
else
	bad "缺少 aarch64 工具链（scripts/setup_toolchain.sh）"
fi
if [ -n "${DTC:-}" ]; then ok "dtc: $("$DTC" --version 2>&1 | head -1)"; else skip "没有 dtc"; fi
if [ -x "$QEMU" ]; then ok "qemu-aarch64-static 可用"; else skip "没有 qemu-aarch64"; fi

section "2. 构建"
make -s -C examples clean >/dev/null 2>&1
BUILD_LOG="$(make -C examples -j4 2>&1)"
BUILD_RC=$?
if [ "$BUILD_RC" -eq 0 ] && ! grep -qE "warning:|error:" <<<"$BUILD_LOG"; then
	ok "交叉编译 6 个示例，零警告零错误"
else
	bad "交叉编译失败或有告警"
	grep -E "warning:|error:" <<<"$BUILD_LOG" | head -20
fi

HOST_LOG="$(make -C examples host 2>&1)"
HOST_RC=$?
if [ "$HOST_RC" -eq 0 ] && ! grep -qE "warning:|error:" <<<"$HOST_LOG"; then
	ok "本机 gcc -Werror 编译 6 个示例通过"
else
	bad "本机编译失败或有告警"
	grep -E "warning:|error:" <<<"$HOST_LOG" | head -20
fi

section "3. 产物架构"
ARCH_OK=1
for f in build/aarch64/*; do
	[ -e "$f" ] || continue
	if file "$f" | grep -q "ARM aarch64"; then
		ok "$(basename "$f") -> ARM aarch64"
	else
		bad "$(basename "$f") 不是 ARM aarch64"
		ARCH_OK=0
	fi
done
[ "$ARCH_OK" = 1 ] || true

if [ "$QUICK" = 0 ] && [ -x "$QEMU" ]; then
	section "4. qemu 冒烟（aarch64 动态链接与参数解析）"
	for b in gpio_blink gpio_event uart i2c_scan spi_loopback pwm; do
		if "$QEMU" -L "$SYSROOT" "build/aarch64/$b" --help >/dev/null 2>&1; then
			ok "$b --help 正常退出"
		else
			bad "$b --help 运行失败"
		fi
	done
	# 错误路径：非法参数必须非 0 退出且给出中文提示
	printf '  --- 错误路径 ---\n'
	check_err() {
		local desc="$1"
		shift
		if "$@" >/dev/null 2>&1; then
			bad "$desc（应当失败却成功）"
		else
			ok "$desc 正确拒绝"
		fi
	}
	check_err "gpio_blink 非法 line" "$QEMU" -L "$SYSROOT" build/aarch64/gpio_blink -l abc
	check_err "gpio_blink 越界 line" "$QEMU" -L "$SYSROOT" build/aarch64/gpio_blink -l 9999
	check_err "gpio_event 缺 -l" "$QEMU" -L "$SYSROOT" build/aarch64/gpio_event
	check_err "pwm 越界 channel" "$QEMU" -L "$SYSROOT" build/aarch64/pwm -c 99
	check_err "i2c_scan 设备不存在" "$QEMU" -L "$SYSROOT" build/aarch64/i2c_scan -d /dev/nonexistent
	check_err "uart 非法波特率" "$QEMU" -L "$SYSROOT" build/aarch64/uart -b 12345
fi

section "5. 功能测试"
if python3 examples/tests/test_uart_pty.py build/host/uart >/tmp/pty.out 2>&1; then
	ok "PTY 串口回环 + 发送测试通过"
else
	bad "PTY 串口测试失败"
	cat /tmp/pty.out
fi

if [ -n "${DTC:-}" ]; then
	if ./scripts/build_overlay.sh --check dts/*.dts >/tmp/dtc.out 2>&1; then
		ok "设备树 overlay 语法/引用编译通过"
	else
		bad "设备树 overlay 编译失败"
	cat /tmp/dtc.out
	fi
else
	skip "没有 dtc，跳过 overlay 编译"
fi

if [ "$QUICK" = 0 ]; then
	section "6. 硬件资产与文档链接"
	if python3 scripts/validate_assets.py --strict >/tmp/assets.out 2>&1; then
		ok "CSV/SVG/GPIO 公式/文档链接校验通过"
	else
		bad "资产校验失败（见下）"
		grep "FAIL" /tmp/assets.out | head -20
	fi
fi

section "7. 脚本语法"
SYNTAX_OK=1
for f in scripts/*.sh; do
	if ! bash -n "$f"; then
		bad "bash 语法: $f"
		SYNTAX_OK=0
	fi
done
[ "$SYNTAX_OK" = 1 ] && ok "所有 shell 脚本 bash -n 通过"
python3 -m py_compile scripts/validate_assets.py examples/tests/test_uart_pty.py &&
	ok "Python 脚本可编译" || bad "Python 脚本语法错误"

section "汇总"
echo "  PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -ne 0 ]; then
	echo "  失败项:"
	printf '    - %s\n' "${FAILED_NAMES[@]}"
	exit 1
fi
echo "  全部自动化验证通过。上板项目见 docs/06_验证报告.md。"
exit 0
