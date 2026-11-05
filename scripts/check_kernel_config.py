#!/usr/bin/env python3
"""check_kernel_config.py - 审计 Linux .config 是否覆盖 Orange Pi Zero 3 (H618) 外设

用法:
  python3 scripts/check_kernel_config.py kernel/out/6.1/.config
  python3 scripts/check_kernel_config.py kernel/out/6.1/.config --csv out.csv
  python3 scripts/check_kernel_config.py kernel/out/6.1/.config \
      --dtb kernel/out/6.1/sun50i-h618-orangepi-zero3.dtb
  python3 scripts/check_kernel_config.py --list-groups

判定:
  y   = 编进内核            m = 模块（rootfs 需要带）
  未设置 = 该外设不可用       NEED = 必选项缺失（退出码 1）
  warn 项缺失只提示，不失败。
"""
from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
from pathlib import Path

# 外设 -> 候选符号（任一命中即可）。required=必选；vendor=True 表示厂商私有符号。
GROUPS = [
    ("架构/平台", ["ARM64", "ARCH_SUNXI", "SUN50I_H616_CCU"], True, False),
    ("时钟/复位", ["COMMON_CLK", "SUN50I_H616_CCU", "SUNXI_CCU"], True, False),
    ("Pinctrl", ["PINCTRL_SUNXI", "PINCTRL_SUN50I_H616"], True, False),
    ("GPIO", ["GPIOLIB"], True, False),
    ("SD/MMC (TF)", ["MMC", "MMC_SUNXI", "MMC_BLOCK"], True, False),
    ("SPI NOR (板载Flash)", ["MTD", "MTD_SPI_NOR", "SPI", "SPI_SUN6I"], True, False),
    ("SPI 用户态 (spidev)", ["SPI_SPIDEV"], True, False),
    ("I2C", ["I2C", "I2C_MV64XXX"], True, False),
    ("I2C 用户态", ["I2C_CHARDEV"], False, False),
    ("UART/控制台", ["SERIAL_8250", "SERIAL_8250_DW", "SERIAL_8250_CONSOLE"], True, False),
    ("PWM", ["PWM", "PWM_SUN4I"], True, False),
    ("红外 IR", ["RC_CORE", "IR_SUNXI"], False, False),
    ("音频 Codec", ["SND_SUN50IW9_CODEC", "SND_SOC_SUNXI_SUN50IW9_CODEC", "SND_SUN4I_CODEC"], True, True),
    ("音频 AHUB/I2S", ["SND_SOC_SUNXI_AHUB", "SND_SUN4I_I2S"], False, True),
    ("HDMI 显示", ["DRM_SUN4I", "DRM_SUN8I_DW_HDMI", "HDMI2_DISP2_SUNXI"], True, False),
    ("GPU (Panfrost)", ["DRM_PANFROST"], False, False),
    ("USB Host", ["USB", "USB_EHCI_HCD", "USB_EHCI_HCD_PLATFORM",
                  "USB_OHCI_HCD", "USB_OHCI_HCD_PLATFORM"], True, False),
    ("USB Gadget (OTG)", ["USB_GADGET", "USB_CONFIGFS"], False, False),
    ("以太网 GMAC", ["NET", "STMMAC_ETH", "DWMAC_SUN8I"], True, False),
    ("以太网 PHY (YT8531)", ["MOTORCOMM_PHY"], True, False),
    ("PMIC AXP313A", ["MFD_AXP20X_RSB", "REGULATOR_AXP20X", "MFD_AXP2101", "REGULATOR_AXP2101", "SUNXI_RSB"], True, True),
    ("温度传感器", ["THERMAL", "SUN8I_THERMAL"], True, False),
    ("看门狗", ["WATCHDOG", "SUNXI_WATCHDOG"], True, False),
    ("RTC", ["RTC_CLASS", "RTC_DRV_SUN6I"], True, False),
    ("板载 LED", ["LEDS_GPIO", "LEDS_TRIGGER_HEARTBEAT"], False, False),
    ("eFuse/chipid", ["NVMEM", "NVMEM_SUNXI_SID"], False, False),
    ("CPU 调频", ["CPU_FREQ", "CPUFREQ_DT", "CPU_FREQ_GOV_ONDEMAND"], False, False),
    ("devtmpfs/initramfs", ["DEVTMPFS", "DEVTMPFS_MOUNT", "BLK_DEV_INITRD"], True, False),
]

WARN_IF_ON = {
    "MODULE_SIG_ALL": "所有模块会被签名；自编 out-of-tree 模块需签名或关闭该选项",
    "MODULE_SIG_FORCE": "强制模块签名，自编模块会拒绝加载",
}

DTB_EXPECT = [
    ("xunlong,orangepi-zero3", "板级 compatible"),
    ("x-powers,axp313a", "PMIC AXP313A"),
    ("allwinner,sun50i-h616", "H616/H618 平台 compatible"),
    ("gpio-leds", "LED 节点"),
    ("mmc-pwrseq-simple", "WiFi 电源序列"),
    ("ethernet-phy", "以太网 PHY"),
    ("motorcomm", "YT8531 PHY 属性"),
    ("jedec,spi-nor", "SPI NOR Flash"),
    ("snps,dw-apb-uart", "UART"),
    ("gpio-keys", "按键（若有）"),
]


