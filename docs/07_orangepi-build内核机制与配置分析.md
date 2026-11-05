# 07 orangepi-build 内核机制与 6.1 配置分析（Orange Pi Zero 3 / H618）

> 定位：这是**内核侧的机制与配置审计**，回答“官方 next（6.1）镜像到底编进了什么、缺什么、
> 和 5.4 BSP 差在哪、怎么在 SDK 之外复现”。面向使用者的编译流程（build.sh 菜单、产物 deb、
> 刷机）见 `docs/04_orangepi-build_SDK.md`；硬件与引脚见 `docs/01`/`docs/02`/`docs/03`。
>
> 审计对象（只读，未修改）：
>
> | 对象 | 路径 | 事实 |
> |---|---|---|
> | SDK | `vendor/orangepi-build`（浅克隆，`git log -1` = `a95129b rk3588: Ubuntu 26.04 / Debian 13 with Linux 6.18`，分支 `next`） | 只含 config/scripts/patch/packages，**不含内核与 u-boot 源码** |
> | 6.1 内核 | `kernel/src/linux-6.1`（`orange-pi-6.1-sun50iw9`，HEAD `71144529b`，2024-07-10） | `Makefile` 的 `VERSION=6 PATCHLEVEL=1 SUBLEVEL=31` |
> | 6.1 配置 | `vendor/orangepi-build/external/config/kernel/linux-6.1-sun50iw9-next.config`（8442 行） | 头注释 `# Linux/arm64 6.1.31 Kernel Configuration` |
> | 5.4 配置 | `vendor/orangepi-build/external/config/kernel/linux-sun50iw9-current.config`（6457 行） | 头注释 `# Linux/arm64 5.4.125 Kernel Configuration` |
> | 板级 | `vendor/orangepi-build/external/config/boards/orangepizero3.conf`（15 行） | `BOARD_NAME="OPI Zero3"`、`REVISION="1.0.6"` |
>
> 5.4 的**内核源码本工作区未克隆**，凡需要看 5.4 实现细节的结论一律标注“未确认”，
> 只用其 `.config` 做符号级对照。
>
> 附表（本文引用的机器可核对清单）：
> - `kernel/config-audit/peripheral_matrix.csv`（外设→符号→值→行号→DTS→绑定驱动→结论）
> - `kernel/config-audit/config_diff_5.4_vs_6.1.md`（5.4/6.1 符号与实现对照、复算命令）

---

## 0. 结论速览（10 条）

1. **6.1 是“主线化 + 厂商代码合入源码树”的混合内核**：显示走 DRM、GPU 走 Panfrost、解码走
   cedrus、USB 走 MUSB/ehci-platform、以太网走 dwmac-sun8i；但音频 codec、AHUB 声卡、PWM 增强、
   红外、sys_info/addr_mgt、uwe5622 仍是厂商代码——**不在补丁目录里，而是已合进
   `orange-pi-6.1-sun50iw9` 分支**（`external/patch/` 下根本没有 `kernel/`）。
2. **`KERNELPATCHDIR=sun50iw9-next` 是空指向**：`external/patch` 只有 `atf/`、`misc/`；
   `advanced_patch()` 因 `shopt -s nullglob` 对不存在的目录**静默跳过、不报错**
   （`compilation.sh:967-996`），所以这套 6.1 编译**不打任何内核补丁**。
3. **镜像类型是 `Image`，不是 zImage**：`arm64.conf:14` 无条件 `KERNEL_IMAGE_TYPE=Image`，
   覆盖 `configuration.sh:127` 的 `zImage`；u-boot 启动脚本也是 `load ... ${prefix}Image`
   （`boot-sun50iw9-next.cmd:85`）。
4. **`LOCALVERSION=-sun50iw9`**（`compilation.sh:498`、`:542`）；deb 版本 `KDEB_PKGVERSION=
   $REVISION`=`1.0.6`（board:15），包名 `linux-image-next-sun50iw9`/`linux-dtb-next-sun50iw9`
   （`scripts/package/mkdebian:98,101`）。
5. **本文编进去的（=y，开机即用）**：CCU/pinctrl/MMC/SPI/I2C/8250_dw/DMA/thermal/watchdog/RTC/
   SID/IOMMU/MBUS/SRAM/crypto-CE、**整套 DRM 显示 + dw-hdmi**、**MUSB OTG + EHCI/OHCI**、
   AXP313A(MFD/regulator/PEK)、**厂商 codec + AHUB 声卡**、**厂商增强 PWM**、
   **uwe5622 BSP 驱动**（`AW_WIFI_DEVICE_UWE5622=y`）。
6. **是模块（=m，要加载）**：`IR_SUNXI`+`RC_CORE`、`DRM_PANFROST`、`VIDEO_SUNXI_CEDRUS`、
   `DWMAC_SUN8I`+`MOTORCOMM_PHY`、`sprdwl_ng`/`sprdbt_tty`/`uwe5622_bsp_sdio`、
   `CFG80211`/`MAC80211`/`RFKILL`/`BT`、`USB_CONFIGFS`、`SUNXI_ADDR_MGT`、`LEDS_GPIO` 等；
   `=m` 共 **2909 个**（5.4 只有 847 个）。
7. **缺失/关闭**：GPU 节点 DTS 里 `status="disabled"`（dts:120-123、dtsi:190），需
   `overlays=gpu`；无 HDMI-CEC；6.1 侧**没有** H616 视频编码、G2D、DI、厂商 DISP2/HDMI2、
   Mali blob 驱动、SPDIF/DMIC。
8. **5.4 与 6.1 的本质差异是驱动模型换代**：5.4 用 34 个 `CONFIG_SUNXI*` 厂商符号（`DISP2_SUNXI`/
   `USB_SUNXI_HCI`/`SERIAL_SUNXI`/`SPI_SUNXI`/`SUNXI_GPU_TYPE`…），6.1 只剩 9 个；同名符号里
   **334 个从 `=y` 降为 `=m`**，仅 42 个反向。
9. **uwe5622 是“内核树内编译”的**：`.ko` 由 `drivers/net/wireless/uwe5622/` 编出
   （`AW_WIFI_DEVICE_UWE5622=y` → `obj-m`），固件以 C 数组**编进 `uwe5622_bsp_sdio.ko`**；
   `MODULES_NEXT` 只是 `/etc/modules` 的清单（`distributions.sh:98-103`），`.ko` 随
   `linux-image` deb 落盘。
10. **独立复现**：`scripts/build_kernel.sh` 用同一分支/`.config`/工具链（Arm GNU 11.2）直接
    `make Image modules dtbs`；与 SDK 差别是没有 `bindeb-pkg`、ccache、`-j(CPUS*1.5)`、deb 版本号。

---

## 1. 内核来源与版本绑定

### 1.1 三级配置：board → family → arch

`BOARD` 由 `build.sh` 的菜单或 `BOARD=` 参数决定，随后加载三个配置文件（顺序很重要）：

| 阶段 | 文件 | 关键行 |
|---|---|---|
| 板级 | `external/config/boards/orangepizero3.conf` | `BOARD_NAME="OPI Zero3"`(2)、`BOARDFAMILY="sun50iw9"`(3)、`BOOTCONFIG="orangepi_zero3_defconfig"`(4)、`KERNEL_TARGET="current,next"`(5)、`MODULES_*`(6-8)、`MODULES_BLACKLIST_LEGACY/CURRENT="bcmdhd"`(9-10)、`BOOT_LOGO="desktop"`(14)、`REVISION="1.0.6"`(15) |
| 家族 | `external/config/sources/families/sun50iw9.conf` | 第 1 行先 `source include/sunxi64_common.inc`；`LINUXFAMILY=sun50iw9`(3)；`CPUMIN=480000`/`CPUMAX=1512000`(5-6)；`GOVERNOR=ondemand`(7)；`ASOUND_STATE=asound.state.sun50iw9-${BRANCH}`(9)；三个分支 case(11-77) |
| 架构 | `external/config/sources/arm64.conf` | `ARCHITECTURE=arm64`/`ARCH=arm64`(12-13)、`KERNEL_IMAGE_TYPE=Image`(14)、`KERNEL_COMPILER`(26-34)、`KERNELDIR="${SRC}/kernel"`(47)、`KERNELSOURCE="${GIT_SERVER}/linux-orangepi.git"`(48) |

加载顺序在 `scripts/configuration.sh` 里：

```bash
sed -n '124,160p' scripts/configuration.sh
# 126  ARCH=armhf                      ← 先给个 armhf 兜底
# 127  KERNEL_IMAGE_TYPE=zImage       ← 随后被 arm64.conf:14 覆盖成 Image
# 151  source "${EXTER}/config/sources/families/${LINUXFAMILY}.conf"   ← 家族（含 sunxi64_common.inc → ARCH=arm64）
# 159  source "${EXTER}/config/sources/${ARCH}.conf"                   ← 架构（此时 ARCH=arm64）
```

> 这就是“任务描述里说 zImage、实际却是 Image”的根因：`zImage` 只对 32 位 armhf 板生效。
> 实测证据：`external/config/bootscripts/boot-sun50iw9-next.cmd:85` 是
> `load ${devtype} ${devnum} ${kernel_addr_r} ${prefix}Image`。

### 1.2 三个分支的内核/u-boot/ATF 组合（`sun50iw9.conf`）

