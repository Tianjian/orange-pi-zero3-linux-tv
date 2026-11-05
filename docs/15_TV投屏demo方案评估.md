# 15 · 把 Zero3 做成「HDMI 电视 + 手机投屏」demo 的方案评估

> 设想：Zero3 接 HDMI 屏，手机视频 App 投屏到 Zero3；手机和 Zero3 都接入 **Zero3 自己开的 hotspot**，
> 保证同一 WLAN、能被发现。问：这是不是更“充分利用”这块板的方向？
>
> **结论：方向可行，而且官方 Android 12 TV 镜像已经把这条路走通了（手册 8.14 MiracastReceiver），
> 但“Zero3 自己开 hotspot”有一个关键前提——板子必须有上行互联网（以太网 NAT 或 AP+STA 中继），
> 否则手机连上后没有外网，在线视频 App 根本播不了。**
> 如果坚持 Linux：只能做 **DLNA/UPnP 渲染器**，且依赖 App 支持标准 DLNA；Miracast/AirPlay/Cast 在 Linux 上
> 要么没有可用接收端，要么工程量大。就“视频 App 投屏”这个目标而言，**Android 12 TV 是更合适的组合**；
> 就“嵌入式 Linux 开发”而言，TV demo 反而不如摄像头/AI/网关类 demo 能用到 26pin/GPIO。

---

## 0. 结论速览

| 目标 | 推荐 | 理由 |
|---|---|---|
| 手机视频 App → HDMI 大屏（屏幕镜像/投屏） | **Android 12 TV 镜像 + MiracastReceiver** | 官方手册 8.14 明确支持；Android 12 的 WiFi、WiFi hotspot、HDMI、视频编解码均为 OK（P303） |
| 留在 Linux，接收 App 投屏 | **DLNA/UPnP 渲染器**（gmrender/upmpdcli + GStreamer/MPV） | 只对“支持标准 DLNA”的 App 有效；无 DRM |
| Linux 上做 Miracast 接收端 | **不推荐** | miraclecast 等方案老、依赖 P2P，UWE5622/6.1 上不可控 |
| iPhone AirPlay | 可尝试 UxPlay，但工程量大 | 需要 H.264 解码 + AES + mDNS；非官方支持 |
| Google Cast | **不可行** | 接收端协议闭源，需要授权 |
| 手机与 Zero3 同 WLAN（推荐拓扑） | **Ubuntu 开发机开 hotspot**（本机 AX201 `AP=yes`，以太网上行） | 开发机做 AP/NAT，手机+Zero3 都做 STA；最稳、可抓包调试 |

**一句话**：**“电视 + 投屏”选 Android 12 TV；想玩 Linux 就做 DLNA/本地媒体中心；不要把“Linux + Miracast”当主线。**

---

## 1. “视频 App 投影”其实是四种不同技术

| 技术 | 手机侧 | 发现/连接 | 接收端 | 本板 Linux 可行性 |
|---|---|---|---|---|
| **Miracast（Wi-Fi Display）** | 安卓“无线投屏/屏幕镜像” | Wi-Fi Direct（P2P）或同网 mDNS | Android TV 的 MiracastReceiver | ❌ 无成熟 Linux sink；miraclecast 老且依赖 P2P |
| **DLNA/UPnP** | App 内“投屏”到电视 | SSDP/mDNS，同一子网 | gmrender/upmpdcli/GStreamer | ✅ 可行，但 App 必须支持标准 DLNA |
| **AirPlay** | iPhone 屏幕镜像/投视频 | mDNS | UxPlay/RPiPlay | ⚠️ 可移植，工作量大 |
| **Google Cast** | YouTube/Netflix 的 Cast 按钮 | mDNS | 需授权接收端 | ❌ 无开源接收端 |
| 厂商私有（乐播等） | 部分国内 App | 私有发现/协议 | 需厂商 SDK | ❌ 基本不可行 |

> 先确认你要投的 App 用的是哪一种：是“手机设置里的无线投屏”（Miracast），
> 还是“App 播放器右上角的 TV 按钮”（多为 DLNA/私有协议）。两者方案完全不同。

---

## 2. 官方 Android 12 TV 路线（最可行）

手册 8.14（P319–321）写得很清楚：

1. **开发板和手机连接同一个 WiFi 热点**；
2. 开发板打开 **MiracastReceiver** 应用；
3. 手机设置 → 投屏 → 搜索到开发板 → 连接；
4. 开发板 Accept；
5. HDMI 屏显示手机画面。