def parse_config(path: Path) -> dict[str, str]:
    cfg: dict[str, str] = {}
    for line in path.read_text(errors="replace").splitlines():
        m = re.match(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$", line)
        if m:
            cfg[m.group(1)[7:]] = m.group(2)
            continue
        m = re.match(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$", line)
        if m:
            cfg[m.group(1)[7:]] = "n"
    return cfg


def state(cfg: dict[str, str], sym: str) -> str:
    if sym not in cfg:
        return "absent"
    return cfg[sym]


def audit(cfg: dict[str, str]) -> list[dict[str, str]]:
    rows = []
    for name, candidates, required, vendor in GROUPS:
        found = [(s, state(cfg, s)) for s in candidates if state(cfg, s) not in ("absent", "n")]
        if found:
            sym, val = found[0]
            status = "OK(y)" if val == "y" else ("OK(m)" if val == "m" else f"OK({val})")
            # 展示命中的全部符号，便于看清真正生效的驱动
            syms = " + ".join(s for s, _ in found[:3])
            rows.append({"group": name, "symbol": syms, "value": val,
                         "status": status, "level": "required" if required else "optional",
                         "note": ""})
        else:
            tried = ", ".join(candidates)
            rows.append({"group": name, "symbol": "—", "value": "未设置",
                         "status": "NEED" if required else "miss",
                         "level": "required" if required else "optional",
                         "note": f"候选: {tried}" + ("（厂商私有）" if vendor else "")})
    for sym, why in WARN_IF_ON.items():
        if state(cfg, sym) in ("y", "m"):
            rows.append({"group": "配置风险", "symbol": sym, "value": state(cfg, sym),
                         "status": "WARN", "level": "optional", "note": why})
    return rows


def check_dtb(path: Path) -> list[tuple[str, bool, str]]:
    dtc = None
    for cand in [Path("tools/local/usr/bin/dtc"), Path("/usr/bin/dtc")]:
        if cand.exists():
            dtc = str(cand)
            break
    if dtc is None:
        print("  [WARN] 找不到 dtc，跳过 DTB 检查", file=sys.stderr)
        return []
    try:
        out = subprocess.run([dtc, "-I", "dtb", "-O", "dts", str(path)],
                             capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as exc:
        print(f"  [FAIL] dtc 无法解析 {path}: {exc.stderr.strip()}", file=sys.stderr)
        return []
    return [(needle, needle in out, desc) for needle, desc in DTB_EXPECT]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("config", nargs="?", help="内核 .config 路径")
    ap.add_argument("--dtb", help="可选：同时检查 DTB 节点")
    ap.add_argument("--csv", help="把审计表写成 CSV")
    ap.add_argument("--strict-warn", action="store_true", help="WARN 也返回非 0")
    ap.add_argument("--list-groups", action="store_true")
    args = ap.parse_args()

    if args.list_groups:
        for name, syms, req, vendor in GROUPS:
            print(f"{name:22s} {'/'.join(syms)}")
        return 0
    if not args.config:
        ap.error("需要 .config 路径")

    cfg_path = Path(args.config)
    if not cfg_path.exists():
        ap.error(f"找不到 {cfg_path}")
    cfg = parse_config(cfg_path)
    rows = audit(cfg)

    width = max(len(r["group"]) for r in rows) + 2
    print(f"内核配置审计: {cfg_path}  （{len(cfg)} 个 CONFIG_*）\n")
    print(f"{'外设'.ljust(width)} {'符号':38s} {'值':6s} 状态")
    print("-" * (width + 58))
    for r in rows:
        print(f"{r['group'].ljust(width)} {r['symbol']:38s} {r['value']:6s} {r['status']}")
        if r["status"] in ("NEED", "miss") and r["note"]:
            print(f"{'':{width}}  └ {r['note']}")

    need = [r for r in rows if r["status"] == "NEED"]
    warn = [r for r in rows if r["status"] == "WARN"]
    print(f"\n必选项缺失: {len(need)}   模块/可选缺失: {sum(1 for r in rows if r['status']=='miss')}   风险项: {len(warn)}")

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=["group", "symbol", "value", "status", "level", "note"])
            w.writeheader()
            w.writerows(rows)
        print(f"CSV 已写入 {args.csv}")

    if args.dtb:
        print(f"\nDTB 节点检查: {args.dtb}")
        res = check_dtb(Path(args.dtb))
        for needle, ok, desc in res:
            print(f"  [{'OK' if ok else 'MISS'}] {desc:22s} ({needle})")
        if res and not all(ok for _, ok, _ in res):
            print("  [WARN] 有节点缺失；若对应外设 disabled 属正常（如 i2c3/uart5/spi1 默认关）")

    if need:
        return 1
    if args.strict_warn and warn:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
