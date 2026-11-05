#!/usr/bin/env python3
"""yolo_perf_model.py - H618（Orange Pi Zero 3）YOLO 推理性能理论模型

用法:
  python3 scripts/yolo_perf_model.py                         # 640x480, fp32+int8, 默认模型
  python3 scripts/yolo_perf_model.py --input 320x320
  python3 scripts/yolo_perf_model.py --precision int8 --camera 30
  python3 scripts/yolo_perf_model.py --json
  python3 scripts/yolo_perf_model.py --peak-gflops 48.4 --eff-low 0.08 --eff-high 0.20

模型:
  t_infer = FLOPs(input) / (peak_gflops * efficiency)
  t_frame = t_pre + t_infer + t_post
  FPS     = min(camera_fps, 1000 / t_frame)
  latency = 1000/camera_fps (等待下一帧) + t_frame   （未做流水线重叠时）

输入缩放: 以 640x640 的官方 GFLOPs 为基准，按像素面积线性缩放
（YOLO 的 backbone/neck/head 都与输入面积近似成正比；stride=32 要求宽高是 32 的倍数）。
"""
from __future__ import annotations

import argparse
import json
import sys

# 模型: 名称 -> (参数量 M, GFLOPs @640x640, 备注)
MODELS = {
    "yolov5n": (1.9, 1.9, "Ultralytics YOLOv5 nano"),
    "yolov5s": (7.2, 7.2, "YOLOv5 small"),
    "yolov8n": (3.2, 8.7, "Ultralytics YOLOv8 nano"),
    "yolov8s": (11.2, 28.6, "YOLOv8 small"),
    "yolov11n": (2.6, 6.3, "Ultralytics YOLO11 nano"),
    "yolov11s": (9.4, 21.5, "YOLO11 small"),
}

# 硬件基线（可覆盖）
HW = {
    "cores": 4,
    "freq_ghz": 1.512,
    "fp32_flop_per_cycle_per_core": 8.0,   # 4 lanes x 2 (FMA)
    "ddr_gbs": 12.8,                        # LPDDR4 32-bit 1600MT/s 保守值；2400MT/s=19.2
}


def peak_gflops(args) -> float:
    if args.peak_gflops:
        return args.peak_gflops
    return HW["cores"] * HW["fp32_flop_per_cycle_per_core"] * HW["freq_ghz"]


def flops_at(flops640: float, w: int, h: int) -> float:
    return flops640 * (w * h) / (640 * 640)


