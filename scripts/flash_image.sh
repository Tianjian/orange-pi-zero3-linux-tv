#!/usr/bin/env bash
# flash_image.sh - 把 Orange Pi 镜像安全写入 TF 卡（Linux 主机）
#
# 用法:
#   ./scripts/flash_image.sh 镜像.img.xz /dev/sdX          # 交互确认
#   ./scripts/flash_image.sh 镜像.img /dev/sdX --yes       # 跳过确认（慎用）
#   ./scripts/flash_image.sh IMAGE DEV --list              # 只看设备信息
#   ./scripts/flash_image.sh IMAGE DEV --yes --verify      # 写后校验
#
# 安全设计:
#   - 只接受块设备；拒绝系统盘及其分区；拒绝设备不存在/未插卡
#   - 写前显示 lsblk 型号/容量，必须输入 YES（除非 --yes）
#   - 自动卸载目标设备上已挂载的分区
#   - 支持 .xz/.gz/.zip/.7z 自动解压到临时文件（或用户手动指定解压后镜像）
set -euo pipefail

usage() {
	sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

[ $# -ge 2 ] || usage 2
IMAGE="$1"
DEV="$2"
shift 2
ASSUME_YES=0
VERIFY=0
LIST_ONLY=0
for arg in "$@"; do
	case "$arg" in
	--yes | -y) ASSUME_YES=1 ;;
	--verify) VERIFY=1 ;;
	--list) LIST_ONLY=1 ;;
	-h | --help) usage 0 ;;
	*) echo "未知参数: $arg" >&2; usage 2 ;;
	esac
done

die() {
	echo "错误: $*" >&2
	exit 1
}

[ -e "$IMAGE" ] || die "镜像不存在: $IMAGE"
[ -b "$DEV" ] || die "$DEV 不是块设备（用 lsblk 查，例 /dev/sdb，不要写 /dev/sdb1）"

DEV_NAME="$(basename "$DEV")"
DEV_SYS="/sys/class/block/$DEV_NAME"
[ -d "$DEV_SYS" ] || die "找不到 $DEV_SYS"

# 拒绝把数据写进系统盘
ROOT_SRC="$(findmnt -n -o SOURCE / | head -1)"
if [ -n "$ROOT_SRC" ] && [ -b "$ROOT_SRC" ]; then
	ROOT_DISK="$(lsblk -no pkname "$ROOT_SRC" 2>/dev/null | head -1)"
	if [ -n "$ROOT_DISK" ]; then
		[ "$DEV_NAME" = "$ROOT_DISK" ] && die "$DEV 是当前系统盘（/ 所在磁盘 $ROOT_DISK），拒绝写入"
		PARENT="$(lsblk -no pkname "$DEV" 2>/dev/null | head -1)"
		[ "$PARENT" = "$ROOT_DISK" ] && die "$DEV 属于当前系统盘，拒绝写入"
	fi
fi

# 设备信息
echo "== 目标设备 =="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,TRAN "$DEV" 2>/dev/null || true
echo

SIZE_BYTES="$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)"
[ "$SIZE_BYTES" -gt 0 ] || die "无法读取 $DEV 容量"
SIZE_H="$(numfmt --to=iec "$SIZE_BYTES" 2>/dev/null || echo "$SIZE_BYTES")"
if [ "$SIZE_BYTES" -lt $((4 * 1024 * 1024 * 1024)) ]; then
	die "设备容量只有 $SIZE_H，Orange Pi 镜像至少需要 8GB TF 卡"
fi

# 解压
TMP_IMG=""
cleanup() { [ -n "$TMP_IMG" ] && rm -f "$TMP_IMG"; }
trap cleanup EXIT
case "$IMAGE" in
*.xz)
	echo "== 解压 .xz（需要 xz）=="
	command -v xz >/dev/null || die "缺少 xz"
	TMP_IMG="$(mktemp --suffix=.img)"
	xz -dc "$IMAGE" >"$TMP_IMG"
	SRC_IMG="$TMP_IMG"
	;;
*.gz)
	echo "== 解压 .gz =="
	TMP_IMG="$(mktemp --suffix=.img)"
	gzip -dc "$IMAGE" >"$TMP_IMG"
	SRC_IMG="$TMP_IMG"
	;;
*.7z)
	echo "== 解压 .7z（需要 7z）=="
	command -v 7z >/dev/null || die "缺少 7z（p7zip-full）"
	TMP_IMG="$(mktemp --suffix=.img)"
	# 只取 .img，避免把 .sha/.txt 一起拼进镜像
	7z e -so "$IMAGE" "*.img" >"$TMP_IMG"
	SRC_IMG="$TMP_IMG"
	;;
*)
	SRC_IMG="$IMAGE"
	;;
esac
IMG_BYTES="$(stat -c %s "$SRC_IMG")"
IMG_H="$(numfmt --to=iec "$IMG_BYTES" 2>/dev/null || echo "$IMG_BYTES")"
echo "镜像: $IMAGE -> $IMG_H"
if [ "$IMG_BYTES" -gt "$SIZE_BYTES" ]; then
	die "镜像 $IMG_H 大于设备容量 $SIZE_H"
fi

[ "$LIST_ONLY" = 1 ] && exit 0

if [ "$ASSUME_YES" != 1 ]; then
	echo
	echo "!!! 即将清空 $DEV ($SIZE_H) 并写入 $IMAGE"
	echo "!!! 该设备上的所有数据都会丢失。"
	read -r -p "确认请输入 YES: " reply
	[ "$reply" = "YES" ] || die "用户取消"
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo "== 卸载目标分区 =="
for part in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
	if mountpoint -q "$part" 2>/dev/null || findmnt -n "$part" >/dev/null 2>&1; then
		$SUDO umount "$part" || die "无法卸载 $part"
		echo "  已卸载 $part"
	fi
done

echo "== 写入（dd, bs=4M, oflag=direct）=="
$SUDO dd if="$SRC_IMG" of="$DEV" bs=4M conv=fsync oflag=direct status=progress
sync
echo "== 写入完成 =="

if [ "$VERIFY" = 1 ]; then
	echo "== 校验（读回比较前 $IMG_H）=="
	IMG_SUM="$(sha256sum "$SRC_IMG" | cut -d' ' -f1)"
	# 读回校验：镜像大小是 4MiB 整数倍时精确读；否则多读一块再截断。
	# head 提前退出会让 dd 收到 SIGPIPE，pipefail 下会误判失败，故截断时临时关闭 pipefail。
	if [ $((IMG_BYTES % 4194304)) -eq 0 ]; then
		DEV_SUM="$($SUDO dd if="$DEV" bs=4M count=$((IMG_BYTES / 4194304)) \
			iflag=direct status=none | sha256sum | cut -d' ' -f1)"
	else
		set +o pipefail
		DEV_SUM="$($SUDO dd if="$DEV" bs=4M count=$((IMG_BYTES / 4194304 + 1)) \
			iflag=direct status=none 2>/dev/null |
			head -c "$IMG_BYTES" | sha256sum | cut -d' ' -f1)"
		set -o pipefail
	fi
	if [ "$IMG_SUM" = "$DEV_SUM" ]; then
		echo "校验通过: $IMG_SUM"
	else
		die "校验失败: image=$IMG_SUM device=$DEV_SUM"
	fi
fi

$SUDO partprobe "$DEV" 2>/dev/null || true
echo
echo "拔卡前请执行 sync 并安全弹出。首次启动建议接 USB-TTL 看串口日志（115200 8N1）。"