配合手册 8.2（P303）的适配表：**HDMI 视频/音频、WiFi、WiFi hotspot、视频编解码、Mali GPU、红外、USB 摄像头全部 OK**。
也就是说，官方 Android 12 TV 镜像本身就是一个“电视盒子”，Miracast 接收端是现成的。

### 2.1 优点

- 不用自己写投屏协议；MiracastReceiver 是厂商 App；
- HDMI + 硬件解码 + GPU 都有厂商适配；
- 手机“屏幕镜像”对所有 App 生效（不依赖 App 是否支持 DLNA）；
- 板子可同时开 WiFi hotspot（P303 明确 OK）。

### 2.2 限制/风险

| 风险 | 说明 | 应对 |
|---|---|---|
| **DRM/HDCP** | Netflix/Disney+ 等受保护内容可能黑屏（HDCP 链路不满足） | demo 用非 DRM 内容/国内 App；提前实测 |
| **Android 内存** | Android 12 TV 在 1GB/1.5GB 上会卡；建议 **2GB 起，4GB 更稳** | 选 2GB/4GB 版本 |
| **hotspot 无外网** | 手机连板子 hotspot 后没有互联网，在线视频不能播 | 板子用以太网接路由器并开 NAT；或改用路由器 hotspot |
| **WiFi 并发** | AP + Miracast 接收同时工作，UWE5622 驱动/射频要实测 | 先按“同一路由器 WLAN”验证，再试板子 AP |
| **延迟** | Miracast 编码+传输+解码，约 100–300ms | 看视频可接受；不建议游戏 |
| **4K** | HDMI 2.0a 可 4K，但 Miracast/解码/UI 4K 不稳 | demo 固定 1080p |
| **Google 服务** | 国内镜像通常无 GMS | 用国内 App/本地内容 |

### 2.3 推荐的网络拓扑（关键）

**首选：Ubuntu 开发机开 hotspot，手机和 Zero3 都连它。** 这正好对应手册 8.14 的“都连同一个 WiFi 热点”，
而且开发机有以太网上行，可以同时给手机提供外网、给 Zero3 提供 SSH/调试通道。

```
方案 A（推荐，本机已验证 AP 能力）:
  Internet ── 以太网 ── Ubuntu 开发机(AP + NAT) ──WiFi── 手机
                                          └────WiFi── Zero3(STA) ──HDMI── 电视
  同一子网 10.42.0.0/24；手机有外网；Zero3 可 SSH；PC 可 Wireshark 抓包。

方案 B（路由器热点，最省事）:
  路由器(有外网) ──WiFi── 手机 / Zero3
  不用配置 NAT，但无法在 PC 上直接抓无线包。

方案 C（Zero3 开 AP，需自己解决上行）:
  Zero3(AP + NAT) ──WiFi── 手机；Zero3 需以太网上行或 AP+STA 中继。
  不稳定因素多（UWE5622 并发、NAT 配置），不推荐作为首选。

方案 D（手机开热点，Zero3 连）:
  手机(AP+数据) ──WiFi── Zero3；手机自己当 AP 时投屏实现可能异常，不推荐。
```

#### 2.3.1 Ubuntu 开发机 hotspot 实操（NetworkManager）

本机（Ubuntu 24.04 + Intel AX201）已确认：

```bash
$ nmcli -f WIFI-PROPERTIES.AP device show wlp0s20f3
WIFI-PROPERTIES.AP:                     yes
$ ip route show default
default via 172.25.8.1 dev enp89s0 ... metric 100     # 以太网是默认路由（外网）
default via 172.25.64.1 dev wlp0s20f3 ... metric 600  # WiFi 当前连的是别的 AP
```

创建热点（会断开 wlp0s20f3 当前 WiFi，但外网仍走以太网）：

```bash
# 2.4GHz（兼容性最好；AX201 也支持 5GHz，可试 band a）
nmcli device wifi hotspot ifname wlp0s20f3 \
  ssid "OPi-Z3-Lab" password "<hotspot-password>" band bg

# 查看 NetworkManager 自动建的连接与地址（默认 10.42.0.1/24，自带 DHCP+NAT）
nmcli connection show --active
ip -br addr show wlp0s20f3

# 关闭热点，恢复原来的 WiFi
nmcli connection down Hotspot
```

要点：

- NetworkManager 的 `ipv4.method shared` 会自动起 dnsmasq 并做 NAT（走默认路由/以太网），
  手机连上即可上网；Zero3 也能 SSH 出去/被 SSH。
