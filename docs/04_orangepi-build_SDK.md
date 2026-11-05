# orangepi-build Linux SDK 编译指南

> 页码规则：`（手册 P`印刷页码` / PDF 第`物理页码`页）`，印刷页码 = PDF 物理页 − 9。
> 全部内容来自 `docs/source/manual.pdf` 第 4 章（P243–P261）+ 相关章节，未写的明确标“手册未说明”。
> 本文件只讲**怎么编**；硬件能力见 `docs/01`，引脚见 `docs/03`。

## 结论速览

| 项目 | 结论 | 出处 |
|---|---|---|
| 编译机 | **只支持 Ubuntu 22.04 X64**；禁止 WSL、禁止在板子上编 | P243 / PDF 252 |
| SDK 仓库 | `orangepi-xunlong/orangepi-build`，H618 必须用 **`next` 分支** | P245 / PDF 254 |
| 分支语义 | `current` = u-boot v2018.05 + Linux5.4；`next` = u-boot v2024.01 + Linux6.1 | P246 / PDF 255 |
| 交叉工具链 | 首次运行自动下载到 `toolchains/`，境内镜像走清华 | P246–P247 / PDF 255–256 |
| 内核工具链 | 5.4 与 6.1 都用 `gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu` | P247–P248 / PDF 256–257 |
| u-boot 工具链 | v2018.05 → `gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabi`；v2024.01 → `gcc-arm-11.2-...aarch64-none-linux-gnu` | P248 / PDF 257 |
| 四步产物 | `output/debs/u-boot/`、`output/debs/linux-*.deb`、`external/cache/rootfs/*.tar.lz4`、`output/images/.../*.img` | P250–P261 / PDF 259–270 |
| 无交互编译 | `sudo ./build.sh BOARD=orangepizero3 BRANCH=next BUILD_OPT=<目标> ...`（目标 = u-boot / kernel / image） | P250、P254、P261 / PDF 259、263、270 |
| 改源码必做 | 先在 `userpatches/config-default.conf` 设 `IGNORE_UPDATES="yes"`，否则改动被同步覆盖 | P250、P254 / PDF 259、263 |
| 26pin 功能 | 默认全关；Debian/Ubuntu 用 `orangepi-config` 开 dtbo，Arch 用 `extlinux.conf` 的 `FDTOVERLAYS` | P118、P268 / PDF 127、277 |

---

## 1. 编译环境要求

### 1.1 硬性要求

- **只支持 Ubuntu 22.04 的 X64 电脑**（手册 P243 / PDF 第252页）。

```bash
test@test:~$ lsb_release -a
Distributor ID: Ubuntu
Description:    Ubuntu 22.04 LTS
Release:        22.04
Codename:       jammy
```

- **不要在 WSL 里编译**（未测试，不保证）；**不要**在开发板自身的 Linux 里跑 orangepi-build。
- 没有 Ubuntu 可以用 VirtualBox / VMware 装 22.04 虚拟机。
- 镜像地址：`https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04/ubuntu-22.04-desktop-amd64.iso`

### 1.2 必须先换清华源

```bash
sudo mv /etc/apt/sources.list /etc/apt/sources.list.bak    # 手册原文漏了斜杠，见下方“坑”
sudo vim /etc/apt/sources.list
```

```ini
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy-security main restricted universe multiverse
# deb-src 行手册默认注释（提高 apt update 速度），需要源码包时再放开
```

```bash
sudo apt-get update          # 必须无报错
```

（手册 P243–P244 / PDF 第252–253页）

> ⚠️ **手册 P244 的命令有错**：印的是 `sudo mv /etc/apt/sources.list cat /etc/apt/sources.list.bak`（多了 `cat`，且缺 `/`）。正确写法是上面的 `sudo mv /etc/apt/sources.list /etc/apt/sources.list.bak`。

### 1.3 网络

内核与 u-boot 源码都在 GitHub，**编译时电脑必须能正常访问 GitHub**（手册 P244 / PDF 第253页）。

> 手册未给出 orangepi-build 的磁盘/内存最低要求（未说明）。实际预留 ≥ 60GB 空闲较稳妥（本仓库经验值，非手册结论）。