| 分支 | 内核分支 | u-boot | ATF | 其它 |
|---|---|---|---|---|
| `legacy`（4.9） | `branch:orange-pi-4.9-sun50iw9`(15) | `branch:v2018.05-sun50iw9`(16) | `ATFSOURCE=""`、`ATF_COMPILE="no"`(26-27) | `UBOOT_COMPILER="arm-linux-gnueabi-"`(20)、`OFFSET=20`(25) |
| `current`（5.4） | `branch:orange-pi-5.4-sun50iw9`(35) | `branch:v2018.05-h618`（zero3 命中，38 行） | 同上，禁用(48-49) | `UBOOT_TARGET_MAP=";;dts/${BOARD}-u-boot.dts boot0_sdcard.fex boot_package.fex"`(41) |
| `next`（6.1） | `branch:orange-pi-6.1-sun50iw9`(73) | `branch:v2024.01`（64-66 行，zero3 命中） | `ATFSOURCE='https://github.com/ARM-software/arm-trusted-firmware'`、`ATFBRANCH='commit:4b9be5abfa8b1a7c7e00776da01768d3358e648a'`(57-58)、`ATF_PLAT="sun50i_h616"`(59)、`ATF_TARGET_MAP='PLAT=sun50i_h616 DEBUG=1 bl31;;build/sun50i_h616/debug/bl31.bin'`(60) | `UBOOT_TARGET_MAP=';;u-boot-sunxi-with-spl.bin'`(61)、`OVERLAY_PREFIX='sun50i-h616'`(56)、`LINUXCONFIG="linux-6.1-sun50iw9-next"`(74) |

细节：next 的 ATF 是 **`DEBUG=1`** 构建（60 行），产物 `build/sun50i_h616/debug/bl31.bin` 由
`compile_atf()`（`compilation.sh:90-110`）打进 u-boot deb；next 的 u-boot 用主线打包
（`u-boot-sunxi-with-spl.bin`），current/legacy 用 `boot0_sdcard.fex + boot_package.fex`
（写盘见 `sunxi64_common.inc:84-99`）。`KERNEL_TARGET="current,next"`（board:5）即两条线都支持。

### 1.3 内核源码怎么来

`scripts/main.sh:485`：

```bash
[[ $BUILD_OPT =~ kernel|image ]] && fetch_from_repo "$KERNELSOURCE" "$KERNELDIR" "$KERNELBRANCH" "yes"
```

- `KERNELSOURCE=https://github.com/orangepi-xunlong/linux-orangepi.git`（arm64.conf:48）
- `KERNELDIR=$SRC/kernel`（arm64.conf:47）——即 `vendor/orangepi-build/kernel/`
- `KERNELBRANCH=branch:orange-pi-6.1-sun50iw9`（sun50iw9.conf:73）
- `fetch_from_repo()`（`general.sh:497` 起）会先把 `https://github.com/` 替换成 `$GITHUB_SOURCE`，
因此 `GITHUB_MIRROR=gitclone|fastgit` 会改变实际拉取地址（`configuration.sh:112-122`）。
本工作区的 6.1 源码是**独立浅克隆**到 `kernel/src/linux-6.1` 的（不是 SDK 的 `kernel/`），
同一分支 HEAD `71144529b`。

### 1.4 内核版本号怎么算

`grab_version()`（`compilation.sh:868-876`）直接读目标树的 `Makefile` 的
`VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION`，拼成 `6.1.31`，用于：

用于 `linux-version compare "${version}" ge 4.3` 选择 `bindeb-pkg`（`compilation.sh:518-522`），
打完补丁后会在 415 行再读一次。

---

## 2. 工具链：选谁、从哪来、怎么选

### 2.1 编译器前缀与版本要求

| 变量 | 值 | 出处 |
|---|---|---|
| `KERNEL_COMPILER` | amd64 主机上 `aarch64-none-linux-gnu-`；aarch64 原生主机上 `aarch64-linux-gnu-` | `arm64.conf:26-34` |
| `KERNEL_USE_GCC` | current/legacy = `> 10.0`；**next 未显式设置** → 继承 `> 8.0` | `sun50iw9.conf:24`(legacy)、`:46`(current)；next case(54-75) 无此项 → `arm64.conf:46` |
| `ATF_COMPILER` | `aarch64-none-linux-gnu-`（amd64 主机） | `arm64.conf:31` |
| `UBOOT_COMPILER` | `aarch64-none-linux-gnu-` | `arm64.conf:32` |

> ⚠️ 这是容易搞错的一点：next 分支用的是 `> 8.0`，会选到 **9.2**（§2.3），不是 11.2。
> `configuration.sh:412-414` 对三个 `*_USE_GCC` 做非空校验，为空直接 `exit_with_error`。

### 2.2 toolchains/ 目录与下载逻辑

`prepare_host()` 在 amd64 主机上、且 `SKIP_EXTERNAL_TOOLCHAINS != yes` 时，按 `BOARDFAMILY`
选一组工具链并**全部下载解包到 `$SRC/toolchains/`**（`general.sh:1564-1626`）：

```bash
sed -n '1577,1600p' vendor/orangepi-build/scripts/general.sh   # sun50iw9 家族会下载 13 个包：
# ky-toolchain / gcc-linaro-{4.8,4.9.4,5.5.0,7.4.1} / gcc-arm-9.2 / gcc-arm-11.2 ...
```

下载源与镜像（`general.sh:1664-1715`）：

- 默认：`server=${ARMBIAN_MIRROR}`（`configuration.sh:618-626` 用 `redirect.armbian.com` 探测）
- `DOWNLOAD_MIRROR=china` → `https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/`（1705-1706）
  —— **本 SDK 默认就是这个**（`config-example.conf:15` `DOWNLOAD_MIRROR="china"`；
  `configuration.sh:23` 的 `CHINA_DOWNLOAD_MIRROR=huawei` 只影响 apt/rootfs 源，不影响工具链）
- `ky`/`arm-gnu-toolchain` 包强制走 `http://www.iplaystore.cn/upload/`（1713-1715）
- 失败重试：原源 → tuna → bfsu（1721-1739）；`.download-complete` 标记存在则跳过（1717-1719）

### 2.3 find_toolchain：按版本表达式挑“最接近”的

`compilation.sh:882-920`：

算法（`compilation.sh:882-920`）：遍历 `$SRC/toolchains/*/bin/${compiler}gcc`，取
`-dumpversion` 的 major.minor，先 `awk` 校验 `$gcc_ver $expression`，再取与表达式里目标版本
距离最小者；`SKIP_EXTERNAL_TOOLCHAINS=yes` 时直接返回 `/usr/bin`。

- `> 8.0`：9.2 与 11.2 都满足，`|8.0-9.2|=1.2 < |8.0-11.2|=3.2` → **选 9.2**（不是 11.2！）
- `> 10.0`：只有 11.2 满足 → 选 11.2

> 结论（重要）：**next 分支（`> 8.0`）在“干净 SDK + 默认下载全部工具链”时会选到
> `gcc-arm-9.2-2019.12`**；只有 current/legacy（`> 10.0`）才必然选 11.2。
> 本仓库固定用 11.2 属于更保守的选择；官方发布日志显示 11.x（`docs/04` §5.3），
> 说明官方服务器上的实际选择与“最接近”算法不一致——**该推断未在真机复现，标注未确认**。

### 2.4 编译时的 CCACHE 拼接

`main.sh:121-133`：除非 `USE_CCACHE=no`，否则 `CCACHE=ccache` 且把 `/usr/lib/ccache`
前置到 `PATH`；`PRIVATE_CCACHE=yes` 时 `CCACHE_DIR=$EXTER/cache/ccache`。
所以 `compilation.sh` 里所有 `CROSS_COMPILE="$CCACHE $KERNEL_COMPILER"` 在默认配置下等于
`CROSS_COMPILE="ccache aarch64-none-linux-gnu-"`。
**`ccache` 是隐式必备依赖**：缺失时 `make` 会报 `ccache: command not found`。

---

## 3. 编译流水线：`compile_kernel()` 逐段拆解

入口在 `scripts/main.sh:591-606`：

`main.sh:591-597`：`if [[ $BUILD_OPT == kernel || image ]]` 且
`[[ ! -f ${DEB_STORAGE}/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb ]]` 时才
`compile_kernel`。两个注意点：

- **已有同名 deb 就跳过编译**（594 行）——所以要改代码先删
  `${DEB_STORAGE}/linux-image-next-sun50iw9_1.0.6_arm64.deb`（`docs/04` §5.5 有同样结论）。
- `REPOSITORY_INSTALL` 含 `kernel` 时直接用官方预编译 deb，不编译。

`compile_kernel()` 本体在 `scripts/compilation.sh:372-593`，按执行顺序：

### 3.1 清理与 overlayfs（372-385）

`compilation.sh:374-385`：`CLEAN_LEVEL` 含 `make` 才 `make clean`；`USE_OVERLAYFS=yes` 时
`kerneldir=$(overlayfs_wrapper wrap ...)`，否则 `kerneldir="$LINUXSOURCEDIR"`。

- `CLEAN_LEVEL` 默认值来自 `external/config/templates/config-example.conf:2`
  `CLEAN_LEVEL="debs,oldcache"`——**不含 `make`**，所以默认不 `make clean`（增量编译）。
- `USE_OVERLAYFS` 默认**未设置**（config-example.conf 里没有这一项），所以默认直接在
  `$SRC/kernel` 里编译；只有 `USE_OVERLAYFS=yes` 时才用 `overlayfs_wrapper()`（`compilation.sh:1088-1120`）
  在 `/tmp` 上叠一层可写层，保持源码目录干净（`/tmp` 必须是 tmpfs，且不建议与 `CREATE_PATCHES=yes` 同用，1082-1086 行注释）。

### 3.2 版本与 git hash（387-415）

