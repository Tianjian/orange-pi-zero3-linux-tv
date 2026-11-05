# 16 · Linux 投屏路线实施方案（DLNA 渲染器 + HDMI 大屏）

> 前提：**Ubuntu 开发机开 hotspot（以太网上行 + NAT）**，手机和 Zero3 都做 STA；
> Zero3 跑 Linux，接 HDMI 屏，作为 **DLNA/UPnP 渲染器**，接收手机视频 App 的“投屏”。
> 不包含 Miracast/AirPlay/Google Cast（Linux 无可用接收端，见 [docs/15](15_TV投屏demo方案评估.md)）。
>
> 本文给出：内核版本、发行版、工具链、应用架构、部署/调试工具、里程碑与验收标准。
> 目标是把“能跑”变成“可部署、可调试、可复现”的一条工程路线。

---

## 0. 结论速览

| 决策项 | 选择 | 理由 |
|---|---|---|
| **内核** | **官方 6.1.31-sun50iw9（厂商树）** | HDMI/DE 只有厂商树支持（主线到 7.4 仍无 HDMI/DE 节点）；WiFi UWE5622 树内驱动；cedrus 可硬解 H.264/H.265 |
| **发行版** | **Debian 12 bookworm（minimal/server，无桌面）** | 官方镜像支持；GStreamer 1.22；`gmediarender` 有 Debian 包；Python 3.11；支持周期长 |
| **内核工具链** | **Arm GNU 11.2-2022.02**（仓库已装） | 与官方 SDK 一致；`scripts/build_kernel.sh` 已验证可编 |
| **应用工具链** | 板端原生 `gcc 12`（首选）/ 交叉 `aarch64-none-linux-gnu-gcc` + Debian sysroot（可选） | 应用只有 Python + 少量 C（gmediarender），原生编译最省事；CI 只做语法/单测 |
| **渲染器** | **gmediarender（hzeller/gmrender-resurrect 0.3.1，源码编译）** | 成熟、资源占用低；`--gstout-videopipe` 可定制 `kmssink`；B 站 DLNA 投屏有公开成功案例；Debian 0.1 包可作后备 |
| **视频输出** | GStreamer `kmssink`（无桌面，DRM/KMS 直出） | 省内存/CPU；避免 X/Wayland 栈；`force-modesetting=true` |
| **音频输出** | ALSA HDMI（`alsasink device=...`），禁用 PulseAudio | 减少一层音频服务；HDMI 音频直出 |
| **硬件解码** | GStreamer `v4l2slh264dec`（cedrus 无状态解码）；失败回退 `avdec_h264` | 6.1 树内 cedrus=m；Debian GStreamer 含 v4l2codecs 插件 |
| **网络** | 开发机 hotspot + NM shared（10.42.0.0/24） | 手机有外网、Zero3 可 SSH、PC 可 tcpdump；见 [docs/15](15_TV投屏demo方案评估.md) §2.3 |
| **部署** | rsync + systemd + healthcheck；后续 `.deb` | 简单可回滚，适合 demo 到小批量 |

**核心判断**：**TV 场景必须用厂商 6.1 内核**——主线没有 HDMI/DE 节点，无法输出画面；这不是“新旧内核”的选择题。

## 0.1 镜像基线（已下载并校验）

- 镜像：**Orange Pi 1.0.4 Bookworm / Debian 12 / kernel 6.1.31-sun50iw9 / server**
- 文件：`images/Orangepizero3_1.0.4_debian_bookworm_server_linux6.1.31.img`（2.39 GiB）
- SHA256：`dda562f0ce9c3fc2be656f816b8f3aea466a3f9ace9fdf87d97ebdc72aeada40`（与镜像自带 `.sha` 一致）
- 镜像默认：`console=both`、`disp_mode=1920x1080p60`、`bootlogo=false`；
  首次启动自动扩 rootfs；默认账号 `root`/`orangepi`（密码 `orangepi`，登录后立即改）
- 详细来源/校验/分区：`docs/evidence/image_download.md`


---

## 1. 需求与验收指标

### 1.1 功能需求

