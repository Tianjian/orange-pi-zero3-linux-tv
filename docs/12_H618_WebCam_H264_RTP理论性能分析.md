# 12 · H618 网络摄像头（USB2.0 UVC → H.264 → RTP）理论性能分析

> 问题：Orange Pi Zero 3（Allwinner H618）接 **USB2.0 UVC 摄像头**，抓 640×480（或 720p/1080p）
> 图像帧，做 **H.264 编码**，再通过 **RTP** 推流，理论性能到什么程度？能不能当“网络摄像头/WebCam”用？
>
> 先说结论：**芯片本身有 H.264 硬件编码器（H616 brief：4K@25 / 1080p@60），但官方 Linux 6.1 内核
> 没有编码驱动；5.4 BSP 只有厂商私有 `cedar_dev`，没有标准 V4L2/FFmpeg/GStreamer 硬编路径。**
> 因此在官方 6.1 上只能 **软件 x264**：**640×480@30 是临界可用（ultrafast，约 3.5 个核）**，
> **720p@30 做不到（约 10 fps）**，**1080p 只有 3–5 fps**。要 720p/1080p 实时，必须走 Android/厂商硬编栈，
> 或换带 VENC 的板（RK3566/RK3588 等）。
>
> 数据来源：本仓库 `docs/01`–`docs/11`、`docs/source/h616-soc.pdf`、6.1/5.4 内核源码、
> [docs/evidence/webcam_benchmarks.md](evidence/webcam_benchmarks.md)（实测锚点）。
> 计算过程：[scripts/webcam_pipeline_model.py](../scripts/webcam_pipeline_model.py)。

---

## 0. 结论速览（官方 6.1 Linux、纯 CPU、目标 30 fps、H.264 2 Mbps）

| 分辨率 | 相机格式 | 编码器 | 编码耗时 | 可达 FPS | 4 核占用 | 端到端延迟 | 判定 |
|---|---|---|---:|---:|---:|---:|---|
| **640×480** | YUYV | x264 ultrafast | 26 ms | **30.0** | 78% | ~160 ms | **可用（临界）** |
| 640×480 | YUYV | x264 veryfast | 48 ms | 21.0 | 100% | ~182 ms | 只能 21 fps |
| 640×480 | MJPEG | x264 ultrafast | 26 ms | 30.0 | 78% | ~149 ms | 推荐（省 USB） |
| **1280×720** | MJPEG | x264 ultrafast | 78 ms | **12.8** | 100% | ~212 ms | **30 fps 不可用** |
| 1280×720 | YUYV | — | — | USB 上限 21.7 | — | — | 30 fps 也超 USB |
| **1920×1080** | MJPEG | x264 ultrafast | 176 ms | **5.7** | 100% | ~330 ms | 不可用 |
| 1920×1080 | MJPEG | **硬件编码** | ~6 ms | 30（USB/解码允许） | ~25%（解码） | ~160 ms | **仅 5.4/Android 厂商栈（未证实）** |

**一句话选型**：
- **640×480@30**：软件 x264 **ultrafast + zerolatency**，4 线程，MJPEG 采集；编码占约 **78%** 的 4 核，加上 MJPEG 解码/网络后接近饱和，建议实际跑 **20–25 fps** 留余量。
- **640×480@15–20**：ultrafast 约 40–52% CPU，veryfast 也可（21 fps 上限），画质更好。
- **720p/1080p 实时**：官方 6.1 做不到（720p ≈ 13 fps、1080p ≈ 5.7 fps）；要么 Android/5.4 厂商硬编，要么换板。
- USB2.0 只限制 **720p YUYV@30**（55 MB/s > 40 MB/s）和 1080p 原始格式；**MJPEG 不受 USB 限制**。

---

## 1. 系统边界

