# DLNA 投屏联调记录

日期：2026-11-05
板端：Orange Pi Zero3，Debian 12，kernel 6.1.31-sun50iw9，4GB
渲染器：gmediarender 0.1（GStreamer 1.22）+ `kmssink` + cedrus
网络：开发机 hotspot `OPi-Z3-Lab`，板子 `<board-ip>`

## 1. 本地 HTTP MP4 验证

- 生成 1920×1080 H.264 MP4，板端 `python3 -m http.server 8000` 提供；
- SOAP `SetAVTransportURI` + `Play` → `TransportState=PLAYING`，位置递增；
- 说明 SSDP/描述/SOAP/GStreamer 控制链路正常。

## 2. 手机 B 站投屏

- 手机能发现 `OrangePi-Zero3 TV`；
- 投屏 URL 为 B 站 CDN MP4，实际流：**H.264 High，720×1280（竖屏），30fps**；
- 首版 `kmssink` 直接输出，报：
  ```
  drmModeSetPlane failed: No space left on device (28)
  ```
  原因：竖屏 1280 高 > HDMI 1080 显示平面高度，DRM plane 放不下。
- 修复：视频 sink 前加 `videoconvert ! videoscale add-borders=true`，强制 1920×1080 NV12：
  ```
  --gstout-videopipe "videoconvert ! videoscale add-borders=true ! video/x-raw,width=1920,height=1080,format=NV12 ! kmssink"
  ```
- 用同一 B 站 MP4 经服务播放：`TransportState=PLAYING`，位置 1s/2s/3s 递增，gmediarender CPU ~49%（软缩放 + 解码），不再报 plane 错误。

## 2.1 第二个问题：视频层被 console 盖住

- 修好缩放后仍只看到 login console；
- `modetest -M sun4i-drm -p`：
  - plane 31（YUV overlay）`zpos=0`
  - plane 37（RGB primary，fbcon）`zpos=1`
  → primary 在 overlay 之上，console 把视频盖住；
- 修复：`modetest -M sun4i-drm -w 31:zpos:3` 把视频层提到 console 之上；
- 固化到 systemd：`ExecStartPre=/usr/bin/modetest -M sun4i-drm -w 31:zpos:3`；
- 保留 HDMI console（空闲时可见），播放时视频覆盖 console。

## 3. 板端配置

`/boot/orangepiEnv.txt` 增加：
```
extraargs=video=HDMI-A-1:1920x1080@60
```
启动后 `/sys/class/graphics/fb0/virtual_size` = `1920,1080`，避免运行时切模式失败。

## 4. 结论

- B 站 DLNA 投屏在 Linux + gmediarender + cedrus + HDMI 上可行；
- 竖屏/非 1080p 源必须做等比缩放，否则 `kmssink` 报 ENOSPC；
- 仍待手机端复测确认 HDMI 画面。