`compilation.sh:387-415`：**先 `rm -f localversion`**（387，源码树里的同名文件会被忽略），
然后用 `grab_version()`（868-876）读版本、`rev-parse HEAD` 取 hash；397 行判断
`$EXTER/patch/kernel/$KERNELPATCHDIR/series.conf`，408 行调
`advanced_patch "kernel" "$KERNELPATCHDIR" "$BOARD" "" "$BRANCH" "$LINUXFAMILY-$BRANCH"`，
415 行**打完补丁再读一次版本**。`rm -f localversion` 意味着源码树里即使有 `localversion`
文件也会被忽略，版本后缀只由 `make LOCALVERSION=...` 决定（见 §3.6）。

### 3.3 工具链选择（419-431）

`compilation.sh:419-431`：`dpkg-architecture -e "${ARCH}"` 为真→原生编译；amd64 主机→
`find_toolchain`，为空则 `exit_with_error "Could not find required toolchain"`。

### 3.4 `.config` 的三个来源（433-445）

`compilation.sh:433-445` 的优先级：`$DEST/config/<LINUXCONFIG>.config`（需
`KERNEL_KEEP_CONFIG=yes`）> `$USERPATCHES_PATH/<LINUXCONFIG>.config` >
`$EXTER/config/kernel/<LINUXCONFIG>.config`。对 Zero3 next，`LINUXCONFIG="linux-6.1-sun50iw9-next"`
（`sun50iw9.conf:74`），默认命中的就是本文开头“审计对象”表里那份官方配置。

随后 `call_extension_method "custom_kernel_config"`（447-452）是**扩展点**：在
`olddefconfig` 之前拿到“干净”的 `.config`；SDK 自身不注册实现，默认不做事。

### 3.5 `olddefconfig`（455-485）

`compilation.sh:455-485`：

- `KERNEL_CONFIGURE != yes` → legacy 分支走 `silentoldconfig`，其它（含 sun50iw9 next）走
  **`olddefconfig`**：只补新符号，不改已有选择。
- `KERNEL_CONFIGURE=yes` → `oldconfig` + `menuconfig`，并把结果**写回 SDK 配置**
  （478 行 `cp .config "${EXTER}/config/kernel/${LINUXCONFIG}.config"`）——这是唯一会改到
  `vendor/orangepi-build` 的路径，本仓库保持只读。
- 456 行把 `patch/misc/headers-debian-byteshift.patch` 复制到 `/tmp`，本流程未见引用点（**未确认**作用）。

### 3.6 编译与产物校验（493-508）

`compilation.sh:494-507` 的 make 行（逐项解释见下表）：

```make
make $CTHREADS ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" \
     $SRC_LOADADDR LOCALVERSION="-$LINUXFAMILY" \
     $KERNEL_IMAGE_TYPE ${KERNEL_EXTRA_TARGETS:-modules dtbs}
# 505 行用 -f arch/$ARCHITECTURE/boot/$KERNEL_IMAGE_TYPE 校验产物，失败即 exit_with_error
```

| 变量 | 值（Zero3 next） | 说明 |
|---|---|---|
| `CTHREADS` | `-j$((CPUS + CPUS/2))`（`main.sh:398`，`USEALLCORES != no`） | 默认 1.5 倍核数，不是 `nproc` |
| `ARCH` | `ARCHITECTURE`=`arm64` | 与 `ARCH=arm64` 等价 |
| `CROSS_COMPILE` | `ccache aarch64-none-linux-gnu-` | 见 §2.4 |
| `SRC_LOADADDR` | **空** | 只有 `meson64_common.inc:7` 设置了 `LOADADDR=0x1080000`，sunxi 家族没有 |
| `LOCALVERSION` | `-sun50iw9` | 来自 `LINUXFAMILY`，不是板名 |
| `KERNEL_IMAGE_TYPE` | `Image` | 见 §1.1 |
| 额外目标 | `modules dtbs` | 可用 `KERNEL_EXTRA_TARGETS` 覆盖 |

`dtbs` 目标里包含 **DT overlay**：`arch/arm64/boot/dts/allwinner/Makefile:6` 有
`subdir-y := $(dts-dirs) overlay`，overlay 目录的 `Makefile:2-33` 用 `dtbo-$(CONFIG_ARCH_SUNXI)`
列出 27 个 `.dtbo` + 1 个 `sun50i-h616-fixup.scr`。

### 3.7 打包：`bindeb-pkg`（517-556）

`compilation.sh:518-556`：版本 ≥4.3 → `kernel_packing=bindeb-pkg`，然后
`make $CTHREADS bindeb-pkg KDEB_PKGVERSION=$REVISION KDEB_COMPRESS=$DEB_COMPRESS
LOCALVERSION=-$LINUXFAMILY KBUILD_DEBARCH=$ARCH DEBFULLNAME=... DEBEMAIL=...`，
最后 `rm -f linux-firmware-image-*.deb` 并把 `*.deb` rsync 到 `$DEB_STORAGE`。

- deb 版本号 = `KDEB_PKGVERSION=$REVISION`=`1.0.6`（board:15），不是内核版本号；
  `KDEB_COMPRESS=xz`（`configuration.sh:16`）让编包阶段明显慢于编译本身。
- 包名见 `scripts/package/mkdebian:98,101`：`linux-image-$BRANCH$LOCALVERSION` →
  `linux-image-next-sun50iw9`，`linux-dtb-next-sun50iw9`，headers 一并产出
  （即 `docs/04` §5.4 那三个 deb）。
- **`linux-firmware-image-*.deb` 被主动删除**（554 行）：内核 deb 不含 `linux-firmware`，
  固件要么编进 .ko（uwe5622），要么来自 rootfs 的 `linux-firmware` 包。
- 558 行 `family_tweaks_kernel`：sun50iw9 家族未定义（只有 `family_tweaks_s`/`_bsp`），no-op。

### 3.8 与内核编译相关的开关汇总

| 开关 | 默认 | 出处 | 影响 |
|---|---|---|---|
| `KERNEL_CONFIGURE` | 空（会弹菜单） | `main.sh:267-281`、`config-example.conf:1` | `no`=olddefconfig 不交互；`yes`=menuconfig 并回写 SDK 配置 |
| `CLEAN_LEVEL` | `debs,oldcache` | `config-example.conf:2` | 加 `make` 才会 `make clean`（`compilation.sh:374`） |
| `USE_CCACHE` | 空 → **启用** | `main.sh:121` | 需要宿主机装 `ccache` |
| `PRIVATE_CCACHE` | 空 | `main.sh:127` | `yes` 时 `CCACHE_DIR=$EXTER/cache/ccache` |
| `USE_OVERLAYFS` | 空 → 不启用 | `compilation.sh:379` | 启用后源码树只读，构建在 `/tmp` 叠加层 |
| `KERNEL_KEEP_CONFIG` | 空 | `compilation.sh:434` | `yes` 时复用 `$DEST/config/<LINUXCONFIG>.config` |
| `KERNEL_EXPORT_DEFCONFIG` / `BUILD_KSRC` | 空 / `no` | `compilation.sh:480` / `configuration.sh:144` | 前者仅在 `KERNEL_CONFIGURE=yes` 时生效；后者 `yes` 时先打 `linux-source` 包 |
| `KERNEL_EXTRA_TARGETS` | 空（默认 `modules dtbs`） | `compilation.sh:499` | 可改成只编 `Image` |
| `USEALLCORES` / `SKIP_EXTERNAL_TOOLCHAINS` | `yes` / 空 | `configuration.sh:18` / `general.sh:1566` | 前者决定 `CTHREADS` 是否 1.5 倍核数；后者 `yes` 时不下载工具链、直接用 `/usr/bin` |

---

## 4. 补丁目录审计：`KERNELPATCHDIR=sun50iw9-next` 到底打了什么

### 4.1 事实：`external/patch` 里没有 `kernel/`

```bash
$ ls vendor/orangepi-build/external/patch/
atf  misc
$ ls vendor/orangepi-build/external/patch/kernel
ls: cannot access '.../external/patch/kernel': No such file or directory
$ git -C vendor/orangepi-build ls-tree -d --name-only HEAD external/patch
external/patch/atf
external/patch/misc
```

`external/patch/atf` 只有 `atf-rk3399`、`atf-rockchip64`、`atf-sunxi64`（最后一个是给
sunxi64 家族的 H6，不是 sun50iw9）；`external/patch/misc` 是通用/打包类补丁
（`headers-debian-byteshift.patch`、`0001..0012-bootsplash.patch`、`compiler.patch`、
若干 wireless 补丁等）。

### 4.2 `KERNELPATCHDIR` 的赋值链路

- current/legacy 显式写 `KERNELPATCHDIR=${BOARDFAMILY}-${BRANCH}`（`sun50iw9.conf:40` / `:18`）
  → `sun50iw9-current` / `sun50iw9-legacy`。
- `next` case（54-75 行）**没有**写，落到 `configuration.sh:421` 默认
  `KERNELPATCHDIR="$LINUXFAMILY-$BRANCH"` → **`sun50iw9-next`**；`LINUXCONFIG` 同理由
  `configuration.sh:418` 兜底（next 在 74 行显式写成 `linux-6.1-sun50iw9-next`，两者恰好一致）。

### 4.3 `advanced_patch()` 对“不存在的目录”的行为（关键）

`compilation.sh:941-997`：