- **AP isolation 必须关闭**（NM 默认关闭），否则手机和 Zero3 互相看不见，mDNS/SSDP 也过不去。
- 如果 5GHz/HE 模式起不来，退回 `band bg`；1080p 投屏 5–10Mbps，2.4GHz 够用。
- 开发机上可直接 `sudo tcpdump -i wlp0s20f3` 或 Wireshark 看 mDNS/RTSP/RTP，排障比板子开 AP 方便。
- 防火墙若启用，放行 hotspot 接口的 DHCP/DNS/mDNS/SSDP：
  `sudo ufw allow in on wlp0s20f3`（或按需放行 67/68、53、5353、1900）。
- 手机连上后确认拿到 `10.42.0.x`，并与 Zero3 互 ping；`avahi-browse -art` 应能看到双方服务。

> 如果开发机 WiFi 网卡不支持 AP（`WIFI-PROPERTIES.AP: no`），改用 USB WiFi 网卡或路由器方案；
> 不要用“同一张网卡既连外网又开 AP”的 STA+AP 并发（多数消费网卡不支持）。

## 3. Linux 路线能做到什么

### 3.1 DLNA/UPnP 渲染器（唯一现实的选择）

```bash
# 例：gmrender-resurrect（GUPnP 的 DLNA renderer）
sudo apt install gstreamer1.0-tools gstreamer1.0-plugins-good \
                 gstreamer1.0-plugins-bad gstreamer1.0-libav
# 编译/安装 gmrender-resurrect 后：
gmediarender -f "OrangePi-Zero3-TV" --gst-launch="gst-launch-1.0"
```

- 手机 App 的“投屏”如果走标准 DLNA，会发现 `OrangePi-Zero3-TV`，把 URL 推过来；
- 板子用 GStreamer/MPV 解码（厂商 6.1 的 cedrus 可硬解 H.264/H.265 1080p），HDMI 全屏输出；
- 不需要 Miracast/P2P；只要同一子网（SSDP 多播可达）。

**限制**：
- App 必须支持标准 DLNA；很多国内 App 的“投屏”是私有协议（乐播等），发现不了；
- 受 DRM 保护的流无法播（无 Widevine）；
- 没有“屏幕镜像”，只能投 App 给的媒体 URL。

### 3.2 Miracast 接收端（不推荐）

- 开源实现 `miraclecast` 依赖 wpa_supplicant P2P + Wi-Fi Direct + GStreamer，维护停滞；
- UWE5622 驱动虽然声明了 `P2P_CLIENT/P2P_GO`（`unisocwifi/cfg80211.c:253-291`），但没有 Linux Miracast sink 栈；
- 6.1 厂商内核的 WiFi 是私有驱动，P2P/AP/STA 并发行为未验证；
- 结论：**不要把 Linux Miracast 作为 demo 主线**。

### 3.3 AirPlay（可尝试）

- `UxPlay`（GStreamer）可做 AirPlay 镜像接收端，但需要 H.264 解码 + AES + mDNS；
- 在 H618 上要交叉编译、调 GStreamer，且只服务 iPhone；
- 工作量明显大于 Android TV 方案。

### 3.4 Google Cast

- 接收端协议闭源，需要 Google 授权/Cast SDK；开源只有发送端（castnow 等）。
- **不可行**。

---

## 4. 性能/硬件预算

| 项 | 结论 |
|---|---|
| HDMI | 1080p60 输出没问题；4K 输出可试但 UI/投屏不稳，demo 固定 1080p |
| 解码 | Android：厂商硬解；Linux 6.1：`cedrus=m`（H.264/H.265 1080p）；4K 需实测 |
| WiFi | UWE5622 802.11ac；Miracast 1080p 约 5–10Mbps，带宽不是问题；2.4GHz 干扰/延迟是问题 |
| 内存 | Android 12 TV：**2GB 起**，4GB 稳；Linux 1GB 可跑 DLNA |
| 散热 | 持续解码+WiFi 建议散热片；85°C 仍 1512MHz（同 die 实测）但长期高温不利 |
| 电源 | 5V/2A 起；HDMI+WiFi+USB 外设建议 5V/3A |
| 延迟 | Miracast 100–300ms；DLNA 起播 1–3s，播放中延迟低 |

---

## 5. “充分利用开发板”怎么理解？

TV demo 会用到的外设/模块：

- ✅ HDMI 输出、WiFi、蓝牙（遥控/音箱）、红外（13pin 遥控）、USB（键鼠/摄像头）、VPU 解码、GPU（Android UI）；
- ❌ 26pin GPIO/I2C/SPI/UART/PWM、CSI 摄像头、TV-OUT、音频 codec（Android 用 HDMI 音频）。

所以：

