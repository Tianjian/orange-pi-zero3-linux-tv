# 内核版本选型证据（抓取 2026-11-02）

## 1. kernel.org 发布状态

来源：<https://www.kernel.org/>、<https://www.kernel.org/releases.json>

| 通道 | 版本 |
|---|---|
| mainline | **7.4-rc1** |
| stable | 7.3.1 |
| stable | 7.2.15 |
| longterm | 6.18.60 |
| longterm | 6.12.115 |
| longterm | 6.6.161 |
| longterm | **6.1.191** |

结论：7.4 尚为 **rc1**（非稳定版）；若跟主线，应选 **6.18 LTS 或 6.12 LTS**，而不是 7.4-rc。

## 2. Armbian uwe5622（板载 WiFi 的主线替代驱动）

来源：<https://github.com/armbian/uwe5622>（master，README 与 dkms.conf，2026-11-02 抓取）

- 仓库描述：**“AW859A / UWE5622 Linux driver”**（与 `docs/08` §3 的芯片身份结论一致）。
- README “Kernel Compatibility” 明确列出支持版本：
  **Linux 6.1 / 6.12 / 6.18 / 7.0 / 7.1** —— **不含 7.4**。
- 分支列表（GitHub API）：`master`、`7.3-compat-v2`、`add-vendor-next-to-ci`
  → 说明兼容工作推进到 7.3 一带，7.4 尚无支持分支。
- `dkms.conf`：编译 `uwe5622_bsp_sdio`（`CONFIG_AW_WIFI_DEVICE_UWE5622=y`）、
  `sprdwl_ng`、`sprdbt_tty` 三个模块；即 6.1 树内同名驱动。

## 3. 对结论的支撑

| 结论 | 证据 |
|---|---|
| 7.4 非稳定版 | kernel.org mainline 7.4-rc1 |
| 7.4 无板载 WiFi 支持 | uwe5622 支持列表最高 7.1；分支最高 7.3-compat |
| 6.18/6.12 可用 DKMS | uwe5622 支持列表包含 6.12/6.18 |
| 6.1 仍可作基线 | kernel.org longterm 6.1.191；厂商树内驱动（docs/07） |
| 7.4 无 H.264 编码 | 主线 cedrus 仅解码（docs/12、hardware/ref/cedrus-6.1） |
