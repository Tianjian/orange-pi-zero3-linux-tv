#!/usr/bin/env python3
"""validate_assets.py - 校验 hardware/ 数据资产、文档链接与 GPIO 编号一致性

零依赖（仅标准库）。用法:
    python3 scripts/validate_assets.py            # 全量
    python3 scripts/validate_assets.py --strict   # 有 FAIL 返回 1
    python3 scripts/validate_assets.py --quiet

检查内容:
  1. hardware/pinout_26pin.csv: 26 行、列齐全、脚号 1..26 不重复、
     gpio_line == (bank-'A')*32 + pin、3.3V/5V/GND 存在
  2. hardware/pinout_13pin.csv: 13 行、脚号 1..13 不重复
  3. hardware/h618_gpio_bank.csv: GPIO 编号公式
  4. hardware/pinout_26pin.svg: XML 合法、包含 26 个脚号文本、viewBox 存在
  5. docs/*.md 与 README.md 中的本地相对链接可解析
"""
from __future__ import annotations

import argparse
import csv
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HWD = ROOT / "hardware"

PIN_COLS = ["pin", "header", "signal", "soc_pin", "gpio_line", "wpi", "alt_functions", "voltage", "notes"]
BANK_ROW_COLS = ["pin", "header", "signal", "soc_pin", "gpio_line", "wpi", "alt_functions", "voltage", "notes"]

fails: list[str] = []
warns: list[str] = []
oks: list[str] = []


def ok(msg: str) -> None:
    oks.append(msg)


def fail(msg: str) -> None:
    fails.append(msg)


def warn(msg: str) -> None:
    warns.append(msg)


def gpio_line_of(soc_pin: str) -> int | None:
    """PH5 -> 229；非法返回 None"""
    m = re.fullmatch(r"P([A-Z])(\d{1,2})", soc_pin.strip().upper())
    if not m:
        return None
    bank, pin = m.group(1), int(m.group(2))
    if pin > 31:
        return None
    return (ord(bank) - ord("A")) * 32 + pin


def read_csv(path: Path, cols: list[str]) -> list[dict[str, str]] | None:
    if not path.exists():
        fail(f"{path.relative_to(ROOT)} 不存在")
        return None
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        fail(f"{path.relative_to(ROOT)} 含 UTF-8 BOM")
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"{path.relative_to(ROOT)} 不是 UTF-8: {exc}")
        return None
    rows = list(csv.DictReader(text.splitlines()))
    if not rows:
        fail(f"{path.relative_to(ROOT)} 没有数据行")
        return None
    header = list(rows[0].keys())
    if header != cols:
        fail(f"{path.relative_to(ROOT)} 表头不符: {header} != {cols}")
    return rows


def check_pinout(path: Path, expected_rows: int) -> None:
    rel = path.relative_to(ROOT)
    rows = read_csv(path, PIN_COLS)
    if rows is None:
        return
    if len(rows) != expected_rows:
        fail(f"{rel}: 期望 {expected_rows} 行，实际 {len(rows)} 行")

    pins = []
    for i, row in enumerate(rows, start=2):
        raw_pin = (row.get("pin") or "").strip()
        if not raw_pin.isdigit():
            fail(f"{rel}:{i} pin 不是数字: {raw_pin!r}")
            continue
        pin = int(raw_pin)
        pins.append(pin)
        soc = (row.get("soc_pin") or "").strip()
        line_s = (row.get("gpio_line") or "").strip()
        if soc and soc.upper() != "NC":
            expect = gpio_line_of(soc)
            if expect is None:
                fail(f"{rel}:{i} soc_pin 格式非法: {soc!r}")
            elif line_s and line_s != str(expect):
                fail(f"{rel}:{i} {soc} 应为 line {expect}，实为 {line_s}")
            elif not line_s:
                warn(f"{rel}:{i} {soc} gpio_line 为空")
            else:
                ok(f"{rel}:{i} {soc} -> {line_s}")
        elif line_s:
            warn(f"{rel}:{i} 非 GPIO 脚却填了 gpio_line={line_s}")

    dup = sorted({p for p in pins if pins.count(p) > 1})
    if dup:
        fail(f"{rel}: 重复脚号 {dup}")
    if sorted(pins) != list(range(1, expected_rows + 1)):
        missing = sorted(set(range(1, expected_rows + 1)) - set(pins))
        fail(f"{rel}: 脚号不连续，缺 {missing}")

    volts = " ".join((r.get("voltage") or "") for r in rows).upper()
    for token in ("3.3", "5"):
        if token not in volts:
            warn(f"{rel}: 未找到 {token} 电源脚标注")
    if "GND" not in " ".join((r.get("signal") or "") for r in rows).upper():
        warn(f"{rel}: 未找到 GND 标注")


def check_gpio_bank() -> None:
    path = HWD / "h618_gpio_bank.csv"
    rel = path.relative_to(ROOT)
    rows = read_csv(path, ["bank", "pin", "gpio_line", "pinctrl_name", "function"])
    if rows is None:
        return
    for i, row in enumerate(rows, start=2):
        pinctrl = (row.get("pinctrl_name") or "").strip()
        line_s = (row.get("gpio_line") or "").strip()
        expect = gpio_line_of(pinctrl)
        if expect is None:
            fail(f"{rel}:{i} pinctrl_name 非法: {pinctrl!r}")
        elif line_s != str(expect):
            fail(f"{rel}:{i} {pinctrl} 应为 {expect}，实为 {line_s}")
        else:
            ok(f"{rel}:{i} {pinctrl}={line_s}")


def check_svg() -> None:
    path = HWD / "pinout_26pin.svg"
    rel = path.relative_to(ROOT)
    if not path.exists():
        fail(f"{rel} 不存在")
        return
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        fail(f"{rel} XML 非法: {exc}")
        return
    root = tree.getroot()
    if "viewBox" not in root.attrib:
        fail(f"{rel} 缺少 viewBox")
    text = "".join(t for t in root.itertext())
    missing = [str(n) for n in range(1, 27) if not re.search(rf"(?<!\d){n}(?!\d)", text)]
    if missing:
        fail(f"{rel} 缺少脚号文本: {missing}")
    else:
        ok(f"{rel} 含 1..26 全部脚号")


MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")


def check_links() -> None:
    mds = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md")), *sorted((ROOT / "hardware").glob("*.md"))]
    for md in mds:
        if not md.exists():
            continue
        text = md.read_text(encoding="utf-8", errors="replace")
        for target in MD_LINK.findall(text):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            resolved = (md.parent / target).resolve()
            if not resolved.exists():
                fail(f"{md.relative_to(ROOT)}: 链接目标不存在 -> {target}")
        ok(f"{md.relative_to(ROOT)} 链接检查")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    check_pinout(HWD / "pinout_26pin.csv", 26)
    check_pinout(HWD / "pinout_13pin.csv", 13)
    check_gpio_bank()
    check_svg()
    check_links()

    if not args.quiet:
        for m in oks:
            print(f"  [ OK ] {m}")
        for m in warns:
            print(f"  [WARN] {m}")
        for m in fails:
            print(f"  [FAIL] {m}")
    print(f"\n结果: OK={len(oks)} WARN={len(warns)} FAIL={len(fails)}")
    if args.strict and fails:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
