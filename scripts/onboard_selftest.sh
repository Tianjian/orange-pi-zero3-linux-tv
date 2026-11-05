#!/usr/bin/env bash
# onboard_selftest.sh - 在 Orange Pi Zero 3 板子上运行，输出开发环境体检报告
#
# 用法（在板子上）:
#   bash onboard_selftest.sh              # 打印到屏幕
#   bash onboard_selftest.sh --out r.txt  # 同时保存
#   bash onboard_selftest.sh --full       # 附带 gpio readall / i2cdetect 等详细输出
#
# 说明: 只读检查，会尝试读取 /sys、/proc、设备节点，不修改配置。
set -uo pipefail

OUT=""
FULL=0
for arg in "$@"; do
	case "$arg" in
	--out)
		OUT="${2:-}"
		shift 2 || true
		;;
	--full) FULL=1; shift ;;
	-h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) shift ;;
	esac
done

REPORT=""
say() { REPORT+="$*"$'\n'; }
sec() { say ""; say "===== $* ====="; }
kv() {
	local k="$1" v="${2:-}"
	[ -n "$v" ] && say "$(printf '%-22s' "$k"): $v"
}
have() { command -v "$1" >/dev/null 2>&1; }

sec "板卡身份"
[ -r /proc/device-tree/model ] && kv "model" "$(tr -d '\0' </proc/device-tree/model)"
[ -r /proc/device-tree/compatible ] && kv "compatible" "$(tr '\0' ' ' </proc/device-tree/compatible)"
kv "hostname" "$(hostname)"
kv "chipid" "$(grep -h chipid /sys/class/sunxi_info/sys_info 2>/dev/null | awk -F: '{print $2}' | xargs)"
kv "SoC" "$(grep -m1 -E 'Hardware|Revision' /proc/cpuinfo | tr '\n' ' ')"
kv "内核" "$(uname -sr)"
kv "架构" "$(uname -m)"
if [ -r /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	kv "发行版" "${PRETTY_NAME:-unknown}"
fi
kv "启动时间" "$(uptime -p 2>/dev/null || uptime)"
kv "运行时长(s)" "$(cut -d. -f1 /proc/uptime)"

sec "CPU / 内存"
kv "CPU 核数" "$(nproc)"
kv "CPU 型号" "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
kv "当前频率" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo n/a) kHz"
kv "调频策略" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
kv "内存" "$(awk '/MemTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo)"
kv "可用内存" "$(awk '/MemAvailable/{printf "%.0f MB", $2/1024}' /proc/meminfo)"
kv "swap" "$(awk '/SwapTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo)"

sec "温度 / 电源"
for z in /sys/class/thermal/thermal_zone*; do
	[ -d "$z" ] || continue
	t=$(cat "$z/temp" 2>/dev/null || echo 0)
	kv "$(basename "$z") $(cat "$z/type" 2>/dev/null)" "$(awk -v t="$t" 'BEGIN{printf "%.1f C", t/1000}')"