---

## 2. 获取源码

### 2.1 克隆 orangepi-build

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/orangepi-xunlong/orangepi-build.git -b next
```

- **H618 系列必须用 `next` 分支**（手册 P245 / PDF 第254页）。
- 正常 clone 不需要 GitHub 账号密码；若提示要密码，先检查 URL 是否抄错。

### 2.2 版本矩阵（重要，别和 git 分支搞混）

| 分支 | u-boot 版本 | linux 内核版本 |
|---|---|---|
| `current` | u-boot v2018.05 | linux5.4 |
| `next` | u-boot v2024.01 | linux6.1 |

（手册 P246 / PDF 第255页）

> 这里的 current/next 指**内核源码线**，与 `orangepi-build` 仓库自己的 git 分支不是一回事。全志 5.4 BSP = current，6.1 LTS = next。

### 2.3 源码仓库与分支（orangepi-build 里不含内核/u-boot 源码）

| 组件 | 仓库与分支 |
|---|---|
| Linux5.4 | `https://github.com/orangepi-xunlong/linux-orangepi/tree/orange-pi-5.4-sun50iw9` |
| Linux6.1 | `https://github.com/orangepi-xunlong/linux-orangepi/tree/orange-pi-6.1-sun50iw9` |
| u-boot v2018.05 | `https://github.com/orangepi-xunlong/u-boot-orangepi/tree/v2018.05-h618` |
| u-boot v2024.01 | `https://github.com/orangepi-xunlong/u-boot-orangepi/tree/v2024.01` |

（手册 P248 / PDF 第257页）

> 坑：从 GitHub 下的 orangepi-build 里**看不到** u-boot、kernel、toolchains，这是正常的——`build.sh` 会自动去上面这些地址拉。

### 2.4 交叉编译工具链

- 首次运行 `build.sh` 会自动下载到 `toolchains/`；之后每次运行只检查存在性，不缺就不重复下载（P246 / PDF 第255页）。
- 境内镜像：`https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/_toolchain/`（P247 / PDF 第256页）

下载后 `toolchains/` 里的内容（12 个）：

```text
gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu
gcc-arm-11.2-2022.02-x86_64-arm-none-linux-gnueabihf
gcc-arm-9.2-2019.12-x86_64-aarch64-none-linux-gnu
gcc-arm-9.2-2019.12-x86_64-arm-none-linux-gnueabihf
gcc-linaro-4.9.4-2017.01-x86_64_aarch64-linux-gnu
gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabi
gcc-linaro-5.5.0-2017.10-x86_64_arm-linux-gnueabihf
gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu
gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabi
gcc-linaro-aarch64-none-elf-4.8-2013.11_linux
gcc-linaro-arm-linux-gnueabihf-4.8-2014.04_linux
gcc-linaro-arm-none-eabi-4.8-2014.04_linux
```

**H618 实际使用的工具链**（手册 P247–P248 / PDF 第256–257页）：

| 目标 | 分支 | 工具链目录 |
|---|---|---|
| Linux 内核 | linux5.4 | `gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu` |
| Linux 内核 | linux6.1 | `gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu` |
| u-boot | v2018.05 | `gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabi` |
| u-boot | v2024.01 | `gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu` |

### 2.5 目录结构

**刚 clone 下来**（P246 / PDF 第255页）：

```text
orangepi-build/
├── build.sh          # 编译入口脚本
├── external/         # 配置文件、特定脚本、部分程序源码
├── LICENSE           # GPL 2
├── README.md
└── scripts/          # 编译镜像的通用脚本
```

**成功编译过一次镜像之后**（P248–P249 / PDF 第257–258页）：

```text
orangepi-build/
├── build.sh
├── external/         # 含 external/cache/rootfs（rootfs 缓存）、external/config/kernel/*.config
├── kernel/           # linux 内核源码
├── LICENSE
├── output/           # u-boot/linux 的 deb 包、编译日志、生成的镜像
├── README.md
├── scripts/
├── toolchains/       # 交叉编译工具链
├── u-boot/           # u-boot 源码
└── userpatches/      # 编译脚本用到的配置文件（config-default.conf 在这里）
```

