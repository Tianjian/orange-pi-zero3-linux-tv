# Debian 12 镜像下载与校验记录

日期：2026-11-04
来源：Orange Pi 官网 Zero3 支持页 → Debian Image → linux6.1 文件夹 → server 版
页面：<http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/service-and-support/Orange-Pi-Zero-3.html>
Google Drive 文件夹：`1g2o209HE9_28v7wIXdq0tf5jOTTJdpVb` → `10zlO-0mMz-fqRQOKAOWX-mQA_UbN_C1n`
文件 ID：`1xbSmrUu0uffnFkDvZduvzV1oUilZIWL5`

## 文件

| 文件 | 大小（字节） | SHA256 |
|---|---|---|
| `Orangepizero3_1.0.4_debian_bookworm_server_linux6.1.31.7z` | 531,858,607 | `bfbe35d89164329402990e8ceb93c94cdff69020f89a44b7cfbfefb73bfb7249` |
| `Orangepizero3_1.0.4_debian_bookworm_server_linux6.1.31.img` | 2,571,108,352 | `dda562f0ce9c3fc2be656f816b8f3aea466a3f9ace9fdf87d97ebdc72aeada40` |

镜像内自带 `.img.sha`，内容与上面 img 的 SHA256 **一致**。

## 校验命令/结果

```text
$ 7z t Orangepizero3_1.0.4_debian_bookworm_server_linux6.1.31.7z
Everything is Ok
Files: 2
Size: 2571108477
Compressed: 531858607

$ cat ...img.sha
dda562f0ce9c3fc2be656f816b8f3aea466a3f9ace9fdf87d97ebdc72aeada40 *...img

$ sha256sum ...img
dda562f0ce9c3fc2be656f816b8f3aea466a3f9ace9fdf87d97ebdc72aeada40  ...img
```

## 镜像内容（debugfs 只读检查）

- `/etc/os-release`：`Orange Pi 1.0.4 Bookworm` / Debian 12 (bookworm)
- `/etc/hostname`：`orangepizero3`
- `/lib/modules`：`6.1.31-sun50iw9`
- `/boot`：`Image`（symlink）、`vmlinuz-6.1.31-sun50iw9`、`initrd.img-6.1.31-sun50iw9`、
  `dtb-6.1.31-sun50iw9/`、`orangepiEnv.txt`、`boot.scr`
- `/etc/passwd`：`root`、`orangepi` 两个账号；官方手册默认密码 `orangepi`
- 首次启动服务：`orangepi-firstrun.service`、`orangepi-resize-filesystem.service`（会自动扩 rootfs）

`/boot/orangepiEnv.txt`：

```text
verbosity=1
bootlogo=false
console=both
disp_mode=1920x1080p60
overlay_prefix=sun50i-h616
rootdev=UUID=535922e7-511d-46ea-82e6-573f913006af
rootfstype=ext4
```

- `console=both`：串口 + HDMI 都有 console；
- `disp_mode=1920x1080p60`：默认 1080p60，正好符合 docs/16 的 TV 基线。

## 分区表

```text
Disk ...img: 2.39 GiB, 2571108352 bytes, 5021696 sectors
Disklabel type: dos
Device ...img1  Boot Start 8192  End 5021695  Sectors 5013504  2.4G 83 Linux
```

单分区 ext4（`/boot` 是 rootfs 里的目录，不是独立 FAT 分区）；首次启动会扩到 TF 卡容量。

## 烧写

```bash
# 插卡后，确认设备（不要写系统盘）
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,TRAN

# 脚本已支持 .7z 自动解压；--verify 会读回校验
./scripts/flash_image.sh \
  images/Orangepizero3_1.0.4_debian_bookworm_server_linux6.1.31.7z \
  /dev/sdX --yes --verify
```

> `flash_image.sh` 会用 `7z e -so` 解压到临时 `.img`，再 `dd` 写入；
> 需要 sudo 权限（当前会话 sudo 需密码，建议在你的终端里执行）。