1. Zero3 连开发机 hotspot，自动获取 IP（10.42.0.x）；
2. Zero3 启动后自动进入“可被发现”状态（DLNA renderer，友好名如 `OrangePi-Zero3 TV`）；
3. 手机视频 App（先以 B 站/支持 DLNA 的 App 为准）能发现并投屏；
4. HDMI 输出 1080p，声音走 HDMI；
5. 支持播放/暂停/停止/seek/音量（DLNA AVTransport + RenderingControl 基础动作）；
6. 断网/重启后自动恢复；
7. 可远程部署、查看状态、收集日志。

### 1.2 验收指标（demo 基线）

| 指标 | 目标 |
|---|---|
| 发现时间 | 上电到可被发现 ≤ 30 s |
| 起播时间 | 手机点投屏到画面出现 ≤ 5 s（受源站影响） |
| 1080p H.264 解码 | 连续 30 min 不卡顿，CPU ≤ 60%（4 核） |
| 音画同步 | 偏差 ≤ 100 ms |
| 内存占用 | 系统空闲 ≤ 300 MB；播放 ≤ 600 MB |
| 稳定性 | 24 h 循环播放 + 网络重连，无人工干预 |
| 温度 | ≤ 80°C（散热片），不降频 |
| 远程运维 | SSH + HTTP 状态 + 一键日志包 |

---

## 2. 技术路线

```
手机 App（DLNA 控制点）
   │ SSDP 发现 + SOAP 控制（AVTransport/RenderingControl）
   ▼
Zero3: gmediarender（GUPnP + GStreamer playbin）
   │ 媒体 URL（HTTP/FLV/MP4/HLS）
   ▼
GStreamer: qtdemux/flvdemux → h264parse → v4l2slh264dec（cedrus）→ kmssink → HDMI
                                                   └→ alsasink → HDMI 音频
```

- **不做屏幕镜像**：DLNA 只接收 App 给出的媒体 URL；手机屏幕内容不传输。
- **DRM 内容不支持**：无 Widevine；只做非 DRM 的公开流/本地内容。
- **Miracast 不做**：Linux 无成熟 sink；需要屏幕镜像请走 Android TV（[docs/15](15_TV投屏demo方案评估.md)）。

---

## 3. 内核版本：为什么锁定 6.1 厂商树

| 候选 | HDMI/DE | WiFi UWE5622 | cedrus 解码 | 结论 |
|---|---|---|---|---|
| 官方 6.1.31-sun50iw9 | ✅ 厂商 DRM（HDMI 可用） | ✅ 树内三模块 | ✅ `VIDEO_SUNXI_CEDRUS=m` | **唯一满足 TV 的现成组合** |
| 官方 5.4 BSP | ✅（vendor disp2） | ✅ | 私有 cedar（解码） | 可做，但老、维护差 |
| 主线 6.12/6.18/7.4 | ❌ 无 HDMI/DE 节点 | ❌ 需 DKMS | ✅（7.4 起 H616） | **不能做 HDMI 输出** |

- 主线到 7.4 仍没有 H616 的 HDMI/DE 节点（见 [docs/08](08_社区与主线调研.md) §2），所以 **TV demo 不能用主线**。
- 内核就用官方镜像自带的 **6.1.31-sun50iw9**；只有需要改驱动/配置时才用 [scripts/build_kernel.sh](../scripts/build_kernel.sh) 重编。
- 需要确认的配置/模块：
  - `CONFIG_DRM_SUN4I=y`、`CONFIG_DRM_SUN8I_DW_HDMI=y`、`CONFIG_DRM_SUN8I_MIXER=y`（HDMI/DE）
  - `CONFIG_VIDEO_SUNXI_CEDRUS=m`（H.264/H.265 解码；`modprobe sunxi-cedrus`）
  - `CONFIG_AW_WIFI_DEVICE_UWE5622=y`、`CONFIG_WLAN_UWE5622=m`、`CONFIG_SPRDWL_NG=m`、`CONFIG_TTY_OVERY_SDIO=m`（WiFi/BT）
  - `CONFIG_SND_SUN50IW9_CODEC=y`（模拟音频；HDMI 音频走 DRM/HDMI codec）