def estimate(model: str, w: int, h: int, precision: str, eff_low: float, eff_high: float,
             pre_ms: float, post_ms: float, camera_fps: float, peak: float,
             int8_gain: float = 2.0) -> dict:
    params_m, flops640, note = MODELS[model]
    flops = flops_at(flops640, w, h)

    if precision == "fp32":
        e_low, e_high = eff_low, eff_high
        mult = 1.0
    else:  # int8: TFLite 整网 2.0~2.5x；A53 无 SDOT，收益主要来自权重/带宽减 4x
        mult = int8_gain
        e_low, e_high = min(0.9, eff_low * mult), min(0.95, eff_high * mult)

    # 有效算力（GFLOP/s 或 GOP/s）
    f_low, f_high = peak * e_low, peak * e_high
    t_infer_high_ms = flops / f_low * 1000.0   # 慢端
    t_infer_low_ms = flops / f_high * 1000.0   # 快端
    t_frame_low = pre_ms + t_infer_low_ms + post_ms
    t_frame_high = pre_ms + t_infer_high_ms + post_ms
    fps_low = min(camera_fps, 1000.0 / t_frame_high)
    fps_high = min(camera_fps, 1000.0 / t_frame_low)
    # 未流水线时：等一帧 + 处理
    lat_low = 1000.0 / camera_fps + t_frame_low
    lat_high = 1000.0 / camera_fps + t_frame_high

    return {
        "model": model,
        "precision": precision,
        "input": f"{w}x{h}",
        "params_m": params_m,
        "flops_g": round(flops, 2),
        "peak_upper_fps": round(1000.0 / (flops / peak * 1000.0), 1),  # 100% MAC 上限
        "eff": f"{e_low*100:.0f}-{e_high*100:.0f}%",
        "infer_ms": (round(t_infer_low_ms), round(t_infer_high_ms)),
        "fps": (round(fps_low, 1), round(fps_high, 1)),
        "latency_ms": (round(lat_low), round(lat_high)),
        "note": note,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="640x480", help="WxH，宽高需为 32 的倍数")
    ap.add_argument("--precision", choices=["fp32", "int8"], default="fp32")
    ap.add_argument("--camera", type=float, default=30.0, help="相机帧率")
    ap.add_argument("--eff-low", type=float, default=0.08, help="fp32 低效率（默认 8%%）")
    ap.add_argument("--eff-high", type=float, default=0.16, help="fp32 高效率（默认 16%%）")
    ap.add_argument("--pre-ms", type=float, default=10.0, help="预处理（色彩/缩放/归一化）每帧 ms")
    ap.add_argument("--post-ms", type=float, default=5.0, help="后处理（NMS/解码）每帧 ms")
    ap.add_argument("--peak-gflops", type=float, default=0.0, help="覆盖峰值算力")
    ap.add_argument("--int8-gain", type=float, default=2.0, help="int8 相对 fp32 的整网加速比（默认 2.0）")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    try:
        w, h = (int(x) for x in args.input.lower().split("x"))
    except ValueError:
        ap.error("--input 格式应为 WxH，例如 640x480")
    if w % 32 or h % 32:
        print(f"警告: {w}x{h} 不是 32 的倍数，YOLO 需 letterbox 到 32 的倍数", file=sys.stderr)

    peak = peak_gflops(args)
    rows = [estimate(m, w, h, args.precision, args.eff_low, args.eff_high,
                     args.pre_ms, args.post_ms, args.camera, peak, args.int8_gain) for m in MODELS]

    if args.json:
        print(json.dumps({"peak_gflops": peak, "rows": rows}, ensure_ascii=False, indent=2))
        return 0

    print(f"H618 YOLO 理论性能模型  |  输入 {w}x{h}  |  {args.precision}  |  相机 {args.camera:g}fps")
    print(f"峰值算力 {peak:.1f} GFLOP/s（4×A53 × 8 FLOP/cycle × {HW['freq_ghz']}GHz）"
          f"，DDR {HW['ddr_gbs']}~19.2 GB/s，预处理 {args.pre_ms:g}ms，后处理 {args.post_ms:g}ms")
    print()
    head = f"{'模型':9s} {'参数M':>5s} {'GFLOPs':>7s} {'100%上限':>8s} {'效率':>8s} {'推理ms':>13s} {'FPS':>9s} {'端到端ms':>11s}"
    print(head)
    print("-" * len(head))
    for r in rows:
        print(f"{r['model']:9s} {r['params_m']:5.1f} {r['flops_g']:7.2f} "
              f"{r['peak_upper_fps']:8.1f} {r['eff']:>8s} "
              f"{r['infer_ms'][0]:5d}–{r['infer_ms'][1]:<6d} "
              f"{r['fps'][0]:4.1f}–{r['fps'][1]:<4.1f} "
              f"{r['latency_ms'][0]:4d}–{r['latency_ms'][1]:<5d}")
    print()
    print("说明:")
    print("  100%上限 = FLOPs / 峰值算力，忽略内存墙/深度可分离卷积效率，现实中不可能达到。")
    print(f"  推理ms/FPS 区间来自 fp32 有效效率 {args.eff_low*100:.0f}–{args.eff_high*100:.0f}%（可调）；int8 按 {args.int8_gain:g}× 估算。")
    print("  端到端 = 等一帧(1000/相机fps) + 预处理 + 推理 + 后处理；流水线可隐藏等待帧。")
    print("  未计入 USB 传输/曝光（相机自身帧率已覆盖）与热降频；持续满载可能掉 10–30%。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
