# DLNA 横屏直出最终验收

日期：2026-11-05
设备：Orange Pi Zero3 / H618 / Debian 12 / 6.1.31-sun50iw9（no-fbdev）
投屏端：手机 B 站，多个横屏视频

## 最终链路

```text
gmediarender（仅 UPnP 发现/控制，fakesink）
  + opiz3-bridge 读取 CurrentURI
  + ffmpeg -map 0:v:0 -an -f rawvideo -pix_fmt nv12 -
  + gst-launch fdsrc ! rawvideoparse width=1280 height=720 format=nv12 framerate=30/1
               ! kmssink plane-id=31
```

## 验收结果

- 连续切换多个 B 站横屏视频，均可正常投屏；
- 无 20 秒中断；
- 1280×720、30fps、画面流畅；
- CPU 约 1.5–2 核（ffmpeg ~70% + gst ~35%）；
- 无音频（当前 HDMI 屏无音频输出）。

## 已知限制

- 仅横屏 720p；竖屏/其他分辨率不支持；
- 无 letterbox/缩放；
- 无音频；
- 依赖 ffmpeg 软件解码，CPU 占用较高。

## 服务/启动

- `opiz3-renderer.service`（fake gmediarender）：enabled
- `opiz3-bridge.service`（ffmpeg + kmssink）：enabled
- 内核：`/boot/Image -> vmlinuz-6.1.31-sun50iw9`
- 启动参数：`video=HDMI-A-1:1280x720@60 fbcon=map:1`