---

## 3. build.sh 总览

### 3.1 四个功能入口（菜单名照抄）

```bash
sudo ./build.sh
```

| 菜单项 | 作用 | 章节 |
|---|---|---|
| `U-boot package` | 只编 u-boot，出 deb | §4 |
| `Kernel package` | 只编内核，出 dtb/headers/image 三个 deb | §5 |
| `Rootfs and all deb packages` | 只做 rootfs 缓存 + 全部 deb | §6 |
| `Full OS image for flashing` | 编完整可烧录镜像 | §7 |

每次交互结束，脚本都会打印 `Repeat Build Options`——那串就是下次可直接照抄的非交互命令（**最省事，务必记下来**）。

### 3.2 通用参数

| 参数 | 取值 | 说明 |
|---|---|---|
| `BOARD` | `orangepizero3` | 板型 |
| `BRANCH` | `current` / `next` | 内核线（5.4 / 6.1） |
| `BUILD_OPT` | `u-boot` / `kernel` / `image` | 编译目标（`rootfs` 手册未给示例，见待确认） |
| `KERNEL_CONFIGURE` | `yes` / `no` | 是否弹 `make menuconfig` |
| `RELEASE` | 如 `bullseye` | 发行版代号 |
| `BUILD_MINIMAL` | `yes` / `no` | 是否 Minimal 版 |
| `BUILD_DESKTOP` | `yes` / `no` | 是否桌面版 |

（来源：手册各节打印的 Repeat Build Options，P250 / P254 / P261）

### 3.3 两个全局配置文件

`userpatches/config-default.conf`：

```bash
test@test:~/orangepi-build$ vim userpatches/config-default.conf
IGNORE_UPDATES="yes"      # 改源码时必须打开，否则源码被 GitHub 同步覆盖
KERNEL_CONFIGURE=no       # 永久禁用 menuconfig 弹窗
```

（手册 P250、P253 / PDF 第259、262页）

---

## 4. 编译 u-boot

### 4.1 交互流程

```bash
test@test:~/orangepi-build$ sudo ./build.sh
# 1) 选 U-boot package
# 2) 选开发板型号（Orange Pi Zero 3）
# 3) 选分支：current（v2018.05）/ next（v2024.01）
```

（手册 P249 / PDF 第258页）

### 4.2 无交互等价命令

```bash
sudo ./build.sh BOARD=orangepizero3 BRANCH=next BUILD_OPT=u-boot
```

### 4.3 编译日志关键行

```text
[ o.k. ] Compiling u-boot [ v2024.01 ]
[ o.k. ] Compiler version [ aarch64-linux-gnu-gcc 11 ]
[ o.k. ] Target directory [ orangepi-build/output/debs/u-boot ]
[ o.k. ] File name [ linux-u-boot-next-orangepizero3_x.x.x_arm64.deb ]
[ o.k. ] Runtime [ 1 min ]
[ o.k. ] Repeat Build Options [ sudo ./build.sh BOARD=orangepizero3 BRANCH=next BUILD_OPT=u-boot ]
```

（手册 P250 / PDF 第259页）

### 4.4 产物

```text
output/debs/u-boot/linux-u-boot-next-orangepizero3_x.x.x_arm64.deb
```

### 4.5 改了 u-boot 源码怎么生效

1. 先完整编一次 u-boot（否则找不到源码）。
2. `userpatches/config-default.conf` 里设 `IGNORE_UPDATES="yes"`。
3. 编完把 deb 推到板子上装：

```bash
cd output/debs/u-boot
scp linux-u-boot-next-orangepizero3_x.x.x_arm64.deb root@192.168.1.xxx:/root

# 板子上
sudo dpkg -i linux-u-boot-next-orangepizero3_x.x.x_arm64.deb
sudo nand-sata-install
#   选 "5 Install/Update the bootloader on SD/eMMC" -> 回车 -> Warning 再回车
sudo reboot
```

（手册 P250–P251 / PDF 第259–260页）

---

## 5. 编译 Linux 内核

### 5.1 交互流程