- 不启用 `disable-uart0` 等会丢控制台的 overlay；保留串口作为救砖通道。

---

## 4. Linux 发行版选择

| 发行版 | 优点 | 缺点 | 结论 |
|---|---|---|---|
| **Debian 12 bookworm minimal** | 官方镜像；`gmediarender` 有包（0.1-1）；GStreamer 1.22（含 `libgstkms.so`、`libgstv4l2codecs.so`）；Python 3.11；稳定、支持到 2028 | 包版本偏旧；`--gstout-videopipe` 建议用上游 0.3.1 源码 | **推荐** |
| Ubuntu 24.04 server | GStreamer 1.24；新工具链 | 更重；`gmediarender` 未必有包；官方镜像也支持 | 备选 |
| Debian 13 trixie | `gmediarender 0.3.1`；更新 | 官方 Zero3 镜像不一定提供；内核/驱动适配需确认 | 观察 |
| Armbian bookworm | 社区活跃、工具方便 | 非官方；内核/驱动组合需验证 | 备选 |
| Buildroot/Yocto | 镜像小、可量产 | 开发慢；GStreamer/UPnP 集成工作量大 | 量产阶段再考虑 |

**推荐镜像**：Orange Pi 官方 **Debian 12 服务器版（minimal）**，不装桌面。
- 无桌面 → 没有 X/Wayland 抢 DRM master，`kmssink` 可直接用；
- 需要 UI 时再加 `cage`/`weston` + Qt（Phase 5 可选）。

---

## 5. 编译工具链

### 5.1 内核

| 项 | 值 |
|---|---|
| 工具链 | Arm GNU 11.2-2022.02（`aarch64-none-linux-gnu-gcc 11.2.1`） |
| 安装 | `./scripts/setup_toolchain.sh`（已在本仓库验证） |
| 构建 | `./scripts/build_kernel.sh --jobs 8` → `kernel/out/6.1/Image + dtb + modules` |
| 配置 | 官方 `linux-6.1-sun50iw9-next.config`；本仓库审计 0 缺失 |
| 何时重编 | 只改 DTS/驱动/裁剪时；日常应用开发用官方镜像内核即可 |

### 5.2 应用

| 方式 | 适用 | 命令/说明 |
|---|---|---|
| **板端原生**（首选） | gmediarender（C）、Python 应用 | 板子上 `apt install build-essential ...`，`./autogen.sh && make -j4`；Python 直接跑 |
| 交叉编译（可选） | CI/批量 | `aarch64-none-linux-gnu-gcc` + Debian arm64 sysroot（从镜像/`debootstrap` 取），`PKG_CONFIG_SYSROOT_DIR` |
| Python 打包 | 应用 | `python3 -m build` 出 wheel；板端 `pip install` 或直接 rsync |
| 系统包 | 部署 | `dpkg-buildpackage` 出 `.deb`（含 systemd unit、config） |

> 交叉编译 GStreamer/UPnP 依赖较重；**Phase 1 用板端原生编译**，Phase 3 再做可复现的交叉构建。

### 5.3 版本矩阵（写进 README/发布记录）

| 组件 | 版本 |
|---|---|
| 内核 | 6.1.31-sun50iw9 |
| Debian | 12 bookworm |
| GStreamer | 1.22（bookworm） |
| gmediarender | 0.1-1（Debian）或 0.3.1（源码） |
| Python | 3.11 |
| 工具链 | Arm GNU 11.2（内核）/ gcc 12（板端） |

---

## 6. 系统架构

### 6.1 组件图

