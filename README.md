# Wyse 5070 / 3040 IPTV 镜像 · GitHub Actions 自动编译

把原来在本地（n100 / Buildroot）干的重活搬到 GitHub 的免费 runner 上：push 一次，十几分钟后直接下载能烧的镜像。

## 为什么快

Buildroot 那套要先把交叉 gcc 编一遍，光工具链就半小时。这里目标本来就是 x86_64，和 runner 同架构，**用 runner 自带的 gcc 直接编**，省掉整条工具链，只编内核本体。

- 内核：`x86_64_defconfig` + `configs/kernel-fragment.config` 合并
- 用户空间：Alpine minirootfs（不自己造 rootfs）
- 引导：GRUB2 UEFI（`--removable`，不写 NVRAM，换机器也能起）
- 不需要 initramfs：SATA/NVMe/EXT4 都编进了内核，直接 `root=PARTUUID=...`

## 目录

```
.github/workflows/build.yml   两个 job：编内核 → 打镜像
scripts/build-kernel.sh       下载内核源码、合并片段、编 bzImage + 模块
scripts/build-image.sh        分区、装 Alpine、塞内核、装 GRUB、压成 .img.gz
configs/kernel-fragment.config 内核追加项（binderfs / NAT / i915 / R8169 / NVMe …）
configs/grub.cfg              启动菜单模板
rootfs/alpine-setup.sh        首次启动后在机器上执行：装 waydroid/cage/pipewire
rootfs/start_mytv.sh          拉起 MyTV 的脚本
```

## 用法

1. 在 GitHub 建一个空仓库（public / private 都行，Actions 免费额度够）
2. 本地：
   ```bash
   git init
   git add .
   git commit -m "wyse5070 image build"
   git branch -M main
   git remote add origin git@github.com:<你的账号>/<仓库名>.git
   git push -u origin main
   ```
3. push 完自动开跑；也可以在 Actions 页面点 **Run workflow**，手动填内核版本（默认 `6.12.115`）
4. 跑完在 Actions → 这次 run → 页面底部 **Artifacts** 下载：
   - `kernel`：`bzImage-6.12.115`、`modules-6.12.115.tar.gz`、`kernel-config-6.12.115`
   - `wyse5070-image`：`wyse5070-6.12.115.img.gz`（可直接烧盘）

## 烧盘

- Windows：Rufus 选 **DD 模式**（不要 ISO 模式），或 balenaEtcher
- Linux：`zcat wyse5070-*.img.gz | sudo dd of=/dev/sdX bs=4M status=progress`

U 盘 ≥4G。烧完插到 5070/3040，BIOS 里关掉 Secure Boot，F12 选 U 盘启动。

## 首次启动

镜像里只放了 Alpine 基础系统，安卓那套要联网装：

```bash
sh /root/setup/alpine-setup.sh
```

它会换源、装 waydroid / cage / pipewire、建 kiosk 用户、配 tty1 自动登录。装完重启就进 MyTV。

## 本地也能跑

脚本不依赖 GitHub，任何 Linux 机器上（需要 gcc、bc、bison、flex、libssl-dev、libelf-dev）：

```bash
KVER=6.12.115 ./scripts/build-kernel.sh
sudo ./scripts/build-image.sh
```

`build/kernel` 里会缓存内核源码包，重跑不用重新下载。

## 已知限制

- 镜像固定 2.5G，root 分区就是这么大；要扩容就在目标机上 `growpart /dev/sda 2 && resize2fs /dev/sda2`
- runner 是 4 核，内核全量编大概 12–20 分钟（比 n100 快一点，n100 也是 4 核）
- 镜像里没有 initramfs，所以换内核时**必须**保持 SATA/NVMe/EXT4 是 `=y`，改了片段里这几项就得重新加 initramfs