```bash
941  advanced_patch() {
943      local dest=$1          # "kernel"
944      local family=$2        # "sun50iw9-next"   ← KERNELPATCHDIR
946      local target=$4        # ""（compile_kernel 传空）
947      local branch=$5        # "next"
948      local description=$6   # "sun50iw9-next"
953      local names=()
954      local dirs=(
955        "$USERPATCHES_PATH/$dest/$family/target_${target}:..."
956        "$USERPATCHES_PATH/$dest/$family/board_${board}:..."
957        "$USERPATCHES_PATH/$dest/$family/branch_${branch}:..."
958        "$USERPATCHES_PATH/$dest/$family:..."
959        "$EXTER/patch/$dest/$family/target_${target}:..."
960        "$EXTER/patch/$dest/$family/board_${board}:..."
961        "$EXTER/patch/$dest/$family/branch_${branch}:..."
962        "$EXTER/patch/$dest/$family:..."
963      )
967      shopt -s nullglob dotglob          ← 决定一切
969      for dir in "${dirs[@]}"; do
970          for patch in ${dir%%:*}/*.patch; do names+=($(basename "${patch}")); done
974          if [[ -d ${dir%%:*} ]]; then ...links... fi
979      done
983      local names_s=($(echo "${names[@]}" | tr ' ' '\n' | LC_ALL=C sort -u | tr '\n' ' '))
985      for name in "${names_s[@]}"; do ... process_patch_file ... done
```

逐条推演（对 Zero3 next）：

| dirs 元素 | 展开后 | 存在？ |
|---|---|---|
| `$USERPATCHES_PATH/kernel/sun50iw9-next/{target_,board_orangepizero3,branch_next,}` | `output/userpatches/kernel/...` | 否（首次运行只镜像 `$EXTER/patch` 已存在的 `atf/misc`，`general.sh:1647-1648`） |
| `$EXTER/patch/kernel/sun50iw9-next/{target_,board_orangepizero3,branch_next,}` | `external/patch/kernel/...` | 否（连 `external/patch/kernel` 都没有） |

因为 `nullglob` 生效，`for patch in <不存在目录>/*.patch` **一次都不迭代**，`names`/`names_s`
保持空，985 行循环零次执行。**整个过程不报错、不打补丁**；950-951 行的 `display_alert`
仍会打印 “Started patching process for kernel”，容易让人误以为“打了补丁”。

> 反例（如果目录存在）：`advanced_patch` 的优先级是
> `userpatches/target_* > userpatches/board_* > userpatches/branch_* > userpatches/`
> `> external/patch/target_* > external/patch/board_* > external/patch/branch_* > external/patch/`
> （`compilation.sh:931-939` 的注释 + 954-963 行的顺序）。
> 同名补丁只应用**第一个命中的目录**（993 行 `break`），空的补丁文件会被 `skipped`（988-992 行）。
> 应用失败是否中止取决于 `EXIT_PATCHING_ERROR`（`configuration.sh:21` 默认空 → 只告警不中止，
> `compilation.sh:1016-1021`）。

### 4.4 `series.conf` 分支：两个潜在的坑（本次不会触发）

`compilation.sh:397-403`：

```bash
397  if test -f "${EXTER}"/patch/kernel/${KERNELPATCHDIR}/series.conf; then
399      series_conf="${SRC}"/patch/kernel/${KERNELPATCHDIR}/series.conf     ← 注意是 ${SRC}
402      apply_patch_series "${kerneldir}" "$series_conf"
403  fi
```

1. **判断用 `${EXTER}`、读取用 `${SRC}`**：`EXTER=$SRC/external`（`build.sh:205`），即判断
   `external/patch/kernel/...`、却去读 `$SRC/patch/kernel/...`（`vendor/orangepi-build/patch/`
   不存在）。真放了 `series.conf` 就会读到不存在的路径。
2. **`apply_patch_series` 在整个 SDK 里没有定义**：
   `grep -rn "apply_patch_series" vendor/orangepi-build/` 只有 401-402 两行（注释 + 调用），
   `grep -rn "apply_patch_series()"` 无结果。真走进去会 `command not found`，
   属于**上游遗留的坏代码路径**。

### 4.5 结论

- **这套 6.1 内核在 SDK 里“零内核补丁”**：没有 `external/patch/kernel/sun50iw9-next/`，
  也没有 `userpatches/kernel/...`，`series.conf` 不存在。
- 因此 6.1 里的厂商驱动（`sun50iw9-codec.c`、`uwe5622/`、`pwm-sunxi-enhance.c`、
  `sunxi-gmac.c`、`ahub` 声卡、`sun50i-h616.dtsi` 的 `ahub*` 节点等）**只能来自
  `orange-pi-6.1-sun50iw9` 分支本身**——厂商把 BSP 直接合进了内核分支，不是打补丁。
- 想改驱动/DTS 就改源码树；要加补丁需自建 `external/patch/kernel/sun50iw9-next/*.patch`，
  且**不要用 `series.conf`**（§4.4 的坑）。

---

## 5. 官方 6.1 `.config` 审计

### 5.0 方法与统计

审计原则：**先在文件里确认符号真实存在，再判断它对应哪个外设**。本文件第 2 行写着

```text
# Automatically generated file; DO NOT EDIT.
# Linux/arm64 6.1.31 Kernel Configuration
```

说明它不是 `defconfig`，而是一份**已经 `olddefconfig` 过、符号基本自洽的完整配置**
（实测见 §5.5）。统计：

```bash
C61=vendor/orangepi-build/external/config/kernel/linux-6.1-sun50iw9-next.config
grep -c '=y$' $C61; grep -c '=m$' $C61; grep -c 'is not set' $C61; grep -c '^CONFIG_' $C61
# → 1965 / 2909 / 1854 / 5002（最后一项含 =字符串/=数字）
```

### 5.1 外设 → 符号 → 值（Zero3 全量，摘自主表）

完整 60+ 行（含 5.4 对照、DTS 状态、绑定驱动）见 `kernel/config-audit/peripheral_matrix.csv`。
下表“行号”均指 `linux-6.1-sun50iw9-next.config`。

**SoC 基础设施 / 存储 / 总线（全部内建，y）**

| 外设 | 符号 | 值 | 行 |
|---|---|---|---|
| SoC / CCU | `ARCH_SUNXI` / `SUN50I_H616_CCU` | y / y | 290 / 6410 |
| pinctrl | `PINCTRL_SUN50I_H616` + `_R` | y + y | 3464 / 3465 |
| CPUfreq | `CPUFREQ_DT` + `ARM_ALLWINNER_SUN50I_CPUFREQ_NVMEM` | y + y | 569 / 571 |
| DMA / 中断 | `DMA_SUN6I` / `SUN6I_R_INTC`+`SUNXI_NMI_INTC` | y / y+y | 6202 / 7190,7191 |
| MBUS/SRAM/IOMMU | `SUNXI_MBUS`+`SUNXI_SRAM`, `SUN50I_IOMMU` | y / y | 6532,6533 / 6466 |
| SID / Crypto / Mailbox | `NVMEM_SUNXI_SID`, `CRYPTO_DEV_SUN8I_CE`, `SUN6I_MSGBOX` | y / y / y | 7268 / 8019 / 6445 |
| MMC | `MMC`+`MMC_BLOCK`+`MMC_SUNXI` | y | 5922 / 5926 / 5956（一个控制器覆盖 mmc0/1/2） |
| SPI | `SPI`+`SPI_SUN6I`（`SPI_SUN4I` 也开） | y | 3340 / 3369 / 3368 |
| SPI NOR / spidev | `MTD_SPI_NOR` / `SPI_SPIDEV` | y / y | 2089 / 3384 |
| I2C | `I2C`+`I2C_MV64XXX`；`I2C_GPIO` | y / **m** | 3262,3303 / 3301 |
| 串口 | `SERIAL_8250`+`_DW`+`_CONSOLE` | y | 3169 / 3180 / 3173 |
| PWM | `PWM`+`PWM_SUNXI_ENHANCE`（厂商）；`PWM_SUN4I` | y / **m** | 7168,7177 / 7176 |

**显示 / GPU / 视频**

| 外设 | 符号 | 值 | 行 | 备注 |
|---|---|---|---|---|
| DRM 核心 | `DRM` | y | 4752 | |
| 显示引擎 | `DRM_SUN4I` | y | 4794 | sun4i-drm |
| Mixer / TCON-TOP | `DRM_SUN8I_MIXER` / `DRM_SUN8I_TCON_TOP` | y / y | 4797 / 4798 | dtsi 用 h616-de33-mixer-0、h6-tcon-top |
| HDMI | `DRM_SUN8I_DW_HDMI` | y | 4796 | compatible 回落 `sun50i-h6-dw-hdmi` |
| DSI | `DRM_SUN6I_DSI` | y | 4795 | H616 dtsi 无 DSI 节点（预留） |
| HDMI 音频 | `SND_SOC_HDMI_CODEC` | y | 5268 | dw-hdmi-ahb-audio |
| GPU | `DRM_PANFROST` | **m** | 4948 | 绑定 `arm,mali-bifrost`；节点默认 disabled |
| GPU(无关) | `DRM_LIMA` | **m** | 4947 | Mali-4xx 用，本板无意义 |
| 硬解码 | `VIDEO_SUNXI_CEDRUS` | **m** | 6324 | staging，支持 h616（cedrus.c:707） |

**音频**

| 项 | 符号 | 值 | 行 |
|---|---|---|---|
| ASoC | `SND` / `SND_SOC` | y / y | 5052 / 5136 |
| 内置 codec | `SND_SUN50IW9_CODEC`（厂商） | **y** | 5181 |
| AHUB 平台 + 声卡 | `SND_SOC_SUNXI_AHUB` / `_MACH` / `_AHUB_DAM` | y | 5197 / 5190 / 5191 |
| 未开 | `SND_SUN4I_CODEC`/`SND_SUN50I_CODEC_ANALOG`/`SND_SUN4I_I2S`/`SND_SUN4I_SPDIF`/`SND_SUN50I_DMIC` | not set | 5180 / 5184 / 5185 / 5186 / 5187 |

