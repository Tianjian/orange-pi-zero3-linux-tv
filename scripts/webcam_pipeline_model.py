#!/usr/bin/env python3
"""webcam_pipeline_model.py - H618 网络摄像头（USB UVC → H.264 → RTP）性能模型

用法:
  python3 scripts/webcam_pipeline_model.py                 # 默认 30fps、表格式输出
  python3 scripts/webcam_pipeline_model.py --fps 15
  python3 scripts/webcam_pipeline_model.py --encoder x264-veryfast --format mjpeg
  python3 scripts/webcam_pipeline_model.py --json

模型:
  1) USB2.0 带宽上限：按 40 MB/s 有效带宽（480Mbps 理论、UVC 等时传输实测 ~30–40）
  2) 编码耗时：x264 每百万像素的经验成本（4×A53 @1.5GHz，多线程 wall time）
  3) 分辨率/格式决定数字：YUV 原始按 2B/px，RGB 3B/px，MJPEG 按典型帧大小
  4) CPU 占用 = 编码线程数 × 编码耗时 × 实际 fps / 4000（4 核）
  5) 端到端延迟 = 帧间隔 + USB 传输 + 解码/转换 + 编码 + 打包 + 网络 + jitter buffer

所有系数都集中在 FORMATS/ENCODERS，便于用真机数据校准。
"""
from __future__ import annotations

import argparse
import json
import sys

RES = {
    "640x480": (640, 480),
    "1280x720": (1280, 720),
    "1920x1080": (1920, 1080),
}

# 格式: bytes/px（原始）或 MJPEG 典型帧大小 KB；decode_ms_per_mp = 解码+色彩+缩放
FORMATS = {
    "yuyv": {"bpp": 2, "decode_ms_per_mp": 6.0, "desc": "YUYV 4:2:2（UVC 最常见原始格式）"},
    "rgb": {"bpp": 3, "decode_ms_per_mp": 4.0, "desc": "RGB888（少见，多数相机不直接输出）"},
    "mjpeg": {"frame_kb": {"640x480": 50, "1280x720": 120, "1920x1080": 250},
              "decode_ms_per_mp": 15.0, "desc": "MJPEG（解码 CPU 高，但 USB 带宽低）"},
}

# 编码器: ms_per_mp = 4×A53@1.5GHz 多线程 wall time / 百万像素；threads = 实际占用的核数
ENCODERS = {
    "x264-ultrafast": {"ms_per_mp": 85, "threads": 4.0, "latency_ms": 15,
                       "note": "软件，zerolatency，低延迟/低质量，推荐 480p"},
    "x264-veryfast": {"ms_per_mp": 155, "threads": 4.0, "latency_ms": 25,
                      "note": "软件，质量/速度折中，480p 约 20fps"},
    "x264-faster": {"ms_per_mp": 320, "threads": 4.0, "latency_ms": 40,
                    "note": "软件，太慢，仅 480p 低帧率"},
    "hw-h264": {"ms_per_mp": 3, "threads": 0.2, "latency_ms": 8,
                "note": "硬件编码（芯片支持 1080p60；6.1 无驱动，仅 5.4 BSP/Android 厂商栈，未证实）"},
}

USB_MBPS = 40.0        # USB2.0 有效带宽（MB/s）
LAN_MBPS = {"eth100": 11.0, "eth1000": 110.0, "wifi": 5.0}
JITTER_MS = 80         # 接收端 jitter buffer 典型值


def frame_bytes(fmt: str, res: str, w: int, h: int) -> float:
    if fmt == "mjpeg":
        return FORMATS[fmt]["frame_kb"][res] * 1024
    return w * h * FORMATS[fmt]["bpp"]