```bash
sudo ./build.sh
# 1) 选 Kernel package
# 2) 是否显示内核配置界面：不用改配置选第一项；要改选第二项（进 menuconfig）
# 3) 选开发板型号
# 4) 选分支：current=linux5.4 / next=linux6.1
```

（手册 P252 / PDF 第261页）

### 5.2 无交互

```bash
sudo ./build.sh KERNEL_CONFIGURE=no                                  # 临时屏蔽 menuconfig
sudo ./build.sh BOARD=orangepizero3 BRANCH=next BUILD_OPT=kernel KERNEL_CONFIGURE=no
```

（手册 P253 / PDF 第262页）

### 5.3 日志关键行（next 分支示例）

```text
[ o.k. ] Compiling current kernel [ 6.1.31 ]
[ o.k. ] Compiler version [ aarch64-linux-gnu-gcc 11 ]
[ o.k. ] Using kernel config file [ orangepi-build/external/config/kernel/linux-6.1-sun50iw9-next.config ]
[ o.k. ] Target directory [ output/debs/ ]
[ o.k. ] File name [ linux-image-next-sun50iw9_x.x.x_arm64.deb ]
[ o.k. ] Runtime [ 10 min ]
```

（手册 P254 / PDF 第263页；注意日志里 “Compiling current kernel” 文案与实际 6.1 不一致，是脚本措辞，别被误导）

### 5.4 产物（三个 deb）

```text
output/debs/linux-dtb-next-sun50iw9_x.x.x_arm64.deb       # dtb 文件
output/debs/linux-headers-next-sun50iw9_x.x.x_arm64.deb   # 内核头文件
output/debs/linux-image-next-sun50iw9_x.x.x_arm64.deb     # 内核镜像 + 模块
```

（手册 P254 / PDF 第263页）

> 注意命名差异：u-boot deb 用 `orangepizero3`，内核 deb 用 `sun50iw9`（H618 属于 sun50iw9 平台）。

### 5.5 改了内核源码怎么生效

```bash
# 1) 同 u-boot：先完整编一次，再设 IGNORE_UPDATES="yes"

# 2) 推 deb 到板子
cd output/debs
scp linux-image-next-sun50iw9_x.x.x_arm64.deb root@192.168.1.xxx:/root

# 3) 板子上安装并重启
sudo dpkg -i linux-image-next-sun50iw9_x.x.x_arm64.deb
sudo reboot
```

（手册 P254–P255 / PDF 第263–264页）

### 5.6 板子上单独装内核头文件（编模块用）

```bash
ls /opt/linux-headers*                    # 镜像默认自带 deb
sudo dpkg -i /opt/linux-headers*.deb
ls /usr/src                              # linux-headers-x.x.x
```

⚠️ 手册明说：**Linux6.1 + Debian11 编译内核模块会报 GCC 错误**，要编模块请用 **Debian12 或 Ubuntu22.04**（P216 / PDF 第225页）。

---

## 6. 编译 rootfs

### 6.1 交互流程

```bash
sudo ./build.sh
# 1) 选 Rootfs and all deb packages
# 2) 选开发板型号
# 3) 选分支
# 4) 选 rootfs 类型（发行版）
# 5) 选镜像类型：Image with console interface (server) / Image with desktop environment
# 6) server 再选 Standard 或 Minimal（没特殊需求别选 Minimal）
# 7) desktop 只能选 XFCE
# 8) 额外软件包列表直接回车跳过
```

（手册 P255–P257 / PDF 第264–266页）

### 6.2 分支决定可选的发行版

| 分支 | 可选 rootfs |
|---|---|
| `current`（5.4） | debian11、ubuntu20.04、ubuntu22.04 |
| `next`（6.1） | debian11、debian12、ubuntu22.04、ubuntu24.04 |

（手册 P255 / PDF 第265页）

### 6.3 产物与缓存机制

```text
external/cache/rootfs/bullseye-xfce-arm64.5250ec7002de9e81a41de169f1f89721.tar.lz4
external/cache/rootfs/....tar.lz4.current
external/cache/rootfs/....tar.lz4.list          # rootfs 内所有 deb 包名
```