```
┌──────────────────────────── Zero3 (Debian 12) ────────────────────────────┐
│                                                                            │
│  systemd                                                                   │
│   ├── opiz3-net.service         (oneshot) 连 WiFi/关省电/等 IP              │
│   ├── opiz3-renderer.service    gmediarender + GStreamer                    │
│   ├── opiz3-supervisor.service  Python 守护 + HTTP 状态 + watchdog          │
│   ├── opiz3-idle.service        (可选) 空闲画面/Logo，与 renderer 互斥       │
│   └── opiz3-update.service      (可选) 升级/回滚                            │
│                                                                            │
│  文件: /etc/opiz3-cast/config.toml, /var/lib/opiz3-cast/state.json          │
│  日志: journald + /var/log/opiz3-cast/                                      │
└────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 状态机

```
BOOT → NET_WAIT → DISCOVERABLE ⇄ PLAYING → ERROR → (backoff) → NET_WAIT
```

- `NET_WAIT`：等 wlan0 拿到 10.42.0.x / 默认路由；
- `DISCOVERABLE`：renderer 已注册 SSDP，等待 SetAVTransportURI；
- `PLAYING`：GStreamer 播放中；supervisor 监控 pipeline 状态/温度；
- `ERROR`：连续失败则重启 renderer，指数退避，写 journal。

### 6.3 数据流/控制流

1. 手机 SSDP M-SEARCH → Zero3 回 200 OK（description URL）；
2. 手机 GET description XML → 拿到 AVTransport/RenderingControl 服务；
3. SOAP `SetAVTransportURI` + `Play` → gmediarender 调 GStreamer playbin；
4. playbin 选 `v4l2slh264dec`（或 fallback）→ `kmssink` → HDMI；
5. 音频 `alsasink` → HDMI；
6. 手机 `Pause/Stop/Seek/SetVolume` → gmediarender → GStreamer；
7. supervisor 通过 GUPnP/HTTP 读状态，写 `state.json` 并暴露 `/status`。

---

## 7. 应用程序设计

### 7.1 渲染器：gmediarender

```bash
# 推荐：hzeller/gmrender-resurrect 0.3.1 源码编译
gmediarender \
  -f "OrangePi-Zero3 TV" \
  -u "uuid:6f1c2a2e-..." \
  -p 49152 \
  --gstout-videopipe "videoconvert ! videoscale add-borders=true ! video/x-raw,width=1920,height=1080,format=NV12 ! kmssink" \
  --gstout-audiosink "alsasink" \
  --gstout-audiodevice "hdmi:CARD=HDMI,DEV=0" \
  --gstout-buffer-duration 0.5

# 若发行版包不支持 --gstout-videopipe，用 --gstout-videosink（老包从 0.0.5 就有）
gmediarender -f "OrangePi-Zero3 TV" --gstout-videosink "kmssink" \
  --gstout-audiosink "alsasink" --gstout-audiodevice "sysdefault"
```

- `--gstout-videopipe` 是上游 0.3.1 的定制视频 sink（B 站投屏案例用 `waylandsink`，我们无桌面用 `kmssink`）；
- 手机投屏常见 **720×1280 竖屏**，直接进 `kmssink` 会因平面放不下 1280 高而报 `drmModeSetPlane ENOSPC`；必须加 `videoscale add-borders=true` 缩到 1920×1080；
- 还要把视频 overlay 的 `zpos` 提到 console primary 之上：`modetest -M sun4i-drm -w 31:zpos:3`
  （否则 HDMI 上只看到 login console，见 `deploy/opiz3-renderer.service` 的 `ExecStartPre`）；
- 老版本（Debian 0.1）可能只有 `--gstout-videosink`；两者互斥，按 `--help-gstout` 确认；
- `--gstout-buffer-duration 0.5` 控制起播缓冲（秒），太小易卡、太大延迟高；
- 若 `kmssink` 与 fbcon 抢 DRM：内核 cmdline 加 `fbcon=map:1` 或停 `getty@tty1`，让 `kmssink` 独占；
- 若 `v4l2slh264dec` 不可用，设 `GST_PLUGIN_FEATURE_RANK` 或改 `--gstout-videopipe` 里加 `avdec_h264 ! kmssink`；
- 音频：`aplay -l` 找到 HDMI card，写死 `alsasink device=hw:X,Y`；禁用 PulseAudio（`systemctl --user mask pulseaudio`）。

### 7.2 守护/状态：opiz3-supervisor（Python）

| 模块 | 职责 |
|---|---|
| `netmon` | 检查 wlan0 IP/路由/信号；断线重连（nmcli） |
| `rendermon` | 检查 gmediarender 进程/端口/SSDP；异常重启 |
| `sysmon` | CPU/内存/温度/磁盘；超阈值告警 |
| `api` | HTTP `GET /status`、`/health`、`POST /restart`、`GET /logs?lines=200` |
| `state` | 原子写 `state.json`；供 LED/OLED/Web 使用 |
| `watchdog` | `sd_notify(WATCHDOG=1)`；systemd `WatchdogSec=30` |

- 语言：Python 3.11（标准库 + `requests`/`psutil` 可选）；避免引入重框架；
- HTTP 用标准库 `http.server` 或 `aiohttp`（轻量）；
- 配置热加载：SIGHUP 重读 `config.toml`；
- 安全：只监听 wlan0/内网；无鉴权时不做写操作（或 token）。

### 7.3 配置

```toml
# /etc/opiz3-cast/config.toml
[friendly]
name = "OrangePi-Zero3 TV"
uuid = "uuid:6f1c2a2e-..."