```
USB2.0 UVC 相机                      H618 (4×A53@1.512GHz)                        网络
┌──────────────┐   YUYV/MJPEG   ┌──────────────────────────────────────────┐   H.264/RTP   ┌────────┐
│  sensor/ISP  │ ─────────────► │ V4L2 采集 → (MJPEG 解码) → 色彩/缩放      │ ────────────► │ 接收端 │
│  640×480@30  │   18.4 MB/s    │ → H.264 编码（软 x264 / 硬编码）→ RTP 打包 │   1–8 Mbps    │ 解码/显示│
└──────────────┘                └──────────────────────────────────────────┘               └────────┘
```

- “WebCam”这里按 **网络摄像头（RTP/RTSP 推流）** 分析；不是 USB UVC gadget（把板子当 USB 摄像头插到 PC）。
- 若做 UVC gadget，Linux 端需要用 `g_webcam`/`uvc-gadget`，且 H.264 UVC 主机兼容性差，不在本文范围。
- 相机输出通常是 **YUYV 或 MJPEG**，不是 RGB888；RGB 是主机侧转换结果。

---

## 2. 硬件能力 vs Linux 现实（最关键的一节）

### 2.1 芯片确实有 H.264 编码器

H616/H618 产品简介（`docs/source/h616-soc.pdf`）：

> “H.264 BP/MP/HP encoder up to **4K@25fps or 1080p@60fps**”；框图标注 “H.264 4K@25fps Video Encoder”。

所以“H618 不能编码 H.264”是错的——**芯片有能力**。问题在驱动/用户态。

### 2.2 官方 6.1 内核：只有解码，没有编码

在本次构建的 6.1.31 源码里核实：

| 事实 | 证据 |
|---|---|
| 6.1 只有 `cedrus` **解码**驱动 | `hardware/ref/cedrus-6.1/cedrus.c` 的 `sun50i_h616_cedrus_variant` 能力集只有 `H264_DEC/H265_DEC/VP8_DEC/MPEG2_DEC`，**没有 ENC** |
| 6.1 没有任何 Allwinner 编码驱动 | 全树 grep `cedar_dev/VIDEO_ENCODER_DECODER_SUNXI/venc` 无命中；`drivers/media/platform/sunxi/` 只有 CSI/rotate/DI |
| .config 里也没有编码器 | `CONFIG_VIDEO_SUNXI_CEDRUS=m`（解码）；无任何 `*_VENC/*_ENCODER` |
| 因此 `/dev/video*` 只有解码 M2M | FFmpeg `h264_v4l2m2m` / GStreamer `v4l2h264enc` **无设备可用** |

### 2.3 5.4 BSP：有厂商 `cedar_dev`，但不是标准 V4L2

- 5.4 树里有 `drivers/media/cedar-ve/`（摘录见 `hardware/ref/cedar-ve-5.4/`），Kconfig `VIDEO_ENCODER_DECODER_SUNXI`（模块名 `cedar_dev`），
  官方 5.4 .config 里 **`CONFIG_VIDEO_ENCODER_DECODER_SUNXI=y`**。
- 驱动里有 `VE_LOCK_VENC`、编码引擎 IRQ 字段——**VE 硬件引擎包含编码通道**。
- 但它是 **字符设备 + 私有 ioctl**（`IOCTL_WAIT_VE_DE/EN`、`IOCTL_ENGINE_REQ`…），
  不是 V4L2 M2M，也没有进 FFmpeg/GStreamer；要用必须配 Allwinner 的 **MPP/libvencoder** 私有用户态。