名字各段含义（P257 / PDF 第266页）：
`<发行版代号>-<xfce|cli>-<架构>.<deb包列表的MD5>.tar.lz4`

- **MD5 不变 = 不重编**：只要没改 rootfs 的软件包列表，编镜像时直接复用缓存，能省大量时间（P258 / PDF 第267页）。
- 想强制重做：删掉 `external/cache/rootfs/` 下对应文件。

> 手册未给出 rootfs 的 `Repeat Build Options`（只给了 u-boot / kernel / image 三处），因此 `BUILD_OPT=rootfs` 属**未确认**用法之一（见待确认清单）。

---

## 7. 编译完整镜像

### 7.1 交互流程

```bash
sudo ./build.sh
# 1) 选 Full OS image for flashing
# 2) 选开发板型号
# 3) 选分支
# 4) 选 rootfs 类型
# 5) 选 server / desktop
# 6) server -> Standard / Minimal；desktop -> XFCE
# 7) 额外软件包：直接回车跳过
```

（手册 P258–P260 / PDF 第267–269页）

> ⚠️ 手册内部不一致：§4.5（rootfs）说 next 分支可选 **debian11、debian12、ubuntu22.04、ubuntu24.04**（P255），
> §4.6（image）说 next 分支只有 **debian11、debian12、ubuntu22.04**（P259）。以实际菜单为准，差异见待确认清单。

### 7.2 脚本内部流程（15 步，便于排错定位）

a. 初始化编译环境、装编译依赖包
b. 下载 u-boot / linux 源码（已缓存则只更新）
c. 编译 u-boot → deb
d. 编译 linux → deb
e. 制作 linux firmware deb
f. 制作 `orangepi-config` 工具 deb
g. 制作板级支持 deb
h. desktop 镜像额外制作 desktop 相关 deb
i. 检查 rootfs 缓存，没有则重做
j. 把上面生成的 deb 装进 rootfs
k. 按板型/镜像类型做定制（预装软件、改系统配置）
l. 制作镜像文件并格式化分区（**默认 ext4**）
m. 把配置好的 rootfs 拷进分区
n. 更新 initramfs
o. 用 `dd` 把 u-boot bin 写入镜像

（手册 P260 / PDF 第269页）

### 7.3 产物与收尾

```text
output/images/orangepizero3_x.x.x_debian_bullseye_linux6.1.xx_xfce_desktop/
        orangepizero3_x.x.x_debian_bullseye_linux6.1.xx_xfce_desktop.img
[ o.k. ] Runtime [ 19 min ]
[ o.k. ] Repeat Build Options [ sudo ./build.sh BOARD=orangepizero3 BRANCH=next \
    BUILD_OPT=image RELEASE=bullseye BUILD_MINIMAL=no BUILD_DESKTOP=no KERNEL_CONFIGURE=yes ]
```

（手册 P261 / PDF 第270页）

**最短复现命令**：

```bash
sudo ./build.sh BOARD=orangepizero3 BRANCH=next BUILD_OPT=image \
    RELEASE=bullseye BUILD_MINIMAL=no BUILD_DESKTOP=no KERNEL_CONFIGURE=yes
```

编出来的 `.img` 直接用 balenaEtcher / Win32Diskimager 烧 TF 卡（见 `docs/01` §5）。

---

## 8. DT overlay 与 26pin 功能使能

> 前提结论：26pin 的 I2C/SPI/UART/PWM 在 dts 里**默认关闭**，必须显式打开叠加层（P268 / PDF 第277页）。

### 8.1 Debian / Ubuntu 官方镜像：用 orangepi-config

```bash
sudo orangepi-config
# System -> Hardware -> 方向键定位，空格勾选目标项 -> <Save> -> <Back> -> <Reboot>
```

勾选后要重启才生效。验证：

```bash
ls /dev/spidev1*       # 应出现 /dev/spidev1.1
ls /dev/i2c-3
ls /dev/ttyS5          # linux5.4 为 /dev/ttyAS5
```

（手册 P118–P126 / PDF 第127–135页）

### 8.2 OPi OS Arch：改 extlinux.conf