[network]
ssid = "OPi-Z3-Lab"
password_file = "/etc/opiz3-cast/wifi.secret"   # 0600
power_save = false

[video]
sink = "kmssink force-modesetting=true"
decoder_prefer = "v4l2slh264dec"
fallback = "avdec_h264"

[audio]
sink = "alsasink device=hdmi:CARD=HDMI,DEV=0"

[supervisor]
http_port = 8080
watchdog_sec = 30
```

### 7.4 可选 UI（Phase 5）

- 方案 A：`cage`（单应用 Wayland kiosk）+ Qt/GTK 状态页；
- 方案 B：空闲时用 `gst-launch` 播 Logo/时钟（与 renderer 互斥）；
- 方案 C：只在 HDMI 上显示 console/黑屏，Web 状态页足够（推荐先不做 UI）。

---

## 8. 网络与部署拓扑

```
Internet ── 以太网 ── Ubuntu 开发机 (nmcli hotspot, 10.42.0.1/24, NAT)
                              ├── WiFi: 手机 (10.42.0.x)
                              └── WiFi: Zero3 (10.42.0.x, SSH/HTTP)
```

- 开发机：`nmcli device wifi hotspot ifname wlp0s20f3 ssid OPi-Z3-Lab password ... band bg`（见 [docs/15](15_TV投屏demo方案评估.md) §2.3.1）；
- Zero3：NetworkManager 连接该 SSID；建议在开发机 DHCP 里给 Zero3 固定租约，或板端设静态 IP；
- 关闭 WiFi 省电：`iw dev wlan0 set power_save off`（否则投屏延迟抖动）；
- 防火墙只放行 22/tcp、8080/tcp、49152/tcp+udp、1900/udp、5353/udp。

---

## 9. 部署工具设计

| 工具 | 运行位置 | 作用 | 接口 |
|---|---|---|---|
| `scripts/hotspot_up.sh` | 开发机 | 开热点、显示客户端/租约 | `--ssid --pass --band` |
| `scripts/hotspot_down.sh` | 开发机 | 关热点、恢复 WiFi | — |
| `scripts/provision_board.sh` | 开发机 | 首次装机：apt 依赖、用户、systemd、配置 | `--host user@ip` |
| `scripts/deploy_app.sh` | 开发机 | rsync 应用 + 重启 + healthcheck + 回滚 | `--host --version` |
| `scripts/healthcheck.sh` | 板端 | 服务/IP/UPnP/HDMI/温度/磁盘 | `--json` |
| `scripts/collect_debug.sh` | 板端 | 打包 journal/dmesg/gst/v4l2/nmcli/tcpdump | `--out /tmp/debug.tgz` |
| `scripts/bench_decode.sh` | 板端 | 1080p H.264 解码基准（硬解/软解） | `--file sample.mp4` |
| `scripts/cast_smoke.sh` | 开发机 | 发现 renderer 并推送测试 URL | `--url http://.../test.mp4` |
| `scripts/ota.sh` | 开发机 | `.deb` 升级 + 回滚（Phase 4） | `--host --deb` |

**部署流程**：