- 如果目标是**做一个看得见的“电视盒子”demo**：TV 方案很合适，能展示 HDMI/WiFi/解码/Android 生态；
- 如果目标是**展示嵌入式 Linux 能力**：摄像头 + YOLO（docs/11）或 UVC→H.264→RTP（docs/12）更能用上 USB/CPU/网络；
- 如果目标是**“充分利用”所有接口**：可以组合——“Android TV 投屏 + 13pin 红外遥控 + 26pin GPIO 状态灯/温度显示”，
  或者 Linux 上做“HDMI 媒体中心 + GPIO 控制 + 摄像头画中画”。

---

## 6. 推荐落地方案

### 方案 1（首选，最快出效果）

1. 烧 **Android 12 TV** 镜像（官方资料页）；
2. HDMI 接电视/显示器，网线接路由器（或连路由器 WiFi）；
3. 手机与板子连**同一个路由器 WLAN**；
4. 打开 **MiracastReceiver**，手机“无线投屏”连接；
5. 验证 1080p 视频 App 投屏、延迟、声音、遥控。

### 方案 2（开发机 hotspot 完整版，推荐）

1. Ubuntu 开发机用**以太网**接外网；
2. `nmcli device wifi hotspot ...` 开热点（自动 DHCP+NAT，见 §2.3.1）；
3. 手机和 Zero3 都连这个 SSID，确认都在 `10.42.0.0/24`、能互 ping、手机能上网；
4. Android 路线：Zero3 打开 MiracastReceiver，手机“无线投屏”连接；
   Linux 路线：Zero3 跑 DLNA renderer，手机 App 投屏；
5. 开发机 `tcpdump`/Wireshark 抓 mDNS/RTSP/RTP，定位发现问题。

### 方案 3（Linux 媒体中心）

1. 官方 6.1 镜像 + HDMI + GStreamer/MPV；
2. `gmrender-resurrect` 做 DLNA 接收端；
3. 手机 App 用标准 DLNA 投屏；本地/URL 播放；
4. 可选：`create_ap` 开热点 + 以太网 NAT。

---

## 7. 验证清单

- [ ] 手机投屏方式确认：系统“无线投屏”（Miracast）还是 App 内 DLNA/私有协议？
- [ ] Android TV 镜像版本、内存 ≥2GB、HDMI 1080p 输出正常；
- [ ] 同一 WLAN 下 MiracastReceiver 能被手机发现；
- [ ] 视频 App 投屏 10 分钟不卡顿、音画同步、延迟可接受；
- [ ] DRM 内容是否黑屏（决定 demo 素材）；
- [ ] 板子开 hotspot 时手机能否上网（NAT 是否生效）；
- [ ] 温度/功耗/连续 1h 稳定性；
- [ ] 若走 Linux DLNA：App 能否发现 renderer、能否播 1080p H.264。

---

## 8. 结论

- **“HDMI 电视 + 手机视频 App 投屏”这个方向，官方 Android 12 TV + MiracastReceiver 是最合适的组合**，
  手册 8.14 已经给出完整步骤；这比在 Linux 上造 Miracast 现实得多。
- **“开发机开 hotspot、手机和 Zero3 都做 STA”是推荐拓扑**：开发机以太网上行 + NM shared 自动 NAT，
  手机有外网、Zero3 可调试、PC 可抓包；比 Zero3 开 AP 简单稳定。若开发机网卡不支持 AP，再用路由器方案。
- **Linux 路线只推荐 DLNA/UPnP**，且受 App 协议与 DRM 限制；Miracast/AirPlay/Cast 不作为主线。
- **“充分利用”取决于目标**：TV demo 用 HDMI/WiFi/VPU/GPU，但不用 GPIO/26pin；
  想展示 Linux 嵌入式能力，摄像头/AI/网关类 demo（docs/11、docs/12）更合适。
  两者可以组合成“Android TV + 红外遥控 + GPIO 状态灯”的展示型 demo。

---

## 9. 参考

- 手册 8.14 MiracastReceiver：P319–321（`docs/source/manual.txt`）
- 手册 8.2 Android 12 TV 适配表：P303（WiFi hotspot、HDMI、视频编解码 OK）
- 手册 3.7.3 create_ap 热点：P70（Linux 侧）
- [docs/11](11_H618_YOLO理论性能分析.md)、[docs/12](12_H618_WebCam_H264_RTP理论性能分析.md) —— 另外两类更能用上 Linux/CPU 的 demo
- [docs/13](13_内核版本选型_USB相机WiFi_RTP.md) —— 6.1 vs 主线
- UWE5622 P2P 能力：`kernel/src/linux-6.1/drivers/net/wireless/uwe5622/unisocwifi/cfg80211.c:253-291`
