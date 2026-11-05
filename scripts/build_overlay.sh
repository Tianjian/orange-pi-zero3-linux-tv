#!/usr/bin/env bash
# build_overlay.sh - 用 dtc 编译设备树 overlay（x86 主机，无需 root）
#
# 用法:
#   ./scripts/build_overlay.sh dts/opiz3-uart5-spi1.dts
#   ./scripts/build_overlay.sh dts/*.dts          # 批量
#   ./scripts/build_overlay.sh --check           # 只做语法检查
#
# 产物: build/dtb/<name>.dtbo
# 注意: dtc 只能保证语法/引用可编译，不能保证运行时节点名与 SDK DTS 匹配。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/dtb"
DTC="$ROOT/tools/local/usr/bin/dtc"
[ -x "$DTC" ] || DTC="$(command -v dtc || true)"
CHECK_ONLY=0
FILES=()

for arg in "$@"; do
	case "$arg" in
	--check) CHECK_ONLY=1 ;;
	-h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) FILES+=("$arg") ;;
	esac
done

[ -n "${DTC:-}" ] || {
	echo "找不到 dtc。运行 scripts/setup_toolchain.sh --with-tools 或 apt install device-tree-compiler" >&2
	exit 1
}
[ ${#FILES[@]} -gt 0 ] || {
	echo "请指定 .dts 文件（例: dts/opiz3-uart5-spi1.dts）" >&2
	exit 2
}

mkdir -p "$OUT"
rc=0
for f in "${FILES[@]}"; do
	[ -f "$f" ] || {
		echo "跳过不存在的文件: $f" >&2
		rc=1
		continue
	}
	name="$(basename "$f" .dts)"
	if [ "$CHECK_ONLY" = 1 ]; then
		if "$DTC" -@ -I dts -O dtb -o /dev/null "$f" 2>/tmp/dtc.err; then
			echo "[ OK ] $f"
		else
			echo "[FAIL] $f"
			sed 's/^/       /' /tmp/dtc.err
			rc=1
		fi
	else
		"$DTC" -@ -I dts -O dtb -o "$OUT/$name.dtbo" "$f"
		echo "[ OK ] $f -> $OUT/$name.dtbo"
	fi
done
exit "$rc"