1. 烧 Debian 12 minimal → 串口/SSH 登录 → `provision_board.sh`（装 GStreamer/gmediarender/systemd unit）；
2. `deploy_app.sh` 推应用 → `healthcheck.sh` 通过；
3. 手机投屏 → `cast_smoke.sh` 先做自动化 URL 测试，再人工用 App 验证；
4. 失败回滚：保留 `current`/`previous` 两个软链，`deploy_app.sh --rollback`。

**版本化**：应用版本 + 内核版本 + 配置 hash 写入 `/etc/opiz3-cast/version.json`，healthcheck 上报。

---

## 10. 调试工具设计

| 场景 | 工具/命令 |
|---|---|
| 串口/救砖 | USB-TTL 115200；`scripts/serial_console.sh` |
| 系统日志 | `journalctl -u opiz3-* -f`、`dmesg -T` |
| GStreamer | `GST_DEBUG=3`、`gst-inspect-1.0 v4l2slh264dec`、`gst-launch-1.0` 分步管线 |
| 解码器 | `v4l2-ctl --list-devices`、`v4l2-ctl -d /dev/videoX --list-formats` |
| 显示 | `modetest -M sun4i-drm`、`/sys/class/drm/*/status`、`kmstest` |
| 音频 | `aplay -l`、`speaker-test -D hw:X,Y`、`alsamixer` |
| 网络 | `nmcli dev wifi`、`iw dev wlan0 link`、`tcpdump -i wlan0`、Wireshark（开发机） |
| UPnP | `gssdp-discover`、`gupnp-tools`、`curl <description URL>`、`cast_smoke.sh` |
| 性能 | `perf top`、`top -H`、`pidstat`、`/sys/class/thermal/*` |
| 崩溃 | `gdb-multiarch` + `gdbserver`、`coredumpctl`、`strace -f` |
| 远程 | SSH + `rsync`；开发机 `ssh -L 8080:localhost:8080` 看状态页 |

**一键诊断包**（`collect_debug.sh` 内容）：

```
version.json
uname -a; cat /proc/device-tree/model
systemctl status opiz3-*
journalctl -u opiz3-* --no-pager -n 500
dmesg -T | tail -200
gst-inspect-1.0 v4l2slh264dec | head
v4l2-ctl --list-devices
modetest -M sun4i-drm -c
aplay -l
nmcli -t dev status; ip -br addr; iw dev wlan0 link
cat /sys/class/thermal/thermal_zone*/temp
top -b -n1 | head -20
```

---

## 11. 测试与验收

### 11.1 测试矩阵

| 层级 | 用例 | 通过标准 |
|---|---|---|
| 启动 | 冷启动 → 可被发现 | ≤30s；SSDP 可见 |
| 网络 | 断 WiFi 30s 后恢复 | 自动重连，renderer 重新注册 |
| 解码 | 1080p H.264 硬解/软解 | 30min 无卡顿；CPU/温度达标 |
| 投屏 | B 站/目标 App DLNA | 发现、起播、暂停/继续/停止 |
| 音频 | HDMI 声音 | 音画同步 ≤100ms |
| 稳定性 | 24h 循环 + 网络抖动 | 无人工干预 |
| 部署 | 新卡 provision → deploy → 投屏 | 全流程 ≤30min |
| 回滚 | 坏版本 deploy → rollback | 5min 内恢复 |

### 11.2 解码基准命令

```bash
# 硬解（cedrus）
gst-launch-1.0 filesrc location=/opt/test/1080p_h264.mp4 ! qtdemux ! h264parse \
  ! v4l2slh264dec ! fakesink sync=false
# 软解（fallback）
gst-launch-1.0 filesrc location=/opt/test/1080p_h264.mp4 ! qtdemux ! h264parse \
  ! avdec_h264 ! fakesink sync=false
# 实际输出
gst-launch-1.0 playbin uri=file:///opt/test/1080p_h264.mp4 \
  video-sink="kmssink force-modesetting=true" audio-sink="alsasink device=hw:0,0"
```

---

## 12. 里程碑与排期

