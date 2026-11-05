# 13 · 内核版本选型：只做「UVC 相机 + WiFi + RTP」时，7.4 是否比官方 6.1 更有效？

> 约束：**只用 USB Camera（UVC）抓帧 + 板载 WiFi 推 RTP**，不做 HDMI/音频/GPU/本地显示。
> 问题：用 **Linux 7.4+** 内核，并结合官方 6.1 内核配置的分析结果，是不是更有效的组合？
>
> **短答：不是。** 对这个约束，**官方 6.1 厂商内核是更有效、风险更低的组合**；
> 7.4（当前是 mainline **7.4-rc1**，不是稳定版）既不会提升编码性能，又会丢掉板载 WiFi 的现成驱动。
> 6.1 配置分析的**结论**值得复用（当移植核对表），但 6.1 的 **.config 文件不能直接搬到 7.4**。

---

## 0. 结论速览

| 组合 | UVC 采集 | 板载 WiFi（UWE5622） | H.264 编码 | 维护性 | 结论 |
|---|---|---|---|---|---|
| **官方 6.1 厂商内核** | ✅（标准 UVC） | ✅（树内 `uwe5622_bsp_sdio` 等三模块） | 软件 x264 | 中（厂商混合树，6.1 LTS 仍在维护） | **推荐（默认）** |
| 官方 5.4 BSP | ✅ | ✅ | 软件 x264（有私有 cedar 但无标准管线） | 低（老 BSP） | 仅兼容旧项目 |
| 主线 6.12/6.18 LTS + 板载 WiFi | ✅ | ⚠️ 需 Armbian uwe5622 DKMS（官方支持 6.1/6.12/6.18/7.0/7.1）+ 自补 `mmc1` 节点 | 软件 x264 | 高（LTS、主线） | **可选**，工程量大 |
| 主线 7.4-rc1 + 板载 WiFi | ✅ | ❌ DKMS 支持列表没有 7.4（最高 7.1）；7.4 是 rc 版 | 软件 x264（**7.4 的 cedrus 仍只解码**） | 低（非 LTS/rc） | **不推荐** |
| 主线 7.4/6.18 + **USB WiFi 网卡** | ✅ | 用主线驱动的 USB 网卡 | 软件 x264 | 高 | 可行，但换硬件 |

**一句话**：7.4 不会让 x264 变快，也不会让 USB 更快；它唯一可能带来的“新”是 VPU **解码**（7.4 才合入 cedrus H616），
而你的链路是 **UVC 采集 + 编码**，用不上。**板载 WiFi 才是 7.4 的硬伤。**

---

## 1. 关键事实（决定结论的五条）

### 1.1 7.4 目前是 mainline rc，不是稳定版

`kernel.org`（2026-11-02）：

| 通道 | 版本 |
|---|---|
| mainline | **7.4-rc1** |
| stable | 7.3.1 |
| longterm | 6.18.60、6.12.115、6.6.161、**6.1.191** |

- 生产环境用 rc 内核不合理；要跟主线应选 **6.12 LTS 或 6.18 LTS**。
- 6.1 仍是 longterm（6.1.191），官方 6.1 树也还在维护。

### 1.2 板载 WiFi 是 UWE5622，主线没有驱动

- 6.1 厂商树**自带** `drivers/net/wireless/uwe5622/`，编出 `uwe5622_bsp_sdio/sprdwl_ng/sprdbt_tty`，
  连固件都以 C 数组编进 `uwe5622_bsp_sdio.ko`；开箱即用。
- 主线内核**没有** UWE5622 驱动，也没有排队补丁；只能用 **Armbian 的 out-of-tree DKMS**：
  - 该仓库 `README` 明确支持：**Linux 6.1 / 6.12 / 6.18 / 7.0 / 7.1**；
  - 分支里有 `7.3-compat-v2`（说明在往 7.3 适配），**没有 7.4 支持**。
  - 7.4 若是 rc1，内核 API 还在变，DKMS 大概率编不过/不稳定。
- 主线板级 DTS **没有 `mmc1`（SDIO WiFi）节点**，即使 DKMS 编过，也要自己补 `mmc1 + mmc-pwrseq + vmmc/vqmmc`。

### 1.3 7.4 的“视频引擎支持”是解码，不是编码

- 主线 `cedrus` 在 7.4 才合入 H616/H618 的 **VPU 解码**（H.264/H.265/VP8/MPEG2 DEC）；
- **没有任何主线 H.264 编码器**（Allwinner VENC 仍未上游）。
- 所以 7.4 对“UVC → H.264 编码”这条链路**零收益**；编码仍然是软件 x264，CPU 瓶颈不变。

### 1.4 USB/UVC 在 6.1 与 7.4 上等价