def analyze(res: str, fmt: str, enc: str, fps: float, bitrate_mbps: float, net: str) -> dict:
    w, h = RES[res]
    mp = w * h / 1e6
    fb = frame_bytes(fmt, res, w, h)

    usb_mbps = fb * fps / 1e6          # MB/s（十进制）
    usb_max_fps = USB_MBPS * 1e6 / fb

    t_usb_ms = fb / (USB_MBPS * 1e6) * 1000
    t_dec_ms = FORMATS[fmt]["decode_ms_per_mp"] * mp
    t_enc_ms = ENCODERS[enc]["ms_per_mp"] * mp
    enc_max_fps = 1000.0 / t_enc_ms

    achievable = min(fps, usb_max_fps, enc_max_fps)
    cpu_pct = ENCODERS[enc]["threads"] * (t_enc_ms / 1000.0) * achievable * 100 / 4.0
    cpu_pct = min(cpu_pct, 400.0)

    net_mbps = bitrate_mbps * 1.05      # RTP/UDP/IP 头 + RTCP
    net_ok = net_mbps <= LAN_MBPS[net] * 8

    latency = (1000.0 / fps) + t_usb_ms + t_dec_ms + t_enc_ms + 1 + net_mbps / (LAN_MBPS[net] * 8) * 1000 + JITTER_MS

    return {
        "res": res, "format": fmt, "encoder": enc,
        "frame_kb": round(fb / 1024, 1),
        "usb_mbps": round(usb_mbps, 1), "usb_max_fps": round(usb_max_fps, 1),
        "decode_ms": round(t_dec_ms, 1),
        "encode_ms": round(t_enc_ms, 1), "encode_max_fps": round(enc_max_fps, 1),
        "achievable_fps": round(achievable, 1),
        "cpu_pct": round(cpu_pct, 0),
        "net_mbps": round(net_mbps, 2), "net_ok": net_ok,
        "latency_ms": round(latency, 0),
        "verdict": ("可用" if achievable >= fps * 0.9 and cpu_pct <= 85 else
                    "勉强" if achievable >= fps * 0.6 and cpu_pct <= 110 else "不可用"),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fps", type=float, default=30)
    ap.add_argument("--bitrate", type=float, default=2.0, help="H.264 目标码率 Mbps")
    ap.add_argument("--net", choices=list(LAN_MBPS), default="eth1000")
    ap.add_argument("--format", choices=list(FORMATS), default=None)
    ap.add_argument("--encoder", choices=list(ENCODERS), default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    results = []
    for res in RES:
        for fmt in ([args.format] if args.format else FORMATS):
            for enc in ([args.encoder] if args.encoder else ENCODERS):
                results.append(analyze(res, fmt, enc, args.fps, args.bitrate, args.net))

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return 0

    print(f"H618 网络摄像头模型 | 目标 {args.fps:g} fps | H.264 {args.bitrate:g} Mbps | 网络 {args.net}")
    print(f"USB2.0 有效 {USB_MBPS:g} MB/s | jitter {JITTER_MS} ms | 4×A53@1.5GHz")
    print()
    head = (f"{'分辨率':10s} {'格式':6s} {'编码器':15s} {'帧KB':>6s} {'USB MB/s':>9s} "
            f"{'编码ms':>7s} {'最大fps':>7s} {'CPU%':>5s} {'延迟ms':>7s} 判定")
    print(head)
    print("-" * len(head))
    for r in results:
        print(f"{r['res']:10s} {r['format']:6s} {r['encoder']:15s} {r['frame_kb']:6.1f} "
              f"{r['usb_mbps']:9.1f} {r['encode_ms']:7.1f} {r['achievable_fps']:7.1f} "
              f"{r['cpu_pct']:5.0f} {r['latency_ms']:7.0f} {r['verdict']}")
    print()
    print("说明:")
    print("  - '最大fps' = min(目标 fps, USB 带宽上限, 编码耗时上限)；CPU% 按编码线程数折算到 4 核。")
    print("  - x264 系数按 4×A53 实测包络校准（ultrafast 65–110 ms/MP，取 85 含 zerolatency）；真机需实测校准。")
    print("  - hw-h264 假设厂商硬件编码可用；官方 6.1 内核没有编码驱动，实际不可用（详见 docs/12）。")
    print("  - 延迟含 33ms 帧间隔 + USB + 解码 + 编码 + 网络 + 80ms jitter；不含显示/解码端。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