**USB**

| 项 | 符号 | 值 | 行 |
|---|---|---|---|
| OTG | `USB_MUSB_HDRC` + `USB_MUSB_SUNXI` + `PHY_SUN4I_USB` | y | 5661 / 5669 / 7212 |
| EHCI/OHCI | `USB_EHCI_HCD`+`_PLATFORM` / `USB_OHCI_HCD`+`_PLATFORM` | y | 5596,5600 / 5605,5606 |
| XHCI（冗余） | `USB_XHCI_HCD` | y | 5592 |
| Gadget | `USB_GADGET` / `USB_CONFIGFS` | y / **m** | 5797 / 5844 |

**网络 / 电源 / 传感器**

| 项 | 符号 | 值 | 行 |
|---|---|---|---|
| 主线 EMAC | `STMMAC_ETH`+`DWMAC_GENERIC`+`DWMAC_SUN8I` | y+y+**m** | 2472 / 2476 / 2478 |
| 厂商 GMAC（不绑定） | `SUNXI_GMAC` | y | 2397 |
| MDIO / PHY | `MDIO_SUN4I` / `MOTORCOMM_PHY` | y / **m** | 2607 / 2528 |
| PMIC MFD | `MFD_AXP20X_I2C`（本板用）/ `MFD_AXP20X_RSB`（不用） | y / y | 3954 / 3955 |
| Regulator | `REGULATOR_AXP20X` | y | 4080 |
| PMIC 其它 | `INPUT_AXP20X_PEK`（y）/ `AXP20X_ADC`（m）/ `AXP20X_POWER`（m） | — | 3098 / 6678 / 3619 |
| 温度 | `THERMAL`+`SUN8I_THERMAL`+`CPU_FREQ_THERMAL` | y | 3866 / 3885 / 3881 |
| 看门狗 / RTC | `SUNXI_WATCHDOG` / `RTC_DRV_SUN6I` | y / y | 3913 / 6179 |
| IR | `IR_SUNXI`（+`RC_CORE=m`） | **m** | 4184（4155） |
| 其它 | `GPIO_SYSFS`(y) / `LEDS_GPIO`(m) / `KEYBOARD_SUN4I_LRADC`(y) / `SUN4I_GPADC`(m) | — | 3470 / 5990 / 2922 / 6706 |

**无线（详见 §7）**

| 项 | 符号 | 值 | 行 |
|---|---|---|---|
| uwe5622 BSP | `AW_WIFI_DEVICE_UWE5622` + `AW_BIND_VERIFY` + `SPARD_WLAN_SUPPORT` | y+y+y | 2843 / 2844 / 2834 |
| uwe5622 WiFi/BT | `WLAN_UWE5622` / `SPRDWL_NG` / `TTY_OVERY_SDIO` | m / m / m | 2848 / 2849 / 2851 |
| 框架 | `CFG80211` / `MAC80211` / `RFKILL` | m | 1754 / 1767 / 1778 |
| 蓝牙栈 | `BT` / `BT_HCIUART` / `BT_HCIUART_SERDEV` | m / m / y | 1683 / 1713 / 1714 |

### 5.2 三分法结论：内置 / 模块 / 缺失

**内置（=y，启动即可用）**：SoC 基础设施全套、SD/SDIO/eMMC 控制器、SPI(含 NOR)、I2C、
8250_dw 串口、增强 PWM、**整套 DRM 显示 + HDMI + HDMI 音频**、MUSB OTG、EHCI/OHCI、
AXP313A（MFD+regulator+PEK）、温度/看门狗/RTC、SID/DMA/IOMMU/MBUS、crypto-CE、
**厂商音频 codec(`sunxi/`) + AHUB 声卡(`sunxi_v2/`)**、**uwe5622 BSP 驱动本体**
（=y 但 Makefile 强制编成模块，见 §7.2）、`SUNXI_GMAC`（不匹配本板）、`SUNXI_SYS_INFO`、
`SUNXI_NMI_INTC`、`SUN6I_R_INTC`、**`libphy` 里硬编码的 `sunxi-ephy.o`**（见 §5.6）。

**模块（=m，需加载）**：`IR_SUNXI`、`RC_CORE`、`DRM_PANFROST`、`DRM_LIMA`、
`VIDEO_SUNXI_CEDRUS`、`DWMAC_SUN8I`、`MOTORCOMM_PHY`、`SPRDWL_NG`、`TTY_OVERY_SDIO`、
`CFG80211`/`MAC80211`/`RFKILL`、`BT`/`BT_HCIUART`、`USB_CONFIGFS`、`SUNXI_ADDR_MGT`、
`LEDS_GPIO`、`AXP20X_ADC`/`AXP20X_POWER`、`I2C_GPIO`、`PWM_SUN4I`。

**缺失 / 明确关闭（对 Zero3 有意义的部分）**：

| 缺的东西 | 证据 | 影响 |
|---|---|---|
| GPU（默认） | 板级 `sun50i-h618-orangepi-zero3.dts:120-123` `status="disabled"`；dtsi:190 也是 disabled | 默认无 `/dev/dri/renderD128`，需 `overlays=gpu` |
| HDMI CEC | 配置里无 `DRM_SUN8I_DW_HDMI_CEC` 条目（`CEC_CORE=y` 在 4190） | 遥控器 CEC 不可用 |
| 硬件视频编码 | 只有 `VIDEO_SUNXI_CEDRUS=m`(6324)，无编码器符号 | 不能硬件编码 |
| G2D / DI / 厂商 DISP2 | 6.1 配置无 `SUNXI_G2D`/`SUNXI_DI`/`DISP2_SUNXI` | 无 2D 加速、无硬件去隔行 |
| SPDIF / DMIC | `SND_SUN4I_SPDIF`(5186)/`SND_SUN50I_DMIC`(5187) not set | 板级也没引出 |
| Mali blob 驱动 | 5.4 的 `SUNXI_GPU_TYPE` 在 6.1 不存在 | 厂商 GL 库（libmali）在 6.1 上无内核侧配套，只能用 Panfrost+Mesa |

### 5.3 “符号名容易猜错”的几处（本审计的纠偏）

| 任务里可能猜的名字 | 实际符号 | 事实 |
|---|---|---|
| `CONFIG_SUN6I_IR` / `CONFIG_SUNXI_IR` | `CONFIG_IR_SUNXI`(4184, =m) | 驱动是 `drivers/media/rc/sunxi-cir.c`，匹配 `allwinner,sun6i-a31-ir` 回落 |
| `CONFIG_SND_SUN4I_CODEC` | 实际用 `CONFIG_SND_SUN50IW9_CODEC`(5181) | 树内 `sound/soc/sunxi/sun50iw9-codec.c`（Kconfig 标题 “Allwinner H616 Codec Support”） |
| `CONFIG_SND_SUN50I_CODEC_ANALOG` | 未设置(5184) | H616 的模拟部分并进了上面的 codec 驱动 |
| `CONFIG_MALI` / `CONFIG_PANFROST` | `CONFIG_DRM_PANFROST`(4948) | 无独立 `MALI` 符号；也没有 `SUNXI_IR`（前缀是 `IR_`） |
| `CONFIG_MMC_SUNXI_SLOT_EXTRA` | 不存在该符号 | 6.1 用设备树描述所有 slot |
| `CONFIG_SUNXI_GMAC` 当作以太网驱动 | 它是厂商驱动，**本板不绑定** | 真正生效的是 `DWMAC_SUN8I=m` |

### 5.4 与 DTS 的交叉验证（谁真的会被 probe）

光看 `=y/m` 不够，还要看 DTS 的 `status` 与 `compatible`（完整三列见 CSV）：

- 板级 DTS **打开**：`de`、`hdmi`、`emac0`+`mdio0`、`mmc0`、`mmc1`、`r_i2c`(PMIC)、`uart0`、
  `usbotg`、`usbphy`、`ehci1/2/3`、`ohci1/2/3`、`ir`、`spi0`(flash)、`codec`、四个 `ahub*`、`cpu0`
  （`dts:105-376`）
- 板级 DTS **关闭**：`gpu`(120-123)、`ehci0`/`ohci0`(248-250,264-266)、`i2c1..i2c4`(286-300)、
  `uart2`/`uart5`(302-312)、`spi1`(336-337)
- **dtsi 中无 `status` 的节点默认 okay**：`video-codec@1c0e000`(193-202)、`pwm`(289-299)、
  `rtc`(1299)、`ths`(1386)、`watchdog`(280-286)、`tcon_top`/`mixer0`/`hdmi_phy`。
  所以 **cedrus、PWM 控制器、watchdog/RTC/thermal 都会 probe**（前提是 .ko 已加载）。
- `codec` 在 dtsi 里是 `disabled`(691)，板级 DTS 才打开(351-355)。

### 5.5 `olddefconfig` 实测：官方配置是“自洽”的

用本仓库工具链（Arm GNU 11.2）对同一份官方 `.config` 跑 `olddefconfig`，再与官方文件 diff：

```bash
diff -u $C61 kernel/out/6.1/.config     # 只有 5 个 hunk，全是编译器元数据/GCC 插件：
# CC_VERSION_TEXT、GCC_VERSION、AS_VERSION、LD_VERSION、GCC_PLUGINS 与 GCC_PLUGIN_*/RANDSTRUCT_*
```

**没有任何驱动符号被改动**：官方 `.config` 是完整解析过的，不是半成品 defconfig，
所以“官方没开的，`olddefconfig` 也不会帮你打开”。

---

### 5.6 厂商私有符号（6.1 仍在使用，但**不是靠补丁**）

