#!/usr/bin/env bash
# deploy.sh - 把交叉编译好的程序推到开发板并运行
#
# 用法:
#   ./scripts/deploy.sh orangepi@192.168.1.100                     # 部署并运行 gpio_blink 帮助
#   ./scripts/deploy.sh orangepi@192.168.1.100 build/aarch64/pwm -c 1 -f 50 -d 50 -t 5
#   ./scripts/deploy.sh --host orangepi@192.168.1.100 --bin build/aarch64/i2c_scan -d /dev/i2c-3
#   ./scripts/deploy.sh orangepi@192.168.1.100 --sync              # 只复制全部示例到 ~/opiz3/
#
# 前提: 板子已联网且 ssh 可用（官方镜像默认 orangepi/orangepi，建议先改密码）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/aarch64"
REMOTE_DIR="~/opiz3"

usage() {
	sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

HOST=""
BIN=""
SYNC_ONLY=0
ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--host)
		HOST="$2"
		shift 2
		;;
	--bin)
		BIN="$2"
		shift 2
		;;
	--sync) SYNC_ONLY=1; shift ;;
	-h | --help) usage 0 ;;
	*)
		if [ -z "$HOST" ]; then
			HOST="$1"
		elif [ -z "$BIN" ] && [ -f "$1" ]; then
			BIN="$1"
		else
			ARGS+=("$1")
		fi
		shift
		;;
	esac
done

[ -n "$HOST" ] || usage 2
case "$HOST" in
*@*) : ;;
*) HOST="orangepi@$HOST" ;;
esac

command -v ssh >/dev/null || {
	echo "缺少 ssh" >&2
	exit 1
}

if [ "$SYNC_ONLY" = 1 ]; then
	[ -d "$BUILD" ] || {
		echo "还没有构建产物，先运行 make -C examples" >&2
		exit 1
	}
	echo "== 同步 $BUILD/* -> $HOST:$REMOTE_DIR/"
	ssh "$HOST" "mkdir -p $REMOTE_DIR"
	scp -p "$BUILD"/* "$HOST:$REMOTE_DIR/"
	echo "完成。运行示例: ssh $HOST '$REMOTE_DIR/gpio_blink -l 73 -n 5'"
	exit 0
fi

[ -n "$BIN" ] || BIN="$BUILD/gpio_blink"
[ -f "$BIN" ] || {
	echo "找不到本地程序: $BIN（先 make -C examples）" >&2
	exit 1
}

NAME="$(basename "$BIN")"
echo "== scp $BIN -> $HOST:$REMOTE_DIR/$NAME"
ssh "$HOST" "mkdir -p $REMOTE_DIR"
scp -p "$BIN" "$HOST:$REMOTE_DIR/$NAME"

REMOTE_CMD="$REMOTE_DIR/$NAME"
for a in "${ARGS[@]:-}"; do
	[ -n "$a" ] && REMOTE_CMD="$REMOTE_CMD $(printf '%q' "$a")"
done
echo "== ssh $HOST '$REMOTE_CMD'"
ssh -t "$HOST" "chmod +x '$REMOTE_DIR/$NAME'; $REMOTE_CMD"
