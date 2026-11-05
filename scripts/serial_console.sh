#!/usr/bin/env bash
# serial_console.sh - 连接开发板调试串口（UART0，3.3V TTL，115200 8N1）
#
# 用法:
#   ./scripts/serial_console.sh                 # 自动找 /dev/ttyUSB* /dev/ttyACM*，用 picocom 打开
#   ./scripts/serial_console.sh /dev/ttyUSB0    # 指定设备
#   ./scripts/serial_console.sh /dev/ttyUSB0 1500000
#   ./scripts/serial_console.sh --list          # 列出串口设备与 USB 信息
#
# 接线（USB-TTL 模块 <-> 板子 DEBUG 3pin）:
#   模块 TXD -> 板 RX（DEBUG 中间脚）
#   模块 RXD -> 板 TX（DEBUG 第 3 脚）
#   模块 GND -> 板 GND（DEBUG 第 1 脚）
#   不要接 5V/3.3V！板子由 Type-C 供电。
#
# 退出: picocom 里按 Ctrl-A 再 Ctrl-X
set -euo pipefail

list_ports() {
	echo "== 串口设备 =="
	ls -l /dev/ttyUSB* /dev/ttyACM* /dev/ttyCH341USB* 2>/dev/null || echo "  （无）"
	echo
	echo "== USB 转串口 =="
	if command -v lsusb >/dev/null 2>&1; then
		lsusb | grep -iE "serial|ch34|cp210|ft232|pl2303|uart" || echo "  （未发现常见 USB-TTL 芯片）"
	fi
	echo
	echo "== 当前用户串口权限 =="
	id -nG | tr ' ' '\n' | grep -E "^(dialout|uucp)$" || echo "  不在 dialout 组: sudo usermod -aG dialout \$USER 后重新登录"
}

PORT=""
BAUD=115200
for arg in "$@"; do
	case "$arg" in
	--list | -l)
		list_ports
		exit 0
		;;
	-h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	'' ) ;;
	*)
		if [ -z "$PORT" ]; then PORT="$arg"; else BAUD="$arg"; fi
		;;
	esac
done

if [ -z "$PORT" ]; then
	PORT="$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1 || true)"
fi
if [ -z "$PORT" ]; then
	echo "找不到串口设备。插上 USB-TTL 后运行: $0 --list" >&2
	exit 1
fi
[ -e "$PORT" ] || {
	echo "设备不存在: $PORT" >&2
	exit 1
}
[[ "$BAUD" =~ ^[0-9]+$ ]] || {
	echo "波特率必须是数字: $BAUD" >&2
	exit 1
}

echo "打开 $PORT @ ${BAUD} 8N1（Ctrl-A Ctrl-X 退出）"
if ! id -nG | tr ' ' '\n' | grep -qE "^(dialout|uucp)$" && [ "$(id -u)" -ne 0 ]; then
	echo "提示: 当前用户不在 dialout 组，可能需要 sudo 或先加入组。"
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v picocom >/dev/null 2>&1 && SUDO="sudo"

if command -v picocom >/dev/null 2>&1; then
	$SUDO picocom -b "$BAUD" --imap lfcrlf --echo "$PORT"
elif command -v minicom >/dev/null 2>&1; then
	$SUDO minicom -D "$PORT" -b "$BAUD"
elif command -v screen >/dev/null 2>&1; then
	$SUDO screen "$PORT" "$BAUD"
else
	echo "没有 picocom/minicom/screen，使用裸 stty + cat 回退模式。" >&2
	stty -F "$PORT" "$BAUD" cs8 -cstopb -parenb raw -echo
	cat "$PORT"
fi
