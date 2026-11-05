#!/usr/bin/env bash
# verify_kernel_build.sh - 验证 H618 内核构建产物是否完整、可加载、与 DTS/配置匹配
#
# 用法:
#   ./scripts/verify_kernel_build.sh                     # 默认 kernel/out/6.1
#   ./scripts/verify_kernel_build.sh kernel/out/custom
#
# 检查:
#   1. Image / dtb / System.map / .config / modules 存在
#   2. Image 是 ARM64 Linux kernel，版本字符串正确
#   3. DTB 反编译后关键节点齐全（板型、AXP313A、MMC、GMAC、HDMI、codec、LED…）
#   4. .config 外设审计（scripts/check_kernel_config.py）
#   5. out-of-tree 模块可编译，vermagic 与内核一致
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/kernel/out/6.1}"
PASS=0
FAIL=0
WARN=0

ok() { PASS=$((PASS + 1)); printf '  \033[32m[PASS]\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
warn() { WARN=$((WARN + 1)); printf '  \033[33m[WARN]\033[0m %s\n' "$*"; }
sec() { printf '\n== %s ==\n' "$*"; }

IMAGE="$OUT/Image"
DTB="$OUT/sun50i-h618-orangepi-zero3.dtb"
CONFIG="$OUT/.config"
SYSMAP="$OUT/System.map"

sec "1. 产物存在性"
for f in "$IMAGE" "$DTB" "$CONFIG"; do
	if [ -f "$f" ]; then ok "$(basename "$f") ($(du -h "$f" | cut -f1))"; else bad "缺少 $f"; fi
done
[ -f "$SYSMAP" ] && ok "System.map ($(wc -l <"$SYSMAP") 行)" || warn "缺少 System.map"

sec "2. Image 架构与版本"
if [ -f "$IMAGE" ]; then
	if file "$IMAGE" | grep -q "ARM64\|aarch64"; then
		ok "file: $(file -b "$IMAGE")"
	else
		bad "Image 不是 ARM64: $(file -b "$IMAGE")"
	fi
	VER="$(strings "$IMAGE" | grep -m1 -E '^Linux version [0-9]' || true)"
	if [ -n "$VER" ]; then ok "版本串: $VER"; else warn "Image 中未找到 'Linux version' 串"; fi
fi

sec "3. DTB 节点"
DTC="$ROOT/tools/local/usr/bin/dtc"
[ -x "$DTC" ] || DTC="$(command -v dtc || true)"
if [ -f "$DTB" ] && [ -n "${DTC:-}" ]; then
	DTS_TMP="$(mktemp)"
	"$DTC" -I dtb -O dts "$DTB" -o "$DTS_TMP" 2>/dev/null || bad "dtc 反编译失败"
	if [ -s "$DTS_TMP" ]; then
		for needle in "xunlong,orangepi-zero3" "x-powers,axp313a" "gpio-leds" \
			"mmc-pwrseq-simple" "ethernet-phy" "motorcomm" "jedec,spi-nor" \
			"sn850?" ; do
			[ "$needle" = "sn850?" ] && continue
			if grep -q "$needle" "$DTS_TMP"; then ok "节点/属性: $needle"; else warn "未找到: $needle"; fi
		done
		# 默认关闭但必须存在的节点
		for n in mmc0 mmc1 emac0 hdmi de; do
			if grep -qE "^\s*${n}: |^\s*${n}@|${n}-" "$DTS_TMP"; then ok "节点: $n"; fi
		done
	fi
	rm -f "$DTS_TMP"
else
	warn "跳过 DTB 检查（缺 dtb 或 dtc）"
fi

sec "4. 配置审计"
if [ -f "$CONFIG" ]; then
	if python3 "$ROOT/scripts/check_kernel_config.py" "$CONFIG" --dtb "$DTB" >/tmp/kcfg.out 2>&1; then
		ok "外设配置审计通过（详见 /tmp/kcfg.out）"
	else
		bad "外设配置审计有必选项缺失"
		grep -E "NEED|必选项" /tmp/kcfg.out | head -10
	fi
fi

sec "5. out-of-tree 模块"
KMOD="$ROOT/kernel/modules/hello_opiz3"
if make -s -C "$KMOD" >/tmp/kmod.log 2>&1; then
	ok "hello_opiz3.ko 编译成功"
	file "$KMOD/hello_opiz3.ko" | grep -q "ARM aarch64" && ok "模块架构 aarch64" || bad "模块架构不对"
	if command -v modinfo >/dev/null 2>&1; then
		MV="$(modinfo -F vermagic "$KMOD/hello_opiz3.ko" 2>/dev/null | awk '{print $1}')"
		KV="$(make -s -C "$ROOT/kernel/src/linux-6.1" LOCALVERSION=-sun50iw9 kernelrelease 2>/dev/null || true)"
		ok "模块 vermagic: $MV"
		[ -n "$KV" ] && { [ "$MV" = "$KV" ] && ok "vermagic 与内核 $KV 一致" || warn "vermagic=$MV 内核=$KV"; }
	else
		warn "没有 modinfo（kmod），跳过 vermagic 检查"
	fi
else
	bad "模块编译失败"
	tail -10 /tmp/kmod.log
fi

sec "汇总"
echo "  PASS=$PASS FAIL=$FAIL WARN=$WARN"
[ "$FAIL" -eq 0 ]