- UVC 是标准 USB 类驱动，6.1 厂商内核与 7.4 主线都用 `uvcvideo`；
- H618 的 EHCI/OHCI 控制器在 6.1 厂商 DTS 与主线 DTS 里都已启用；
- 内核版本对 UVC 吞吐的影响 <2%，瓶颈是 USB2.0 总线（~40 MB/s）与 CPU 编码。

### 1.5 6.1 的 .config 不能直接搬到 7.4

官方 6.1 `.config` 里有大量**厂商私有符号**：

| 符号 | 用途 | 主线是否存在 |
|---|---|---|
| `SND_SUN50IW9_CODEC` / `SND_SOC_SUNXI_AHUB` | 模拟音频/AHUB | ❌（且本用例不需要） |
| `AW_WIFI_DEVICE_UWE5622` / `WLAN_UWE5622` / `SPRDWL_NG` / `TTY_OVERY_SDIO` | 板载 WiFi/BT | ❌（需 DKMS） |
| `VIDEO_SUNXI_CEDRUS` | 厂商解码路径 | 主线是 `VIDEO_CEDRUS`（staging） |
| `SUNXI_GMAC` / `sunxi-ephy` | 厂商网卡残留 | ❌（本板用 stmmac + YT8531） |

把 6.1 `.config` 直接 `make olddefconfig` 到 7.4，结果会是：私有符号被丢弃、一堆无关驱动被打开、
真正需要的 `mmc1`/WiFi 依旧没有。**正确做法是用主线 `defconfig` + 我们提供的
`kernel/config/opiz3-h618-mainline.fragment`，再单独处理 WiFi。**

---

## 2. 方案对比（按你的约束）

### 2.1 方案 A：官方 6.1 厂商内核（推荐）

```
UVC (uvcvideo) → MJPEG 解码 → x264 软件编码 → rtph264pay → WiFi(UWE5622) → RTP
```

- WiFi：树内驱动 + 固件，`/lib/modules/6.1.31-sun50iw9/` 直接可用；
- 编码：软件 x264；480p30 约 78% 4 核（见 docs/12）；
- 风险：厂商树升级不透明；6.1 仍是 longterm（6.1.191），但 LTS 周期终会结束，长期需评估迁移到 6.12/6.18。

### 2.2 方案 B：主线 6.12/6.18 LTS + 板载 WiFi（可选，工程量大）

- 优点：LTS、主线安全更新、长期可维护；
- 代价：
  1. 需要 Armbian uwe5622 DKMS（支持 6.12/6.18）；
  2. 需要自己补 `mmc1`/`wifi-pwrseq` 节点（主线板级 DTS 没有）；
  3. 主线没有 HDMI/音频（本用例不需要）；PMIC 中断 parent 的已知 bug 需确认（见 docs/08）；
  4. 需要自己维护 DKMS 与内核升级的兼容性。
- 性能：与 6.1 基本一致（同一 CPU、同一 x264、同一 USB2.0）。

### 2.3 方案 C：主线 7.4-rc + 板载 WiFi（不推荐）

- WiFi：DKMS 最高支持 7.1，7.4 无支持；要么自己 port，要么等；
- 7.4 是 rc，不适合产品；
- 编码性能无提升；
- 唯一“新东西”VPU 解码用不上。

### 2.4 方案 D：主线 6.18/7.4 + USB WiFi 网卡（可行，但换硬件）

- 用主线支持的 USB WiFi（如 mt76/rtw88 系列），绕开 UWE5622；
- 代价：占用一个 USB2.0 口/带宽；2.4GHz 网卡吞吐/延迟不如板载（但 2 Mbps RTP 足够）；
- 如果不介意多一个 USB 网卡，这是“主线 + 低风险”的折中。

---

## 3. 性能上 7.4 会不会更快？

| 环节 | 6.1 厂商 | 7.4 主线 | 差异 |
|---|---|---|---|
| UVC 采集 | uvcvideo | uvcvideo | ≈0 |
| MJPEG 解码 | libjpeg-turbo | 同 | ≈0 |
| H.264 编码 | 软件 x264 | 软件 x264（无 VENC） | **0** |
| USB2.0 带宽 | 40 MB/s 级 | 同 | ≈0 |
| WiFi 吞吐 | 树内 UWE5622 | 无驱动/DKMS | **7.4 更差或不可用** |
| RTP 打包 | 用户态 | 用户态 | ≈0 |
| 调度/内核开销 | — | 新内核可能好 1–3% | 可忽略 |

**结论：7.4 不会把 480p30 从“临界”变成“轻松”，也不会让 720p30 变可行。**
编码仍是 4×A53 上的 x264，性能上限由 CPU 决定（docs/12）。

---

## 4. 那“官方 6.1 配置分析结果”怎么用？

**能用的是“分析结论”，不是“.config 文件”**：

