#!/usr/bin/env bash
# setup_kernel_deps.sh - 准备内核构建所需的主机工具（无需 root）
#
# 正常 Ubuntu/Debian 主机只需要:
#   sudo apt install -y build-essential flex bison bc libssl-dev libelf-dev kmod u-boot-tools
# 本脚本用于“没有 sudo”的环境：用 apt-get download + dpkg-deb -x 把工具解到 tools/local，
# 并处理 Ubuntu bison 把 m4 路径写死为 /usr/bin/m4 的问题（改成相对 "m4"，走 PATH）。
#
# 用法:
#   ./scripts/setup_kernel_deps.sh          # 安装/检查
#   ./scripts/setup_kernel_deps.sh --check  # 只检查
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="$ROOT/tools/local"
BIN="$LOCAL/usr/bin"
DEB="$ROOT/tools/deb"
export PATH="$BIN:$PATH"
[ -d "$LOCAL/usr/share/bison" ] && export BISON_PKGDATADIR="$LOCAL/usr/share/bison"

check() {
	local missing=0
	for t in flex bison m4 mkimage; do
		if command -v "$t" >/dev/null 2>&1; then
			printf '  [ OK ] %-8s %s\n' "$t" "$(command -v "$t")"
		else
			printf '  [MISS] %-8s\n' "$t"
			missing=1
		fi
	done
	# bison 真跑一次（会调用 m4）
	if command -v bison >/dev/null 2>&1; then
		local tmp
		tmp=$(mktemp -d)
		if printf '%%token A\n%%%%\ns: A;\n%%%%\n' >"$tmp/t.y" &&
			bison -o "$tmp/t.c" "$tmp/t.y" >/dev/null 2>&1; then
			echo "  [ OK ] bison 可用（m4 调用正常）"
		else
			echo "  [FAIL] bison 无法调用 m4（需要 BISON_PKGDATADIR 或修补路径）"
			missing=1
		fi
		rm -rf "$tmp"
	fi
	return "$missing"
}

echo "== 检查内核构建依赖 =="
if check; then
	echo "依赖齐全。"
	exit 0
fi
[ "${1:-}" = "--check" ] && exit 1

echo "== 下载并解包 flex / bison / m4 / u-boot-tools =="
mkdir -p "$DEB" "$LOCAL"
(
	cd "$DEB"
	apt-get download flex bison m4 u-boot-tools
)
for f in "$DEB"/flex_*.deb "$DEB"/bison_*.deb "$DEB"/m4_*.deb "$DEB"/u-boot-tools_*.deb; do
	[ -f "$f" ] && dpkg-deb -x "$f" "$LOCAL"
done

# Ubuntu 的 bison 二进制把 m4 路径编译成 /usr/bin/m4；改为相对 "m4"（走 PATH）
if [ -x "$BIN/bison" ] && [ ! -x /usr/bin/m4 ]; then
	python3 - "$BIN/bison" <<'PY'
import sys
p = sys.argv[1]
b = open(p, 'rb').read()
old = b'/usr/bin/m4\x00'
new = b'm4' + b'\x00' * (len(old) - 2)
if old in b:
    open(p, 'wb').write(b.replace(old, new, 1))
    print("  patched bison: /usr/bin/m4 -> m4 (PATH)")
PY
	chmod +x "$BIN/bison"
fi
rm -f "$BIN"/*.bak

echo
echo "== 复检 =="
check
cat <<EOF

使用方式（每次构建前）:
  export PATH="$BIN:\$PATH"
  [ -d "$LOCAL/usr/share/bison" ] && export BISON_PKGDATADIR="$LOCAL/usr/share/bison"
scripts/build_kernel.sh 会自动设置这两项。
EOF