| 阶段 | 时间 | 交付 | 验收 |
|---|---|---|---|
| M0 环境 | 0.5 天 | 镜像烧录、SSH、开发机 hotspot、HDMI console | 手机/板子同网互 ping |
| M1 解码/HDMI | 1 天 | GStreamer 硬解 1080p + HDMI 音频 | 本地文件播放 30min 稳定 |
| M2 DLNA | 1–2 天 | gmediarender 可发现、可投屏 | 目标 App 投屏成功 |
| M3 服务化 | 1 天 | systemd + supervisor + config + healthcheck | 重启自动恢复 |
| M4 稳定性/部署 | 1 天 | 24h 测试、deploy/rollback、日志包 | 全流程可复现 |
| M5 可选 | 2–3 天 | UI/IR 遥控/OTA/只读 rootfs | 按需 |

**总工期**：约 **5–7 个工作日** 到可演示；M5 另算。

---

## 13. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 目标 App 不支持标准 DLNA | 发现不了/投不了 | 先确认 App 协议；B 站有成功案例；否则改用 Android TV 路线 |
| DRM 内容黑屏 | 无法播放会员内容 | 只做非 DRM 内容；或接受 Android TV |
| `v4l2slh264dec` 不可用/花屏 | 硬解失败 | fallback `avdec_h264`；验证 cedrus 模块/固件；升级 GStreamer |
| gmediarender 包过旧 | 没有 `--gstout-videopipe` | 从 hzeller/gmrender-resurrect 源码编译 0.3.1；或退回 `--gstout-videosink` |
| `kmssink` 与 fbcon/桌面抢 DRM | 黑屏/无法输出 | 不装桌面；`fbcon=map:1`；停 getty；`force-modesetting` |
| HDMI 音频路由 | 无声/错设备 | `aplay -l` 确认 card；禁用 PulseAudio；`alsasink device=` |
| WiFi 省电/2.4GHz 干扰 | 延迟抖动/卡顿 | 关 power save；用 5GHz/固定信道；PC 热点靠近 |
| SD 卡磨损 | 长期写坏 | 只读 rootfs/overlayroot、日志 tmpfs、减少写 |
| 散热 | 降频/不稳定 | 散热片/风扇；温度监控 |
| 主线升级诱惑 | HDMI 不可用 | 锁定 6.1 厂商树；主线只做评估 |
| 部署不可复现 | 现场翻车 | 固定版本矩阵 + provision 脚本 + 回滚 |

---

## 14. 目录结构（建议）

```
opiz3-cast/
├── app/
│   ├── supervisor/            # Python 守护/HTTP
│   ├── systemd/               # opiz3-net/renderer/supervisor.service
│   └── config/config.toml
├── deploy/
│   ├── provision_board.sh
│   ├── deploy_app.sh
│   ├── healthcheck.sh
│   ├── collect_debug.sh
│   ├── bench_decode.sh
│   └── cast_smoke.sh
├── test/
│   ├── sample_1080p_h264.mp4
│   └── test_plan.md
└── README.md
```

> 本仓库当前只交付方案；`app/`/`deploy/` 的实现可在下一阶段按本设计落地。

---

## 15. 参考

- [docs/15](15_TV投屏demo方案评估.md) —— 拓扑/协议选择/Android 对比
- [docs/09](09_H618内核适配与编译方案.md)、[docs/10](10_内核构建验证.md) —— 6.1 内核/配置/构建
- [docs/08](08_社区与主线调研.md) —— 主线无 HDMI/DE 的证据
- [docs/12](12_H618_WebCam_H264_RTP理论性能分析.md) —— 解码/编码性能基线
- `scripts/build_kernel.sh`、`scripts/setup_toolchain.sh`
- gmrender：<https://github.com/hzeller/gmrender-resurrect>（`--gstout-videopipe`/`--gstout-audiosink`）
- B 站投屏案例（gmrender + GStreamer）：<https://wiki.dshanpi.org/blog/gmrender-bilibili-cast/>
- Debian `gmediarender 0.1-1` 包（后备）
- GStreamer v4l2codecs / cedrus；Debian bookworm `gstreamer1.0-plugins-bad`