| 符号 | 值 | 行 | 源码位置 | 说明 |
|---|---|---|---|---|
| `SND_SUN50IW9_CODEC` | y | 5181 | `sound/soc/sunxi/sun50iw9-codec.c` | compatible `allwinner,sun50i-h616-codec`（驱动 :818）；**厂商合入**，上游 6.1 无同名符号（未与上游逐行比对） |
| `SND_SOC_SUNXI_AHUB` | y | 5197 | `sound/soc/sunxi_v2/snd_sunxi_ahub.c` | 厂商 AHUB 平台驱动（注意目录是 `sunxi_v2/`） |
| `SND_SOC_SUNXI_AHUB_DAM` | y | 5191 | `sunxi_v2/snd_sunxi_ahub_dam.c` | DAM 通路 |
| `SND_SOC_SUNXI_MACH` | y | 5190 | `sunxi_v2/snd_sunxi_mach.c`(+`_utils.c`) | 声卡 `ahubhdmi`/`ahubdam` |
| `SND_SOC_SUNXI_INTERNALCODEC` | **配置中无此条目** | — | `sunxi_v2/Kconfig:9` | 仅 `SND_SOC_SUNXI_AAUDIO` 打开时才 select；AAUDIO(5196) not set。别与 `sunxi_v2/Kconfig:12` 那个**同族的** `SND_SOC_SUNXI_SUN50IW9_CODEC` 混淆——两者都未启用，真正编进去的是 `sunxi/` 的 `SND_SUN50IW9_CODEC`(5181) |
| `PWM_SUNXI_ENHANCE` | y | 7177 | `drivers/pwm/pwm-sunxi-enhance.c` | 匹配 `allwinner,sun50i-h616-pwm`(:1145) |
| `SUNXI_SYS_INFO` / `SUNXI_ADDR_MGT` | y / m | 3226 / 2201 | 厂商杂项驱动 | 5.4 里后者也是 y |
| `SUN6I_R_INTC` / `SUNXI_NMI_INTC` | y | 7190 / 7191 | 厂商中断控制器 | 5.4 名为 `SUN8I_NMI`(5393) |
| `MFD_SUN4I_GPADC` / `KEYBOARD_SUN4I_LRADC` | y | 3942 / 2922 | GPADC / LRADC 按键 | 后者原为 mainline sun4i-lradc |

**更隐蔽的一处厂商残留**：`drivers/net/phy/sunxi-ephy.c` **连 CONFIG 符号都没有**，被
`drivers/net/phy/Makefile:5` 直接写进 `libphy-y := ... sunxi-ephy.o`（永远内建）。它注册的是
`ephy`(PHY ID 0x00441400) 与 `ac300`(0xc0000000)（`sunxi-ephy.c:248-250`、`:335-337`），
**与 Zero3 的 YT8531C 无关**；6.1 也没有 5.4 的 `SUNXI_EPHY`/`SUNXI_EXT_PHY` 符号。
Zero3 的网口链路是 `stmmac → dwmac-sun8i → YT8531C(motorcomm)`，别被文件名误导。

---

## 6. 5.4 BSP 与 6.1 的关键差异（摘要，详见附表）

完整表格、符号统计与复算命令见 `kernel/config-audit/config_diff_5.4_vs_6.1.md`。这里只留结论：

1. **驱动模型换代**：5.4 是 Allwinner BSP 栈（`DISP2_SUNXI`/`HDMI2_DISP2_SUNXI`/`USB_SUNXI_HCI`/
   `SERIAL_SUNXI`/`I2C_SUNXI`/`SPI_SUNXI`/`SUNXI_THERMAL`/`RTC_DRV_SUNXI`/`SUNXI_GPU_TYPE`），
   6.1 是主线栈（DRM/dwmac/musb/8250_dw/mv64xxx/sun6i-thermal/rtc-sun6i/panfrost）。
   **但音频 codec、AHUB 声卡（`sunxi_v2/`）、PWM 增强、uwe5622、sunxi-ephy 仍是厂商代码**。
2. **量级**：仅 5.4 有的符号 815 个、仅 6.1 有的 2399 个、同名符号 4457 个；
   **334 个从 `=y` 降为 `=m`**，只有 42 个反向。6.1 的 `=m` 总数 2909 vs 5.4 的 847。
3. **对使用的现实影响**：
   - 6.1 上**以太网是模块**（`DWMAC_SUN8I=m` + `MOTORCOMM_PHY=m`），5.4 是全内建；
   - 6.1 上**红外是模块**且 `RC_CORE=m`，`/dev/lirc0` 需加载后才出现；
   - 6.1 上**GPU 默认关**（DTS disabled）且驱动是 panfrost，5.4 是 mali blob；
   - 6.1 上**没有**视频编码、G2D、DI、CEC、SPDIF/DMIC；
   - 5.4 有 `SUNXI_RFKILL`/`SUNXI_EXT_PHY`/`SUNXI_EPHY`/`SUNXI_GPADC`/`SUNXI_SMC`/
     `SUNXI_QA_TEST`/`SUNXI_BOOTEVENT`，6.1 全部没有（`sunxi-ephy.c` 变成无符号的硬编码内建）；
   - PMIC 从 5.4 的 `AXP2101` 族（3448/3548/2764）换成 6.1 的 `AXP20X`+`AXP313A`（3954/4080/3098）。
4. **共同点**：`SUNXI_WATCHDOG`、`AW_WIFI_DEVICE_UWE5622`、`SPRDWL_NG`、`TTY_OVERY_SDIO`、
   `MOTORCOMM_PHY`、`KEYBOARD_SUN4I_LRADC`、`SUNXI_SYS_INFO`、`SUNXI_ADDR_MGT`、`DMA_SUN6I`
   两版都在（个别符号名不同，如 `SID` vs `NVMEM_SUNXI_SID`）。

---

## 7. 三方模块 uwe5622：从哪来、怎么进 rootfs、怎么绑定内核

### 7.1 三个模块名的来源

板级配置 `orangepizero3.conf:6-8` 对三条分支都写：

```text
MODULES_{LEGACY,CURRENT,NEXT}="uwe5622_bsp_sdio sprdwl_ng sprdbt_tty"   # 第 6-8 行
MODULES_BLACKLIST_{LEGACY,CURRENT}="bcmdhd"                             # 第 9-10 行，没有 NEXT
```

它们**不是**“要编译的外部模块”，而只是**开机要 modprobe 的模块名清单**：
`distributions.sh:98-103` 把 `${!modules}`（`MODULES_<BRANCH大写>`）逐行写进
rootfs 的 `/etc/modules`；`distributions.sh:106-111` 把 blacklist 写成
`/etc/modprobe.d/blacklist-<board>.conf`。因为 next 没有 `MODULES_BLACKLIST_NEXT`，
6.1 镜像里**不会生成 blacklist 文件**（`bcmdhd` 本来也不在 6.1 配置里）。

### 7.2 源码在哪：在**内核树内**，不在 SDK 的 packages 里

```bash
$ ls kernel/src/linux-6.1/drivers/net/wireless/uwe5622/
Kconfig  Makefile  tty-sdio/  unisocwcn/  unisocwifi/
$ grep -n "uwe5622" kernel/src/linux-6.1/drivers/net/wireless/Makefile
44:obj-$(CONFIG_SPARD_WLAN_SUPPORT) += uwe5622/
$ grep -n 'source "drivers/net/wireless/uwe5622/Kconfig"' kernel/src/linux-6.1/drivers/net/wireless/Kconfig
49:source "drivers/net/wireless/uwe5622/Kconfig"
```

三个 `.ko` 名字的来历（`unisocwcn/Makefile`）：

```text
79: ifeq ($(CONFIG_AW_WIFI_DEVICE_UWE5622),y)
80:   export CONFIG_WCN_SDIO = y
85:   BSP_CHIP_ID := uwe5622
86:   WCN_HW_TYPE := sdio
87: endif
89: MODULE_NAME := $(BSP_CHIP_ID)_bsp_$(WCN_HW_TYPE)     → uwe5622_bsp_sdio
348: ifdef CONFIG_WCN_BSP_DRIVER_BUILDIN
352:   obj-y := $(MODULE_NAME).o
353: else
358:   obj-m := $(MODULE_NAME).o                          ← 本配置走这条：模块
```

- `uwe5622_bsp_sdio.ko` ← `unisocwcn/`，由 `AW_WIFI_DEVICE_UWE5622=y` 选中，
  但 `WCN_BSP_DRIVER_BUILDIN` 未设置(2840 行 not set) → **编成模块**
- `sprdwl_ng.ko` ← `unisocwifi/Makefile:20` `MODULE_NAME := sprdwl_ng`，由 `SPRDWL_NG=m`(2849) 选中
- `sprdbt_tty.ko` ← `tty-sdio/Makefile:19` `obj-$(CONFIG_TTY_OVERY_SDIO) += sprdbt_tty.o`
  （符号名拼写就是 `OVERY`，不是 `OVERLAY`），由 `TTY_OVERY_SDIO=m`(2851) 选中

> 结论：**“三方模块”其实是厂商合进内核树的驱动**。SDK 的 `external/packages/` 里既没有
> uwe5622 源码包、也没有对应预编译 deb；`external/cache/sources/` 只有 `hcitools`
> （`hciattach_sprd.c`）这类配套工具。
>
> 它们的落盘路径是**内核 deb 的模块目录**：`make bindeb-pkg` 时
> `scripts/package/builddeb:268-269` 执行 `modules_install`，三个 `.ko` 进入
> `linux-image-next-sun50iw9` 的 `/lib/modules/6.1.31-sun50iw9/`——**没有单独的 WiFi/BT deb**。
> 旁证：本树编译中 `find drivers/net/wireless/uwe5622 -name '*.o' | wc -l` = 60，
> 说明它们确实随本次内核构建一起生成。

