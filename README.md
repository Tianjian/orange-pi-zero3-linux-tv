# Orange Pi Zero3 · Linux DLNA TV

把 Orange Pi Zero3（Allwinner H618）做成一个 **DLNA 投屏电视**：手机上的 B 站等视频 App 发现 `OrangePi-Zero3 TV`，投屏到 HDMI 显示器。

项目记录了从硬件/内核分析、Debian 镜像、显示链路、DE3.3 驱动研究，到最终可用的 **720p 横屏直出**方案。

> 当前稳定交付：**横屏 1280×720、30fps、无音频**。  
> 不支持竖屏/letterbox/1080p；手机端请选择横屏视频。

---

## 最终架构

```text
手机 B 站（横屏 720p）
   │  DLNA / UPnP
   ▼
gmediarender（只做发现与控制，fakesink）
   │  AVTransport CurrentURI
   ▼
opiz3-bridge（读取 URI）
   │
   ├─ ffmpeg 软件解码 → raw NV12 (stdout)
   └─ gst-launch fdsrc ! rawvideoparse width=1280 height=720 format=nv12 framerate=30/1
                ! kmssink plane-id=31
   ▼
HDMI 1280×720 全屏
```

### 为什么不是“纯硬件解码”

我们完整尝试过 DE3.3 / cedrus 的硬件路径，并修复了多个驱动问题（见 [`docs/19`](docs/19_DE33移植与验证计划.md)）：

- cedrus 硬解本身很快（900 帧约 2 秒）；
- 但 B 站手机流的 H.264 在约 6 秒会让硬件解码输出异常，`kmssink` 报 `not-negotiated`；
- `qtdemux` 对 B 站分片 MP4 也会在约 5 秒触发 caps 问题；
- DE3.3 的 VI scaler 下采样仍有横条，overlay + letterbox 未闭环。

最终选择 **ffmpeg 软解 + raw NV12 + VI overlay**：绕开分片 MP4 和 cedrus 的兼容问题，稳定、画面流畅；代价是 CPU 约 1.5–2 核。

---

## 快速开始

### 1. 硬件/系统

- Orange Pi Zero3（H618，4GB）
- HDMI 显示器，支持 1280×720
- Debian 12 Bookworm（vendor 6.1.31-sun50iw9 内核）
- 手机与板子接入同一个 WiFi/热点

### 2. 依赖

```bash
sudo apt update
sudo apt install -y ffmpeg gstreamer1.0-tools gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad libdrm-tests
```

### 3. 内核/启动参数

最终方案使用 **no-fbdev** 的 vendor 6.1 内核：

```text
/boot/orangepiEnv.txt:
extraargs=video=HDMI-A-1:1280x720@60 fbcon=map:1
```

> `docs/19` 记录了 DE3.3 驱动补丁；它们只用于研究，**不是最终投屏所必需**。
> 如果你使用带 fbdev 的旧内核，也可以用 `deploy/opiz3-renderer.service` 的软件路径作为回退。

### 4. 安装服务

```bash
# 桥接脚本
sudo cp deploy/opiz3-bridge.py /home/orangepi/opiz3-bridge.py
sudo chown orangepi:orangepi /home/orangepi/opiz3-bridge.py

# gmediarender 只做发现/控制（fakesink）
sudo cp deploy/opiz3-renderer-fake.service /etc/systemd/system/opiz3-renderer.service
sudo cp deploy/opiz3-bridge.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now opiz3-renderer opiz3-bridge
```

服务名：

- `opiz3-renderer.service`：gmediarender，注册 `OrangePi-Zero3 TV`；
- `opiz3-bridge.service`：读取当前 URI，启动 ffmpeg + GStreamer 出画面。

### 5. 投屏

手机打开 B 站 → 投屏 → 选择 **OrangePi-Zero3 TV** → 选择一个**横屏视频**。

---

## 仓库结构

```text
deploy/                 systemd 服务与 bridge 脚本
docs/                   硬件/内核/显示/DLNA 设计与调试记录
docs/evidence/          关键验证记录
kernel/patches/         vendor 6.1 DE3.3 显示实验补丁（GPL-2.0）
kernel/config/          内核配置参考
scripts/                构建/烧录/自检脚本
```

关键文档：

- [`docs/15_TV投屏demo方案评估.md`](docs/15_TV投屏demo方案评估.md) — TV demo 方案选型
- [`docs/17_显示输出链路.md`](docs/17_显示输出链路.md) — DE/TCON/HDMI 显示链路
- [`docs/18_显示性能结论.md`](docs/18_显示性能结论.md) — 性能结论
- [`docs/19_DE33移植与验证计划.md`](docs/19_DE33移植与验证计划.md) — DE3.3 移植/验证全过程
- [`docs/evidence/dlna_final_2026-11-05.md`](docs/evidence/dlna_final_2026-11-05.md) — 最终验收

---

## 已知限制

- 仅支持 **横屏 1280×720**；
- 不支持竖屏、letterbox、1080p；
- 无音频（当前 HDMI 屏无音频输出）；
- ffmpeg 软件解码，CPU 约 1.5–2 核；
- 依赖 B 站投屏 URL 为 720p；其他分辨率需要改 `rawvideoparse` 和 HDMI mode。

---

## 许可证

- 本项目代码与文档：**MIT**（见 [`LICENSE`](LICENSE)）。
- `kernel/patches/` 是 Linux 内核代码的修改，遵循 **GPL-2.0**（见补丁头/内核许可证）。
- 仓库不包含 Orange Pi/Allwinner 的厂商 PDF、镜像或内核源码树。