```bash
sudo vim /boot/extlinux/extlinux.conf
```

```text
LABEL Orange Pi
KERNEL /Image
FDT /dtbs/allwinner/sun50i-h616-orangepi-zero3.dtb
FDTOVERLAYS /dtbs/allwinner/overlay/sun50i-h616-ph-i2c3.dtbo
```

- 多个同时打开就空格分隔写在同一行：
  `FDTOVERLAYS /dtbs/allwinner/overlay/sun50i-h616-ph-i2c3.dtbo /dtbs/allwinner/overlay/sun50i-h616-ph-uart5.dtbo`
- dtbo 存放目录 `/boot/dtbs/allwinner/overlay/`，**不是该目录下所有 dtbo 都能用**。
- 改完 `sudo reboot` 生效。

（手册 P268–P269 / PDF 第277–278页）

### 8.3 可用的 dtbo 清单（H618 / Zero 3）

| 板载功能 | dtbo |
|---|---|
| 26pin - spi1 | `sun50i-h616-spi1-cs1-spidev.dtbo` |
| 26pin - i2c3 | `sun50i-h616-ph-i2c3.dtbo` |
| 26pin - uart5 | `sun50i-h616-ph-uart5.dtbo` |
| 26pin - pwm12 | `sun50i-h616-ph-pwm12.dtbo` |
| 26pin - pwm34 | `sun50i-h616-ph-pwm34.dtbo` |
| 禁用 uart0 调试串口 | `sun50i-h616-disable-uart0.dtbo` |
| 关闭 led 灯 | `sun50i-h616-disable-leds.dtbo` |
| type-c usb0 设为 host 模式 | `sun50i-h616-usb0-host.dtbo` |

（手册 P268 / PDF 第277页）

### 8.4 复用冲突（一定要先规划）

- `ph-pwm12` 与 26pin 的 **UART5 RX/TX** 复用 → 二者只能选一个。
- `ph-pwm34` 与**调试串口 UART0** 复用 → 必须同时开 `disable-uart0`，**调试串口从此不可用**。

（手册 P127 / PDF 第136页）

### 8.5 在 SDK 里给镜像预置 overlay

手册**未说明**如何在 orangepi-build 的板级配置里默认打包某个 dtbo（未确认）。当前可行路径是编完镜像后首次启动用 `orangepi-config` 打开，或改 `external/packages/...` 里的板级脚本（手册未写，需自行读 SDK 脚本）。

---

## 9. wiringOP / wiringOP-Python

### 9.1 wiringOP

- 官方 Linux 镜像**已预装** wiringOP，一般无需重编（P114 / PDF 第123页）。
- 预编译 deb 在 SDK 里：`orangepi-build/external/cache/debs/arm64/wiringpi_x.xx.deb`。

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/orangepi-xunlong/wiringOP.git -b next     # 必须带 -b next
cd wiringOP
sudo ./build clean
sudo ./build
gpio readall                      # 有表输出即安装成功
```

- GitHub 拉不动时，用镜像里自带的源码：`/usr/src/wiringOP`（P115 / PDF 第124页）。

### 9.2 wiringOP-Python（全在 root 下做）

```bash
sudo apt-get update
sudo apt-get -y install git swig python3-dev python3-setuptools
git clone --recursive https://github.com/orangepi-xunlong/wiringOP-Python -b next
cd wiringOP-Python
git submodule update --init --remote
python3 generate-bindings.py > bindings.i
sudo python3 setup.py install
python3 -c "import wiringpi; help(wiringpi)"       # 有帮助信息即成功
```

- 镜像自带源码：`/usr/src/wiringOP-Python`（P137 / PDF 第146页）。

### 9.3 GPIO 编号映射规则

| 编号体系 | 说明 | 出处 |
|---|---|---|
| 26pin 物理引脚 | 板上丝印 1–26 | P113 / PDF 122 |
| GPIO 序号（数字） | 如 PC9=73、PH5=229、PI16=272 | P113–P114 / PDF 122–123 |
| GPIO 名 | 如 `PC9`、`PH2`、`PH10` | 同上 |
| wPi 序号 | wiringOP 用的编号，命令里第三个参数就是它 | P116 / PDF 125 |
| 13pin 引脚 | 无扩展板时 10–13 可作 GPIO：PC1(65)、PI16(272)、PI6(262)、PH10(234, IR-RX) | P113 / PDF 122 |

已确证的数据点：

```text
26pin 7 号引脚 = PC9 = wPi 2           (P116 / PDF 125)
PWM1 = wPi 4, PWM2 = wPi 3,
PWM3 = wPi 21, PWM4 = wPi 22           (P131 / PDF 140)
gpio readall 1~26 对应 26pin；
  27→13pin 10, 29→13pin 11, 31→13pin 12, 33→13pin 13, 28/30/32/34 为空  (P115-116 / PDF 124-125)