| 6.1 分析产出 | 在 7.4/主线上的用法 |
|---|---|
| 外设→驱动→符号矩阵（docs/07、`kernel/config-audit/`） | 当**核对表**：逐项确认主线是否覆盖（USB/MMC/PMIC/thermal/wdt/RTC/以太网） |
| 26pin/13pin 复用、DTS 节点（docs/03、`hardware/dts-ref/`） | 直接复用 SoC 级 dtsi 与引脚组名（H618 复用 H616） |
| `opiz3-h618-mainline.fragment` | 在 7.4/6.18 上 `merge_config` 后 `olddefconfig`，得到 Zero3 基线 |
| 6.1 `.config` 本身 | **不要直接用**：厂商符号在主线不存在，且会打开无关驱动 |
| 启动/功耗/PMIC 结论（docs/02） | 用于 bring-up 排查（AXP313A、USB VBUS、SD 卡检测） |

**推荐主线做法**：

```bash
make ARCH=arm64 defconfig
scripts/kconfig/merge_config.sh -m .config \
  kernel/config/opiz3-h618-mainline.fragment
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- olddefconfig
# 再单独加：UWE5622 DKMS 或 USB WiFi 驱动；补 mmc1 节点（若用板载 WiFi）
```

---

## 5. 建议的决策树

```
需要板载 WiFi（UWE5622）吗？
├─ 是 → 用官方 6.1 厂商内核（方案 A）           ← 你的场景，推荐
│        若必须主线：6.12/6.18 LTS + Armbian DKMS + 自补 mmc1（方案 B）
│        不要用 7.4-rc（DKMS 不支持）
└─ 否 → 可以用 USB WiFi 网卡
          ├─ 要长期维护 → 6.12/6.18 LTS + 主线 UVC + USB WiFi（方案 D）
          └─ 要最新特性 → 7.4 也可以，但仍无硬编，性能同 6.1

需要 H.264 硬件编码吗？
├─ 是 → 6.1/7.4 都不行；Android 12/5.4 厂商栈（未证实）或换 RK3566/RK3588
└─ 否 → 软件 x264，480p 20–30 fps（docs/12）
```

---

## 6. 如果仍要上 7.4：最小验证清单

1. **WiFi**：`armbian/uwe5622` 的 `7.3-compat-v2` 分支能否在 7.4 编译？
   `dkms install` → `modprobe uwe5622_bsp_sdio sprdwl_ng sprdbt_tty` → `iw dev` 能否看到 wlan0。
2. **DTS**：补 `&mmc1 { vmmc/vqmmc/mmc-pwrseq/bus-width=4/non-removable; }` 与 `wifi-pwrseq` 节点。
3. **PMIC**：确认 AXP313A 中断 parent（主线仍写 `&pio` 的已知问题）是否导致启动 hang。
4. **USB/UVC**：`v4l2-ctl --list-devices`、`--list-formats-ext`、30fps 抓流不丢帧。
5. **编码/推流**：x264 speed、RTP 收流、1h 稳定性、WiFi 吞吐/延迟。
6. **回退**：保留 6.1 镜像与串口救砖路径。

> 只要第 1 项过不了（很可能），7.4 方案就不成立；这与“配置分析做得多好”无关。

---

## 7. 最终建议

- **你的场景（UVC + 板载 WiFi + RTP）：官方 6.1 厂商内核是更有效的组合。**
  它开箱有 WiFi、固件、UVC、USB、PMIC、thermal，软件 x264 的性能与 7.4 相同。
- **7.4 不是“更有效”，而是“更新但更不完整”**：没有板载 WiFi 驱动、没有 H.264 编码器、还是 rc 版。
- 若目标是长期主线维护：选 **6.12/6.18 LTS**（不是 7.4-rc）+ Armbian uwe5622 DKMS + 自补 `mmc1`；
  或者换 **USB WiFi 网卡**，彻底绕开 UWE5622。
- 若目标是 720p/1080p 实时：**换平台**（RK3566/RK3588 有标准 V4L2 硬编），不要在 H618 的内核版本上折腾。

---

## 8. 参考

- [docs/12](12_H618_WebCam_H264_RTP理论性能分析.md) —— UVC→H.264→RTP 性能与硬编现状
- [docs/08](08_社区与主线调研.md) —— 主线支持时间线、UWE5622 身份、GPU/VPU
- [docs/09](09_H618内核适配与编译方案.md) —— 6.1 配置/设备树/工具链
- [docs/07](07_orangepi-build内核机制与配置分析.md) —— 6.1 配置审计（可当主线核对表）
- `kernel/config/opiz3-h618-mainline.fragment` —— 主线基线片段
- kernel.org 发布状态（2026-11-02）：mainline 7.4-rc1、longterm 6.18.60/6.12.115/6.1.191
- [armbian/uwe5622](https://github.com/armbian/uwe5622) —— 支持 6.1/6.12/6.18/7.0/7.1，无 7.4
- 抓取证据：[docs/evidence/kernel_version_evidence.md](evidence/kernel_version_evidence.md)