### 7.3 固件：编进 `.ko`，不依赖 `/lib/firmware`

```text
unisocwcn/fw/wcnmodem.bin.hex   9,009,791 字节（version.txt: Marlin3E_Integration_W20.18.4）
unisocwcn/fw/firmware_hex.h:4   #define firmware_hexcode "wcnmodem.bin.hex"
unisocwcn/fw/firmware_hex.h:6-8 static unsigned char firmware_hex_buf[] = { #include firmware_hexcode };
unisocwcn/platform/wcn_boot.c:55 #include "../fw/firmware_hex.h"
```

即 `wcnmodem.bin.hex` 被当作 C 数组**静态编进 `uwe5622_bsp_sdio.ko`**（驱动注释还提到另一条
“amlogic 从 /fw/wcnmodem.bin.hex 下载”的路径；Allwinner 分支走内置数组），所以**换内核时
固件与驱动永远同步**。

### 7.4 与内核版本的绑定关系

| 绑定点 | 机制 | 后果 |
|---|---|---|
| 编译期 | 三个 `.ko` 与内核同一次 `make modules` 产出，`vermagic` 一致 | 换发行版内核（6.6/6.12）就没有这三个 `.ko`，WiFi/BT 全废 |
| 配置期 | `AW_WIFI_DEVICE_UWE5622`/`SPRDWL_NG`/`TTY_OVERY_SDIO` 必须同一份 `.config` 同时打开 | 只开 BSP 不开 `SPRDWL_NG` → 有 SDIO 通道、无 `wlan0` |
| 运行期 | `/etc/modules` 按 `uwe5622_bsp_sdio`→`sprdwl_ng`→`sprdbt_tty` 加载 | 缺一个/顺序错 → WiFi 或蓝牙 tty 起不来 |
| 设备树 | `mmc1`(SDIO) + `wifi_pwrseq`(PG18) + `reg_vcc33_wifi`/`reg_vcc_wifi_io` | DTS 改错 → 枚举不到芯片 |
| 版本一致性 | 5.4/6.1 同名符号同一套源码（5.4:2502/2507/2509） | 两版行为接近；但 6.1 的 `CFG80211/MAC80211` 是模块 |

> 如果 SDK 里只有 deb 没有源码——**本 SDK 属于“有源码、没 deb”**：
> 源码在内核树内，`external/cache/debs/` 下只有 `h618/linux-u-boot-*` 两个 u-boot deb，
> 没有任何 uwe5622 或内核 deb（`ls external/cache/debs/h618/` 可证）。

---

## 8. DTS / overlay

### 8.1 板级 DTS 的关键节点（`hardware/dts-ref/` 与 `kernel/src/linux-6.1` 逐字节一致）

```bash
diff -q hardware/dts-ref/sun50i-h618-orangepi-zero3.dts \
        kernel/src/linux-6.1/arch/arm64/boot/dts/allwinner/sun50i-h618-orangepi-zero3.dts
# 无输出 = 相同；sun50i-h616.dtsi 亦相同
```

| 节点 | 关键属性（行号） | 结论 |
|---|---|---|
| `de` / `hdmi` | 打开（105-118），`hdmi_out` 接 `hdmi-connector` type=“d” | HDMI 输出走 DRM |
| `gpu` | `mali-supply=&reg_dcdc1`、**`status="disabled"`**(120-123) | 默认无 GPU，需 overlay |
| `emac0` | `phy-mode="rgmii"`、`ext_rgmii_pins`、`rx-delay-ps=1800`/`tx-delay-ps=700`(125-133) | 千兆网，delay 值会被 boot 脚本再覆盖（§8.3） |
| `mdio0/ext_rgmii_phy` | `reg=<1>`、`motorcomm,clk-out-frequency-hz=<125000000>`(135-143) | YT8531C 由 `MOTORCOMM_PHY` 驱动 |
| `mmc0` | `cd-gpios=<&pio 5 6>`=PF6、`bus-width=4`、`max-frequency=50MHz`(145-151) | TF 卡（无 eMMC） |
| `mmc1` | `non-removable`、`mmc-ddr-1_8v`、`mmc-pwrseq=&wifi_pwrseq`(153-161) | WiFi SDIO |
| `r_i2c` + `axp313a@36` | `compatible="x-powers,axp313a"`、5 路 regulator（163-219） | PMIC 在 **I2C** 上，不是 RSB |
| `uart0` | `pinctrl-0=<&uart0_ph_pins>`(221-225) | 调试串口 ttyS0（PH 组） |
| `usbotg` / `ehci1/2/3`+`ohci1/2/3` | `dr_mode="peripheral"`(227-241)；Host 口 okay(252-278)，`ehci0/ohci0` disabled | USB-C 只做 device，3 个 USB-A 做 Host |
| `ir` / `spi0` | `ir_rx_pin`、okay(280-284)；spi0 okay + `flash@0` `jedec,spi-nor`(314-334)，`spidev@0` disabled | 红外接收（PH10）+ SPI NOR 启动介质 |
| `spi1` | **disabled**(336-349)，仅有 `spidev@1` | 需 overlay 才可用 |
| `codec` / `ahub*` | `audio-routing="Line Out","LINEOUT"`、四个 ahub 节点 okay(351-371) | 3.5mm 模拟音频 + HDMI 音频 |
| `cpu0` | `cpu-supply=<&reg_dcdc2>`(373-376) | DVFS 由 AXP313A dcdc2 供电 |

### 8.2 overlay：内核树里自带，不是 SDK 的 `packages/bsp/overlays_arm64`

**易混淆点**：`external/packages/bsp/overlays_arm64/` 里是 `usr/bin/*` 之类的 **rootfs 用户态
文件**（`install_bt_panel.sh`、`tinymix` 等），由 `sun50iw9.conf:81` 的
`rsync -a --chown=root:root "${EXTER}"/packages/bsp/overlays_arm64/* ${SDCARD}/`
拷进根文件系统——它**不是设备树 overlay**。

真正的 DT overlay 在**内核树**：

```bash
ls kernel/src/linux-6.1/arch/arm64/boot/dts/allwinner/overlay/*.dts   # 28 个：-ir -gpu
# -ph-{uart2,uart5,i2c1..4,pwm12,pwm34} / -pi-{i2c0..2,pwm1..4,uart2..4}
# -spi0-spidev / -spi1-cs{0,1,0-cs1}-spidev / -usb0-host / -disable-{leds,uart0}
```
`overlay/Makefile:2-33`：`dtbo-$(CONFIG_ARCH_SUNXI) += ...` + `scr-$(CONFIG_ARCH_SUNXI) +=
sun50i-h616-fixup.scr`，由 `dtbs` 一并编出（`allwinner/Makefile:6` 把 `overlay` 加入 `subdir-y`）；
`hardware/dts-ref/overlay/` 的 7 个文件与内核树同名文件 **完全相同**（`cmp` 全 SAME）。

典型用法（`sun50i-h616-gpu.dts` 全文只有 11 行，就是给 `&gpu` 写 `status="okay"`）：

```bash
# /boot/orangepiEnv.txt
overlay_prefix=sun50i-h616
overlays=gpu ir spi1-cs1-spidev
```

`boot-sun50iw9-next.cmd:47-52` 会按 `overlays=` 逐个加载
`dtb/allwinner/overlay/${overlay_prefix}-${overlay_file}.dtbo` 并 `fdt apply`；
失败则回滚原 DTB（59-62 行）。

### 8.3 与 orangepi-config 的关系

`orangepi-config` 是单独编的 deb（`compilation.sh:795-823`，源码在
`external/cache/sources/orangepi-config/`），它的 overlay 开关逻辑：

```bash
# debian-config-functions:58-64（目录选择）  debian-config-jobs:1238-1256（列目录 + 改 env）
58: OVERLAYDIR="/boot/dtb/overlay";
64: [[ "$LINUXFAMILY" == "sun50iw9" && "$BRANCH" == "next" ]] && OVERLAYDIR="/boot/dtb/allwinner/overlay";
1238: ls -1 ${OVERLAYDIR}/${overlay_prefix}*.dtbo | sed 's/'${overlay_prefix}'-//g' | sed 's/.dtbo//g'
1254: sed -i "s/^overlays=.*/overlays=$newoverlays/" /boot/orangepiEnv.txt
```

即：orangepi-config 只是**列目录 + 改 `orangepiEnv.txt`**；overlay 本体由 `linux-dtb-*` 安装
（`dtbs_install` 会把 `dtbo-y`/`scr-y` 一起装上，`scripts/Makefile.dtbinst:23-24,34-38`），
`/boot/dtb` → `dtb-<version>` 的软链由 dtb 包 postinst 建立（`scripts/package/builddeb:72-79`），
所以板上路径就是 `/boot/dtb/allwinner/overlay/`。`/boot/orangepiEnv.txt` 的模板是
`external/config/bootenv/sun50iw9-default.txt`（`verbosity/bootlogo/console/disp_mode/
fb0_width/fb0_height/debug_uart`），overlay 相关键由 `distributions.sh:241-245` 追加
（`overlay_prefix=`、`overlays=`）。本板 `DEFAULT_OVERLAYS` 未设置 → 默认不加载任何 overlay。

另外 `boot-sun50iw9-next.cmd:74-82` 有一段**按 PHY 型号覆盖 delay** 的逻辑：

```text
ethernet_phy=yt8531c → rx-delay-ps=0, tx-delay-ps=600
ethernet_phy=rtl8211f → rx-delay-ps=3100, tx-delay-ps=700
```