新版 wiringOP 的 readall 新增 28、30 表示 PWM3/PWM4                  (P129 / PDF 138)
```

> ⚠️ 上述 “28/30 为空” 与 “28/30 是 PWM3/4” 是 wiringOP 版本差异，两处并存于手册。**完整可靠的 wPi↔引脚表请看 `docs/03` 并在板上跑 `gpio readall` 核对**（见待确认清单）。

硬件 PWM 前提：**v1.0.2 版镜像自带的 wiringOP 用不了硬件 PWM**，必须按 §9.1 用最新源码重编（P129 / PDF 第138页）。

---

## 10. Android 12 源码编译入口

前置：**Ubuntu 22.04 x86_64**，建议内存 ≥16GB、硬盘 ≥200GB，CPU 核越多越好（P335 / PDF 第344页）。

```bash
# 1) 装依赖
sudo apt-get update
sudo apt-get install -y git gnupg flex bison gperf build-essential zip curl zlib1g-dev \
  gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev libx11-dev \
  lib32z1-dev ccache libgl1-mesa-dev libxml2-utils xsltproc unzip u-boot-tools \
  python-is-python3 libssl-dev libncurses5 clang gawk

# 2) 源码是网盘分卷压缩包，先合并再解压
md5sum -c H618-Android12-Src.tar.gz.md5sum
cat H618-Android12-Src.tar.gza* > H618-Android12-Src.tar.gz
tar -xvf H618-Android12-Src.tar.gz

# 3) 编 u-boot + 内核（longan）
cd H618-Android12-Src/longan
./build.sh config
#   platform: 0.android   ic: 0.h618   board: 2.p2
#   flash: 0.default      kern_ver: 0.linux-5.4   arch: 1.arm64
./build.sh                # 成功打印 sun50iw9p1 compile Kernel successful / INFO: build lichee OK.

# 4) 编 Android 并打包
cd ..
source build/envsetup.sh
lunch apollo_p2-userdebug
make -j8
pack
```

产物：`longan/out/h618_android12_p2_uart0.img`（P337 / PDF 第346页）

- Android 12 TV 用 **linux5.4** 内核（P303 / PDF 第312页）。
- 镜像只能 Windows + PhoenixCard 4.2.8 烧写（P22 / PDF 第31页）。

---

## 11. OpenWRT 编译入口

```bash
# 1) 源码（main 分支）
sudo apt update
sudo apt install -y git
git clone https://github.com/orangepi-xunlong/openwrt.git -b main

# 2) 依赖包（手册称仅在 Ubuntu22.04 上验证过）
sudo apt update
sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison \
  build-essential bzip2 ccache cmake cpio curl device-tree-compiler fastjar flex gawk \
  gettext gcc-multilib g++-multilib git gperf haveged help2man intltool libc6-dev-i386 \
  libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev \
  libncurses5-dev libncursesw5-dev libreadline-dev libssl-dev libtool lrzsz mkisofs \
  msmtp nano ninja-build p7zip p7zip-full patch pkgconf python2.7 python3 \
  python3-pyelftools libpython3-dev qemu-utils rsync scons squashfs-tools subversion \
  swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev

# 3) 应用 OrangePi Zero 3 配置并编译
./scripts/feeds update -a
./scripts/feeds install -a
cp configs/orangepi-zero3-h618_defconfig .config
make defconfig
make V=s
```

产物：`bin/targets/sunxi/cortexa53/openwrt-sunxi-cortexa53-xunlong_orangepi-zero3-ext4-sdcard.img.gz`（P302 / PDF 第311页）

- 版本：OpenWrt SNAPSHOT / Linux 6.1.74（P270 / PDF 第279页）。
- 首次启动会跑 `resize-rootfs.sh` 自动扩容并重启，用 `df -h` 验证（P270 / PDF 第279页）。

> ⚠️ 手册 P301 的依赖列表里印着 `libncurses5-dev \libncursesw5-dev`——反斜杠与包名粘在一起是排版错误，应为 `libncurses5-dev libncursesw5-dev`（本文件已修正）。

---

## 12. 坑与注意事项

| # | 坑 | 处理 | 出处 |
|---|---|---|---|
| 1 | 在 WSL / 板子上编 SDK | 不支持，必失败 | P243 / PDF 252 |
| 2 | 换源命令漏 `/`（手册排版错） | `mv /etc/apt/sources.list /etc/apt/sources.list.bak` | P244 / PDF 253 |
| 3 | 改了 u-boot/内核源码，重编后改动消失 | `IGNORE_UPDATES="yes"`（需先成功编过一次） | P250、P254 / PDF 259、263 |
| 4 | `make menuconfig` 报错/截断 | Ubuntu 终端太小，最大化终端窗口再跑 | P253 / PDF 262 |
| 5 | 把 `current/next` 当 git 分支 | 它们是**内核线**，clone 仓库一律 `-b next` | P246 / PDF 255 |
| 6 | kernel deb 名字里是 `sun50iw9` 不是 `orangepizero3` | 别照着 u-boot 的命名找内核包 | P254 / PDF 263 |
| 7 | 以为 rootfs 每次都重编 | MD5 不变就用 `external/cache/rootfs` 缓存 | P258 / PDF 267 |
| 8 | Standard vs Minimal | 没特殊需求别选 Minimal（缺东西，功能可能用不了） | P256 / PDF 265 |
| 9 | 桌面环境只有 XFCE | 没有 GNOME/KDE 选项 | P256 / PDF 265 |
| 10 | openWRT 依赖行排版粘连 | 见 §11 修正 | P301 / PDF 310 |
| 11 | 用 v1.0.2 镜像自带 wiringOP 跑硬件 PWM | 重编最新 wiringOP | P129 / PDF 138 |
| 12 | 开 PWM3/4 后调试串口消失 | 复用 UART0，必须 `disable-uart0` | P127 / PDF 136 |

---

## 13. 待确认清单

| # | 项 | 现状 |
|---|---|---|
| 1 | **rootfs 的非交互命令**（`BUILD_OPT=rootfs`？） | 手册只给了 u-boot/kernel/image 三处 Repeat Build Options，rootfs 未给示例 |
| 2 | **镜像分支可选发行版数** | §4.5 说 next 有 4 个（含 ubuntu24.04），§4.6 说 3 个；以实际菜单为准 |
| 3 | **orangepi-build 磁盘/内存最低要求** | 手册未说明 |
| 4 | **Ubuntu 22.04 之外的编译机** | 手册明确只支持 22.04，其它版本未测试 |
| 5 | **如何在 SDK 里预置默认 dtbo** | 手册未说明板级默认 overlay 的打包方式 |
| 6 | **`orangepi-config` 里 I2C3 的选项名** | 手册仅截图（SPI/UART/PWM/LED 有文字） |
| 7 | **u-boot 的 `nand-sata-install` 通道号** | 手册写 “5 Install/Update the bootloader on SD/eMMC”，不同版本菜单号可能变化 |
| 8 | **Android 源码具体 band/版本号与 `lunch` 目标** | 手册给 `apollo_p2-userdebug`，board=p2；Zero 3 与 p2 的对应关系手册未展开说明 |
| 9 | **wPi 编号完整映射** | 见 §9.3，手册三处口径不一致 |
| 10 | **交叉工具链官方校验值** | 手册只给清华镜像目录，未给 md5/sha256 |