done
for f in /sys/class/power_supply/*/voltage_now; do
	[ -r "$f" ] && kv "电源电压" "$(awk -v v="$(cat "$f")" 'BEGIN{printf "%.2f V", v/1000000}')"
done
have vcgencmd && kv "vcgencmd" "$(vcgencmd measure_temp 2>/dev/null)"

sec "存储"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null | sed 's/^/  /'
kv "SPI Flash" "$(ls /dev/mtd* 2>/dev/null | tr '\n' ' ')"
kv "rootfs 使用率" "$(df -h / | awk 'NR==2{print $5" of "$2}')"

sec "GPIO"
kv "gpiochip 设备" "$(ls /dev/gpiochip* 2>/dev/null | tr '\n' ' ')"
for c in /dev/gpiochip*; do
	[ -e "$c" ] || continue
	kv "$c" "$(cat /sys/class/gpio/gpiochip$(basename "$c" | tr -dc 0-9)/label 2>/dev/null || echo '')"
done
if have gpioinfo; then
	kv "gpioinfo 行数" "$(gpioinfo 2>/dev/null | wc -l)"
else
	say "  （无 gpioinfo，libgpiod 未安装；示例程序用 ioctl 不依赖它）"
fi
if have gpio; then
	kv "wiringOP" "$(gpio -v 2>&1 | head -2 | tr '\n' ' ')"
	[ "$FULL" = 1 ] && gpio readall 2>&1 | sed 's/^/  /'
else
	say "  （无 wiringOP gpio 命令；官方镜像应预装）"
fi

sec "总线设备节点"
kv "i2c" "$(ls /dev/i2c-* 2>/dev/null | tr '\n' ' ')"
kv "spi" "$(ls /dev/spidev* 2>/dev/null | tr '\n' ' ')"
kv "uart" "$(ls /dev/ttyS* /dev/ttyAS* 2>/dev/null | tr '\n' ' ')"
kv "pwm" "$(ls -d /sys/class/pwm/pwmchip* 2>/dev/null | tr '\n' ' ')"
[ -d /sys/class/pwm/pwmchip0 ] && kv "pwm 已导出" "$(ls /sys/class/pwm/pwmchip0/ 2>/dev/null | grep -c '^pwm') 个"
have i2cdetect && [ -e /dev/i2c-3 ] && {
	say "  i2cdetect -y 3:"
	i2cdetect -y 3 2>&1 | sed 's/^/    /'
}

sec "网络"
kv "接口" "$(ip -br addr 2>/dev/null | awk '{printf "%s(%s) ", $1, $3}')"
kv "默认路由" "$(ip route show default 2>/dev/null | head -1)"
kv "WiFi" "$(iw dev 2>/dev/null | awk '/Interface|ssid/{printf "%s ", $0}')"
kv "蓝牙" "$(hciconfig 2>/dev/null | grep -m1 'BD Address' | xargs)"
have nmcli && kv "nmcli" "$(nmcli -t -f DEVICE,STATE,CONNECTION dev 2>/dev/null | tr '\n' ' ')"

sec "USB / 显示 / 音频"
have lsusb && lsusb 2>/dev/null | sed 's/^/  /'
kv "HDMI 状态" "$(cat /sys/class/drm/card*-HDMI-A-1/status 2>/dev/null | tr '\n' ' ')"
kv "声卡" "$(grep -c . /proc/asound/cards 2>/dev/null) 行"

sec "服务与内核模块"
kv "overlayroot" "$(mount 2>/dev/null | grep -c 'overlay on / ' )"
kv "sunxi 相关模块" "$(lsmod 2>/dev/null | awk '/sunxi|dwmac|aw859|8723|xradio/{printf "%s ", $1}')"
kv "dmesg 错误行" "$(dmesg 2>/dev/null | grep -ciE '\berror\b|failed')"
have systemctl && kv "失败的服务" "$(systemctl --failed --no-legend 2>/dev/null | wc -l)"

sec "预装开发工具"
for t in gcc make python3 git docker i2cdetect spidev_test watchdog_test; do
	if have "$t"; then kv "$t" "$(command -v "$t")"; else kv "$t" "未安装"; fi
done
kv "内核头文件" "$(ls -d /usr/src/linux-headers-$(uname -r) 2>/dev/null || echo '未安装（apt install linux-headers-$(uname -r)）')"

sec "结论提示"
say "  - 若 i2c/spi/pwm 节点缺失：sudo orangepi-config -> System -> Hardware 勾选后重启"
say "  - 若温度 > 80C：检查散热，H618 无风扇时建议加散热片"
say "  - 若 dmesg 错误多：dmesg -T | tail -50 查看"

printf '%s' "$REPORT"
if [ -n "$OUT" ]; then
	printf '%s' "$REPORT" >"$OUT"
	echo
	echo "报告已保存: $OUT"
fi