- 本仓库的 5.4 源码只做了 media 目录的稀疏检出，未验证用户态；**“5.4 能硬编”目前是未证实**。
- 2026-11 有[社区帖](https://www.firebbs.cn/forum.php?mod=viewthread&tid=41890)声称给 H618 写了 `sunxi_venc.ko`
  （V4L2 M2M 编码，复用 BSP `sunxi-cedar` 平台设备），但**无仓库、无日志、无 fps**，
  不能作为可用性证据（详见 evidence §9.2）。
- Android 12 镜像有厂商完整多媒体栈，硬编可用（但那就不是 Linux WebCam 方案了）。

### 2.4 结论

| 路线 | H.264 编码 | 可行性 |
|---|---|---|
| **官方 6.1（推荐）** | **软件 x264** | ✅ 可维护、标准 GStreamer/FFmpeg |
| 官方 5.4 BSP | 厂商 `cedar_dev` 硬编（需私有 MPP） | ⚠️ 未证实、不可维护、无标准管线 |
| Android 12 | 厂商硬编 | ✅ 但非 Linux |
| 换板（RK3566/RK3588） | 标准 V4L2 MPP 硬编 | ✅ 推荐用于 1080p 产品 |

**所以本文的主线是“软件 x264”**；硬件编码作为“有条件可行”单独讨论（§6）。

---

## 3. USB2.0 相机带宽与格式

USB2.0 理论 480 Mbps = 60 MB/s；UVC 等时传输实测有效 **约 30–40 MB/s**（按 40 MB/s 估算）。

| 分辨率 | 格式 | 每帧 | 30 fps 需要 | 40 MB/s 下最大 fps | 说明 |
|---|---|---:|---:|---:|---|
| 640×480 | YUYV | 600 KB | 18.4 MB/s | ~65 | ✅ 30 fps 轻松 |
| 640×480 | RGB888 | 900 KB | 27.6 MB/s | ~43 | ✅ 但多数相机不直接给 RGB |
| 640×480 | MJPEG（50 KB/帧） | 50 KB | 1.5 MB/s | 800 | ✅ 最省带宽，解码耗 CPU |
| 1280×720 | YUYV | 1.76 MB | **55.3 MB/s** | **~21.7** | ❌ 30 fps 超 USB2 |
| 1280×720 | MJPEG（120 KB/帧） | 120 KB | 3.7 MB/s | 333 | ✅ 720p30 必须用 MJPEG |
| 1920×1080 | YUYV | 3.96 MB | **124 MB/s** | **~9.6** | ❌ 不可行 |
| 1920×1080 | MJPEG（250 KB/帧） | 250 KB | 7.7 MB/s | 160 | ✅ 带宽够，解码重 |

> 设备侧证据：ELP 等 UVC 模块规格直接写 **720p YUYV@10 / MJPEG@30**，与上表一致——
> USB2.0 上 720p 只能靠 MJPEG 上 30fps。
> 结论：**480p 可以用 YUYV；720p/1080p 必须 MJPEG**（或 H.264 相机，但 UVC H.264 主机兼容性差）。
> 同一 USB2.0 控制器上再接存储盘/网卡会抢带宽；相机独占一个口最稳。

---

## 4. 软件 x264 在 4×A53@1.5GHz 上有多快

### 4.1 估算模型

x264 的耗时与像素数近似成正比，与 preset 强相关。以 4 核并行、`-tune zerolatency` 为前提：

```
t_encode ≈ k(preset) × 百万像素
k(ultrafast) ≈ 85 ms/MP（实测包络 65–110）, k(veryfast) ≈ 155, k(faster) ≈ 320
```

- 640×480 = 0.307 MP → ultrafast ≈ **26 ms/帧（38 fps 上限）**、veryfast ≈ 48 ms（21 fps）、faster ≈ 98 ms（10 fps）。
- 1280×720 = 0.92 MP → ultrafast ≈ **78 ms（12.8 fps）**、veryfast ≈ 143 ms（7 fps）。
- 1920×1080 = 2.07 MP → ultrafast ≈ **176 ms（5.7 fps）**、veryfast ≈ 321 ms（3.1 fps）。

> 系数已按实测锚点校准（4×A53@1.2–1.5GHz、4 线程、zerolatency；误差 ±30%）：
> RPi 3B+ 1080p libx264 实测 **6–7 fps**、RPi 3 720p ultrafast（含 x11grab）**≈7 fps**、
> RPi 5 官方 1080p30 ultrafast 占单核 60%。`-tune zerolatency` 用 sliced-threads，比普通帧级线程低 10–20%。
> **必须用 §9 的方法在真板校准**。

### 4.2 30 fps 下的 CPU 占用

| 分辨率 | preset | 编码 ms/帧 | 30 fps 需要 | 4 核占用 | 结论 |
|---|---|---:|---:|---:|---|
| 640×480 | ultrafast | 26 | 3.1 核 | **~78%** | 临界可用，建议 25–30 fps |
| 640×480 | veryfast | 48 | 5.7 核 | 100%（21 fps 饱和） | 只能 ~21 fps |
| 1280×720 | ultrafast | 78 | 9.4 核 | 100%（12.8 fps 饱和） | 只能 ~13 fps |
| 1920×1080 | ultrafast | 176 | 21 核 | 100%（5.7 fps 饱和） | 只能 ~5.7 fps |

> 注意：上表 CPU 是“编码线程占用”；还要加上 **MJPEG 解码 0.3–1 核**、V4L2/网络/系统开销。
> 所以 480p30 实际是 **4 核满载边缘**，必须 headless、关桌面、固定 performance governor。

---

## 5. 端到端性能表（30 fps 目标，官方 6.1，软件编码）

| 分辨率 | 格式 | 编码器 | 可达 fps | CPU（4 核） | 延迟（含 80ms jitter） | 判定 |
|---|---|---|---:|---:|---:|---|
| 640×480 | YUYV | ultrafast | 30.0 | 78% | 160 ms | 可用（临界） |
| 640×480 | MJPEG | ultrafast | 30.0 | 78% | 149 ms | 可用（推荐） |
| 640×480 | MJPEG | veryfast | 21.0 | 100% | 170 ms | 21 fps 稳定 |
| 1280×720 | MJPEG | ultrafast | 12.8 | 100% | 212 ms | 不可用（30fps） |
| 1280×720 | MJPEG | veryfast | 7.0 | 100% | 276 ms | 不可用 |
| 1920×1080 | MJPEG | ultrafast | 5.7 | 100% | 330 ms | 不可用 |
| 1920×1080 | MJPEG | **硬编** | 30 | ~1 核（解码） | 160 ms | 仅 5.4/Android（未证实） |

### 5.1 延迟构成（480p30 软件）

| 阶段 | 典型值 |
|---|---:|
| 帧间隔（30fps） | 33 ms |
| USB 传输（600KB @40MB/s） | 15 ms |
| MJPEG 解码 + 色彩/缩放 | 5–10 ms |
| x264 编码（ultrafast，zerolatency） | 25–35 ms |
| RTP 打包 + UDP | <1 ms |
| 网络（千兆 LAN） | 1–3 ms |
| 接收端 jitter buffer | 50–200 ms（GStreamer 默认 200ms，可调） |
| **合计（glass-to-glass）** | **~150–300 ms** |

> 不用 `-tune zerolatency`：编码器会缓冲 2–4 帧，延迟 +70–130 ms；
> 接收端 jitter buffer 是最大可调项，GStreamer `rtpjitterbuffer` **默认 latency=200ms**；
> 默认管线在 RPi3 上实测可到 ~5s 延迟，必须 `tune=zerolatency` + `sync=false` + 小 jitter buffer，
> 调优后 ~100–150ms。

---

## 6. 硬件编码路径（有条件可行，但别当默认方案）

假设走 **5.4 BSP + Allwinner MPP/libvencoder** 或 **Android 12**：

| 分辨率 | USB 格式 | 解码/前处理 | 硬编 | 结论 |
|---|---|---|---:|---|
| 1080p30 | MJPEG 7.7 MB/s | ~31 ms/帧（libjpeg-turbo，约 1 核） | ~6 ms | **可行**（解码是瓶颈，约 32 fps 上限） |
| 1080p30 | YUYV | 124 MB/s | — | USB2.0 不可行 |
| 720p30 | MJPEG 3.7 MB/s | ~14 ms | ~3 ms | 很轻松 |
| 720p60 | MJPEG | ~14 ms | ~3 ms | 可能，但 USB/相机要支持 |

但要注意：
- **官方 6.1 没有编码驱动**，以上需要换 5.4 内核 + 私有用户态；本仓库未验证。
- 私有栈的维护成本高、与主线 GStreamer/FFmpeg 不兼容；量产不建议。
- 若产品必须 1080p30，**换 RK3566/RK3588（标准 V4L2 MPP 硬编）** 更稳。

---

## 7. RTP / 网络

H.264 over RTP（RFC 6184）开销很小：

| 码率 | 包率（1200B payload） | RTP/UDP/IP 开销 | 百兆网余量 | 千兆网余量 |
|---:|---:|---:|---:|---:|
| 1 Mbps（480p） | ~110 pkt/s | ~3.5% | 充足 | 充足 |
| 2 Mbps（480p 高质） | ~220 pkt/s | ~3.5% | 充足 | 充足 |
| 4 Mbps（720p） | ~440 pkt/s | ~3.5% | 充足 | 充足 |
| 8 Mbps（1080p） | ~880 pkt/s | ~3.5% | 充足 | 充足 |

- **百兆以太网**就足够 1080p（8 Mbps << 100 Mbps）；瓶颈是编码，不是网络。
- 2.4GHz WiFi 跑 4–8 Mbps 通常可以，但抖动/重传会增大 jitter buffer 延迟；建议 5GHz 或有线。
- 低延迟优先用 **UDP/RTP + 小 jitter buffer**；要穿透/兼容浏览器用 **RTSP/WebRTC**（WebRTC 会加 100–300ms）。

---

## 8. 优化建议（按性价比）

| # | 手段 | 收益 | 代价 |
|---|---|---|---|
| 1 | **480p 而不是 720p/1080p** | 3–6.7× | 分辨率下降 |
| 2 | **x264 ultrafast + zerolatency** | 基准 | 码率/画质下降（1–2 Mbps 可接受） |
| 3 | **MJPEG 采集** | 省 USB、省驱动拷贝 | 解码占 0.3–1 核 |
| 4 | **4 线程 + performance governor** | +10–20% | 功耗/温度 |
| 5 | **headless、关桌面** | 释放 200–500MB 内存/CPU | 无桌面 |
| 6 | **只编码变化区域/ROI** | 省 20–50% | 工程复杂 |
| 7 | **降帧率到 20–25** | CPU 从 78%→52–65% | 流畅度 |
| 8 | **硬件编码（5.4/Android）** | 5–10× | 私有栈、不可维护 |
| 9 | **RTSP/WebRTC** | 浏览器兼容 | 延迟 +100–300ms |

推荐 GStreamer 管线（官方 6.1，软件）：

```bash
gst-launch-1.0 -v v4l2src device=/dev/video0 io-mode=2 \
  ! image/jpeg,width=640,height=480,framerate=30/1 \
  ! jpegdec ! videoconvert ! video/x-raw,format=I420 \
  ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=30 \
  ! rtph264pay config-interval=1 pt=96 \
  ! udpsink host=192.168.1.100 port=5000
```

FFmpeg 等价：

```bash
ffmpeg -f v4l2 -input_format mjpeg -video_size 640x480 -framerate 30 -i /dev/video0 \
  -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2M -g 30 -an \
  -f rtp rtp://192.168.1.100:5000
```

---

## 9. 上板实测方案

```bash
# 1) 相机能力与真实帧率
v4l2-ctl -d /dev/video0 --list-formats-ext
v4l2-ctl -d /dev/video0 --set-fmt-video=width=640,height=480,pixelformat=MJPG \
         --set-parm=30 --stream-mmap --stream-count=300 --stream-to=/dev/null
# 观察实际 fps、丢帧；再测 YUYV

# 2) 确认有没有硬件编码节点（官方 6.1 应该没有）
ls /dev/video* /dev/cedar* 2>/dev/null
v4l2-ctl --list-devices
ffmpeg -hide_banner -encoders | grep -iE "264|v4l2m2m"

# 3) 纯编码基准（不含相机）
ffmpeg -f lavfi -i testsrc2=size=640x480:rate=30 -t 30 \
  -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2M -an -f null -
# 看 speed=xx x（>1 才实时）；换 1280x720/1920x1080、veryfast 再测

# 4) 端到端：相机→编码→RTP，主机侧收流计时
#    记录：capture fps、encoder speed、CPU（top -H）、温度、端到端延迟
```

验收基线（480p30 软件）：

| 指标 | 目标 |
|---|---|
| 编码 speed | ≥1.0×（30fps 实时） |
| 4 核 CPU | ≤85%（留余量给相机/网络） |
| glass-to-glass | ≤300 ms |
| 连续 1h | 不热降频、不丢流 |
| 码率 | 1.5–2.5 Mbps @480p30 |

---

## 10. 不确定性与风险

1. **x264 系数是工程估算**（±30%），必须上板用 `ffmpeg -f lavfi` 测 `speed=` 校准。
2. **硬件编码未证实**：5.4 `cedar_dev` 有编码引擎痕迹，但没有标准 V4L2/FFmpeg 路径；本仓库未验证厂商 MPP。
3. **USB 带宽是“独占”估算**：同一控制器接多设备、UVC 等时传输、相机实际帧率都会影响。
4. **CPU 占用是“编码线程”**，不含 MJPEG 解码/网络/系统；480p30 实际接近满载。
5. **热**：实测 85°C 仍 1512MHz，但长期满载 + 相机供电会加速老化；建议散热片。
6. **相机差异**：不同 UVC 模块的 MJPEG 质量/帧率/曝光延迟差异很大；1080p MJPEG 帧大小可能远超 250KB。
7. **RTP 接收端**：浏览器不能直接收 RTP，需要 RTSP/WebRTC 网关；会增加延迟。

---

## 11. 结论

- **H618 芯片有 H.264 硬编能力（1080p60/4K25），但官方 Linux 6.1 没有驱动**；能用的只有软件 x264。
- **软件 x264 的实际上限**：480p30 临界（约 3.5 核）、480p 20–25 稳；720p 约 10 fps；1080p 约 4 fps。
- **USB2.0 不是主要瓶颈**：480p YUYV 18.4MB/s、720p30 用 MJPEG 3.7MB/s；真正瓶颈是 CPU 编码。
- **RTP 开销可忽略**：1–8 Mbps、百兆网足够；延迟主要来自编码和接收端 jitter buffer（150–300ms）。
- **产品建议**：做 **480p20–25 网络摄像头**用官方 6.1 + x264 ultrafast 完全可行；
  要 **720p/1080p 实时**，走 Android/厂商硬编（未证实）或换 RK3566/RK3588 等带标准 VENC 的平台。

---

## 12. VENC 不确定性核对清单

> 结论：**核心问题不是“H618 的 VENC 硬件未知”，而是“没有一条可交付、可维护、可复现的 Linux 编码栈”。**
> 硬件规格在营销级是清楚的（H.264 1080p60/4K25），不清楚的是工程级参数、驱动/用户态来源与实测数据。
> 5.4 `cedar_dev` 的源码级接口分析见 **[docs/14](14_5.4_cedar设备编码能力分析.md)**。

| 层面 | 已知（有证据） | 不清晰（需要补） |
|---|---|---|
| 硅片能力 | H616 brief：H.264 BP/MP/HP 编码 **4K@25 或 1080p@60**；只有 H.264，无 H.265 编码 | 4K25 对应的 level/码率/画质；1080p60 是否持续；编码+解码并发能力；VENC 与 VE 解码共享 SRAM/带宽的约束；多路编码 |
| 6.1 官方内核 | **没有编码驱动**（cedrus 仅解码，全树无 VENC 符号） | 无（结论明确） |
| 5.4 BSP | `cedar_dev`（`CONFIG_VIDEO_ENCODER_DECODER_SUNXI=y`），有 `VE_LOCK_VENC`/编码 IRQ 字段；**私有 ioctl，非 V4L2** | 它到底是否暴露编码通道；需要哪个用户态；稳定性/性能；能否移植到 6.1 |
| 用户态 | Android 12 有厂商闭源多媒体栈（手册标“视频编解码 OK”） | Linux 侧 MPP/libvencoder 是否覆盖 H616 编码、从哪获取、许可、示例；无公开可复现 demo |
| 主线 | 7.4 才合入 H616 **解码**（cedrus），**编码从未上游** | 无（短期看不到路径） |
| 实测 | 无 H618 1080p30 硬编公开数据；社区 `sunxi_venc.ko` 帖无仓库/日志 | 编码 CPU、fps、码率、画质、延迟、功耗、连续稳定性 |

### 12.1 向厂商（迅龙/全志）索取的 8 项材料

1. VENC 内核驱动：支持的内核版本（5.4/6.1/6.6）、源码或二进制、License；
2. 用户态库：`libvencoder`/MPP 的 so + 头文件 + 示例（H.264 1080p30/720p30）；
3. 编码参数范围：profile/level、GOP、码控（CBR/VBR）、最大码率、延迟模式；
4. 与解码/显示/相机并发的限制（共享 VE/SRAM/带宽）；
5. 参考管线：V4L2/MPP 如何对接 UVC 采集（或 YUV 输入）；
6. 已知问题/errata（4K25 降频、长时间稳定性）；
7. 热设计/功耗数据（编码满载）；
8. 支持窗口与升级策略（6.1 → 6.12/6.18）。

### 12.2 上板验证 6 步（按顺序，任何一步失败就停）

1. **Android 12 基线**：用厂商相机/编码 demo 录 1080p30 H.264，确认硅片能力与画质；
2. **5.4 BSP**：`ls /dev/cedar*`、找 `libvencoder`/`mpp` demo，跑 1080p30 编码，记录 CPU/fps；
3. **输入链路**：1080p MJPEG（USB2 唯一可行）解码 → YUV → 硬编，测整条管线 CPU；
4. **并发**：编码 + WiFi RTP + 相机同时跑 1h，看丢帧/温度/降频；
5. **6.1 移植**：若只有 5.4 驱动，评估 API 差异与工作量（通常很大）；
6. **回归**：与软件 x264 对比（同分辨率/码率的画质、延迟、CPU）。

### 12.3 Go / No-Go 门槛

| 指标 | Go 条件 |
|---|---|
| 1080p30 硬编 CPU | ≤30%（不含 MJPEG 解码） |
| 整机（含 MJPEG 解码 + WiFi） | ≤2.5 个 A53 核，1h 不丢帧 |
| 编码延迟 | ≤50 ms（zerolatency 模式） |
| 画质 | 同码率下不差于 x264 veryfast |
| 可获得性 | 有源码/可维护的二进制 + 明确 License + 厂商支持 |

达不到 → 按“无硬编”处理：480p 软件 x264，或换 RK3566/RK3588。

## 13. 参考

- H616 产品简介（H.264 编码规格）：`docs/source/h616-soc.pdf`
- 6.1 内核（cedrus 仅解码）：`hardware/ref/cedrus-6.1/cedrus.c`（完整树 `kernel/src/linux-6.1/`）
- 5.4 BSP cedar 驱动：`hardware/ref/cedar-ve-5.4/`
- 硬件/系统：[docs/01](01_硬件规格与系统.md)、[docs/02](02_原理图分析.md)、[docs/09](09_H618内核适配与编译方案.md)
- 机器视觉性能：[docs/11](11_H618_YOLO理论性能分析.md)
- 实测锚点：[docs/evidence/webcam_benchmarks.md](evidence/webcam_benchmarks.md)
- 计算脚本：[scripts/webcam_pipeline_model.py](../scripts/webcam_pipeline_model.py)