它覆盖的正是 DTS 里 `emac0` 的 1800/700，所以**以太网稳定性问题先查 `orangepiEnv.txt` 里的
`ethernet_phy=`，再查 DTS**。

---

## 9. 在 SDK 之外独立复现内核编译

### 9.1 与 `scripts/build_kernel.sh` 对齐的最小命令序列

```bash
./scripts/setup_toolchain.sh && source scripts/env.sh   # Arm GNU 11.2 + CROSS_COMPILE
SRC=$PWD/kernel/src/linux-6.1; OUT=$PWD/kernel/out/6.1
CFG=$PWD/vendor/orangepi-build/external/config/kernel/linux-6.1-sun50iw9-next.config

# 1) 源码（首次，与 SDK 的 KERNELSOURCE/KERNELBRANCH 一致）
git clone --depth 1 -b orange-pi-6.1-sun50iw9 https://github.com/orangepi-xunlong/linux-orangepi.git "$SRC"
# 2) 配置（官方完整 .config）+ 3) 编译 + 4) 取产物
cd "$SRC" && cp "$CFG" .config
make -s ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- olddefconfig && cp .config "$OUT/.config"
make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- \
     LOCALVERSION=-sun50iw9 Image modules dtbs
cp arch/arm64/boot/Image System.map "$OUT/"
cp arch/arm64/boot/dts/allwinner/sun50i-h618-orangepi-zero3.dtb "$OUT/"
make -s ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- \
     INSTALL_MOD_PATH="$OUT/modules" LOCALVERSION=-sun50iw9 modules_install
```

`scripts/build_kernel.sh` 就是把上面 2)–4) 固化下来（第 88-114 行），默认 `IMAGE=Image`（第 25 行）、
`LOCALVERSION=-sun50iw9`（第 100-101 行）。

### 9.2 与 SDK 的逐项差异

| 项 | SDK (`compile_kernel`) | `scripts/build_kernel.sh` | 影响 |
|---|---|---|---|
| 镜像类型 | `Image`（arm64.conf:14） | 默认 `Image`，可用 `--image zImage` 覆盖 | **脚本第 13 行注释“官方 SDK 用 zImage”是错的**；默认值才对。zImage 在 arm64 上不是标准产物，指定后会失败（未实测，未确认） |
| 配置来源 | `external/config/kernel/<LINUXCONFIG>.config`（443 行） | 同一个文件（第 57 行） | 一致 |
| 工具链 | `find_toolchain()` 按表达式选，可能选到 9.2（§2.3） | 固定 11.2 | 官方发布版日志显示 11.x，故实际一致；理论上存在 9.2 的分支（未确认） |
| 并行度 | `-j$((CPUS + CPUS/2))`（main.sh:398） | `-j$(nproc)` | 本机 8 核：SDK 12 线程 vs 脚本 8 线程 |
| ccache | 默认启用（main.sh:121-133） | **不用** | 二次编译速度差异明显 |
| 打包/版本号 | `make bindeb-pkg KDEB_PKGVERSION=1.0.6 ...`（537-550），deb 版本 `1.0.6` | 不打包，拷文件 + `INSTALL_MOD_PATH=kernel/out/6.1/modules` | 脚本产物可直接 scp 替换，不能 `dpkg -i`；路径不同但内容等价 |
| 补丁 / overlay | `advanced_patch`（实测空转，§4）；`dtbs` 一并编 overlay | 无补丁；同样 `dtbs` | 等价；u-boot/ATF 需另编 |

### 9.3 想“只换内核、不刷整机”的做法

1. 编出 `Image`、`sun50i-h618-orangepi-zero3.dtb`、`modules/`；`/boot` 是 FAT，
   把 `Image` 拷到 `/boot/Image`，dtb 放 `/boot/dtb/allwinner/`（overlay 在 `dtb/allwinner/overlay/`）；
2. 模块：`modules/lib/modules/6.1.31-sun50iw9/` → 板子 `/lib/modules/`，`depmod -a 6.1.31-sun50iw9`；
3. **保留旧内核**并确认 u-boot `boot.cmd` 的 `Image` 路径不变，否则变砖只能重刷。

---

## 10. 未确认项与风险

| # | 项 | 为什么未确认 | 建议验证方式 |
|---|---|---|---|
| 1 | 官方 next 实际选中的 GCC | `find_toolchain` 的“最接近 8.0”会选 9.2；但官方配置头写的是 `aarch64-linux-gnu-gcc 11.4`。**推测官方在 arm64 主机上原生编译**（`arm64.conf:26-29` 此时 `KERNEL_COMPILER=aarch64-linux-gnu-`，`compilation.sh:421` 走原生分支、不调 `find_toolchain`） | 在 amd64 干净容器跑 `build.sh BUILD_OPT=kernel` 看日志 `Compiler version`；再在 arm64 主机复跑对比 |
| 2 | 5.4 内核源码实现 | 本工作区未克隆 `linux-5.4` | `git clone -b orange-pi-5.4-sun50iw9` 后比对 `sun50iw9-codec`/`disp2`/`gmac` 是否同源 |
| 3 | 5.4 DTS 的 `emac0` compatible | 同上，未读到 5.4 dts | 克隆后看是否用 `allwinner,sunxi-gmac`（若是，则 5.4 走厂商 gmac，6.1 走 dwmac-sun8i 的差异成立） |
| 4 | `headers-debian-byteshift.patch` 在 6.1 流程是否仍被使用 | 只在 `compilation.sh:456` 复制到 `/tmp`，未见到使用点 | 全仓 grep 该文件名/`/tmp` 下的 patch |
| 5 | zImage 在 arm64 是否可行 / `orangepiEnv.txt` 的 `disp_mode`/`fb0_*` 是否被主线 DRM 读取 | 未实测；这些键更像厂商 DISP2 遗留（`sun50iw9-default.txt`），6.1 用 DRM 后未必生效 | `make ARCH=arm64 zImage` 试一次；上板改 `disp_mode` 看 `/sys/class/drm` 是否变化 |
| 6 | `SUNXI_GMAC=y` 是否在某些 overlay/其它板 DTS 下被用到 | 只验证了 Zero3 的 DTS compatible | 检查同 family 其它板 DTS 的 `emac0` compatible |

### 风险提示（三个坑）

1. **`=y` ≠ “这块板能用”**：`SUNXI_GMAC=y`、`USB_XHCI_HCD=y`、`DRM_SUN6I_DSI=y` 在本板都没有可用
   硬件/节点；判据是“配置 + DTS status + compatible 匹配”三件套。
2. **`=m` 才是 6.1 的主要形态**：以太网、红外、GPU、解码、WiFi/蓝牙栈都是模块，换 rootfs 时
   最容易“硬件在、驱动不在”。
3. **`external/patch/kernel` 不存在**：改驱动直接改源码树；加补丁须自建目录且别用 `series.conf`。

---

## 附录 A：本文主要证据命令（可直接复算）

```bash
cd /home/toby/Desktop/OrangePiZero3; B=vendor/orangepi-build
C61=$B/external/config/kernel/linux-6.1-sun50iw9-next.config
C54=$B/external/config/kernel/linux-sun50iw9-current.config

cat -n $B/external/config/boards/orangepizero3.conf; cat -n $B/external/config/sources/families/sun50iw9.conf
sed -n '124,160p' $B/scripts/configuration.sh                # IMAGE_TYPE 覆盖顺序
sed -n '372,593p' $B/scripts/compilation.sh                  # compile_kernel 全文
sed -n '868,920p' $B/scripts/compilation.sh                  # grab_version + find_toolchain
sed -n '941,1023p' $B/scripts/compilation.sh                 # advanced_patch / process_patch_file
sed -n '1564,1626p' $B/scripts/general.sh                    # toolchains 列表与下载
sed -n '84,99p' $B/external/config/bootscripts/boot-sun50iw9-next.cmd   # load Image + 网口 delay
find $B/external/patch -maxdepth 2                           # 只有 atf/misc
grep -rn "apply_patch_series" $B/scripts/                    # 只有调用、没有定义

grep -nE "PANFROST|LIMA" $C61
grep -nE "DWMAC_SUN8I|SUNXI_GMAC|MOTORCOMM_PHY|IR_SUNXI|RC_CORE" $C61 $C54
grep -nE "SND_SUN50IW9_CODEC|SND_SOC_SUNXI_AHUB|AW_WIFI_DEVICE_UWE5622|SPRDWL_NG|TTY_OVERY_SDIO" $C61 $C54

sed -n '79,89p;348,359p' kernel/src/linux-6.1/drivers/net/wireless/uwe5622/unisocwcn/Makefile
cat kernel/src/linux-6.1/drivers/net/wireless/uwe5622/unisocwcn/fw/firmware_hex.h
diff -q hardware/dts-ref/sun50i-h618-orangepi-zero3.dts \
     kernel/src/linux-6.1/arch/arm64/boot/dts/allwinner/sun50i-h618-orangepi-zero3.dts
diff -u $C61 kernel/out/6.1/.config                          # olddefconfig 实测差异（5 个 hunk）
```

## 附录 B：本文与其它文档的分工

| 文档 | 负责什么 |
|---|---|
| `docs/04_orangepi-build_SDK.md` | 用户视角：build.sh 菜单、换源、产物 deb、刷机 |
| `docs/07`（本文） | 机制视角：配置加载、compile_kernel 拆解、补丁空转、6.1/5.4 配置审计、uwe5622 构建形态、overlay、独立复现 |
| `kernel/config-audit/*` | 机器可核对的符号表与差异表 |
| `docs/01`~`03` | 硬件/引脚/复用（本文只引 DTS 节点与状态，不重复引脚表） |
