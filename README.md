# Wyse 5070 / 3040 IPTV 镜像 · GitHub Actions 自动编译

把原本要在本地（n100 / Buildroot）干的重活搬到 GitHub 的 runner 上：push 一次，十几分钟后直接下载能烧的镜像。

## 为什么快

Buildroot 那套要先把交叉 gcc 编一遍，光工具链就半小时。这里目标本来就是 x86_64，和 runner 同架构，**用 runner 自带的 gcc 直接编**，省掉整条工具链，只编内核本体。

- 内核：`x86_64_defconfig` + `configs/kernel-fragment.config` 合并
- 用户空间：Alpine minirootfs（不自己造 rootfs）
- 引导：GRUB2 UEFI（`--removable`，不写 NVRAM，换机器/清 CMOS 也能起）
- 不需要 initramfs：SATA/NVMe/EXT4 都编进内核，直接 `root=PARTUUID=...`

## 目录

```
.github/workflows/build.yml    4 个 job：编内核 → 打镜像+自检 → QEMU 冒烟 → tag 出 Release
scripts/build-kernel.sh        下载源码、合并片段、编 bzImage + 模块（支持 ccache）
scripts/build-image.sh         分区、装 Alpine、塞内核、装 GRUB、压成 .img.gz
scripts/verify-image.sh        结构自检：gzip / ESP / PARTUUID / 模块 / rootfs
scripts/smoke-boot.sh          QEMU(OVMF) 真引导一次，确认能挂 root 进 init
configs/kernel-fragment.config 内核追加项（binderfs / NAT / i915 / R8169 / NVMe …）
configs/grub.cfg               启动菜单模板
rootfs/alpine-setup.sh         首次启动后在机器上跑：装 waydroid/cage/pipewire
rootfs/start_mytv.sh           拉起 MyTV 的脚本
```

## 流水线怎么跑

| 触发 | 行为 |
|---|---|
| push 到 `main`（改动非 md 文件） | 全流程构建，产物放 Artifacts |
| 手动 Run workflow | 可指定内核版本（默认 `6.12.115`） |
| 打 tag `v*` | 全流程 + 自动创建 GitHub Release，产物永久保留 |

四个 job 的接力关系：

```
kernel ──dist/（bzImage + 模块 + config）──> image ──out/*.img.gz──> smoke
                                                     └────────────> release（仅 tag）
```

**跨 job 传文件的坑**：`upload-artifact` 上传 `dist` 目录时会把内容放在 artifact 根部，`download-artifact` 时必须指定 `path: dist` 才能还原成 `dist/bzImage-*`，否则打包脚本找不到内核。`image` job 第一步就有一步 `ls dist/bzImage-*` 做断言，路径一旦错会立刻报错，而不是编到一半才炸。

## 自我校验（失败即终止）

1. **内核侧**（`STRICT=1`）：合并片段后逐项检查 12 个关键符号，缺一个就退出，不浪费二十分钟编出一个跑不起来的盘
2. **镜像侧**（`verify-image.sh`）
   - `gzip -t` 完整性
   - ESP 里 `EFI/BOOT/BOOTX64.EFI` **以及** `EFI/BOOT/grub.cfg` 都在（`--removable` 的 GRUB 只认 ESP 上这份配置，缺了真机直落 rescue shell）
   - `grub.cfg` 的 `PARTUUID` 与 `fstab` 一致，`search --fs-uuid` 在位，没有残留占位符
   - `/lib/modules/<ver>/modules.dep` 存在且有 `.ko`（证明 `depmod` 跑成功）
   - rootfs 里有 `apk`、`/sbin/init`、首启脚本
3. **可启动性**（`smoke-boot.sh`）：QEMU + OVMF 真引导这张盘，串口日志里必须看到 `Linux version`、`Kernel command line ... root=PARTUUID=`、`EXT4-fs (sda2): mounted filesystem`、`Run /sbin/init as init process`，出现 `Kernel panic` 直接判失败。串口日志作为 artifact 留 15 天，真机起不来时可对照。

## 缓存

| 缓存 | key | 效果 |
|---|---|---|
| 内核源码包 `build/kernel/linux-*.tar.xz` | `ksrc-<ver>` | 省掉每次一分多钟下载 |
| ccache `~/.ccache` | `ccache-<ver>-<片段哈希>-<sha>`，逐级回退 | 只改片段里一两项时，绝大部分目标文件复用，重编从 15 分钟级降到分钟级 |

runner 是 4 核（公开仓库；私有仓库默认 2 核）。冷编译约 15–20 分钟，命中 ccache 后通常 3–6 分钟。

## 推送

```bash
cd wyse5070-ci
git init && git add . && git commit -m "wyse5070 image build"
git branch -M main
git remote add origin git@github.com:<你的账号>/<仓库名>.git
git push -u origin main
```

出 Release：

```bash
git tag v1.0 && git push origin v1.0
```

## 本地也能跑

脚本不依赖 GitHub，任何 Linux 上（需要 gcc、bc、bison、flex、libssl-dev、libelf-dev、dosfstools、parted、mtools、grub-efi-amd64-bin、qemu-system-x86、ovmf）：

```bash
KVER=6.12.115 CCACHE=1 ./scripts/build-kernel.sh      # 编内核，产物进 dist/
sudo -E ./scripts/build-image.sh                      # 打镜像，产物进 out/
sudo ./scripts/verify-image.sh out/wyse5070-*.img.gz  # 结构自检
./scripts/smoke-boot.sh out/wyse5070-*.img.gz         # QEMU 试转一圈
```

`build/kernel` 里会缓存源码包，重跑不用重新下载。

## 烧盘

- Windows：Rufus 选 **DD 模式**（❗不要 ISO 模式），或 balenaEtcher
- Linux：`zcat wyse5070-*.img.gz | sudo dd of=/dev/sdX bs=4M status=progress`

U 盘 ≥4G。插到机器上，BIOS 里**关掉 Secure Boot**（自编译内核和 GRUB 都没签名），F12 选 U 盘启动。

## 首次启动

镜像里只有 Alpine 基础系统，安卓那套要联网装：

```bash
sh /root/setup/alpine-setup.sh
```

它会换源、装 waydroid / cage / pipewire、建 kiosk 用户、配 tty1 自动登录。装完重启就进 MyTV。

## 排障

| 现象 | 大概率原因 |
|---|---|
| 开机直接进 BIOS / 不认盘 | Secure Boot 没关；或 U 盘不是 UEFI 方式写入（Rufus 用了 ISO 模式） |
| 黑屏无输出 | 接了 DP 转 HDMI 转接头不兼容；换 DP++ 双模头试试 |
| 掉进 `grub rescue>` | ESP 上的 `grub.cfg` 丢了，看 `verify-image.sh` 的检查项 |
| 启动后 `can't open root device` | 分区表变了/镜像写到别处，`grub.cfg` 的 PARTUUID 与 `fstab` 对不上 |
| 卡在 init 之后 | 串口接上看 `调试模式` 那个启动项的完整日志 |

无头机器调试：接 USB-TTL 到板上的串口（或直接用 5070 的串口针脚），选 GRUB 第二项「调试模式」，`loglevel=7` + `console=ttyS0,115200`，日志走串口。正常项也带了 `console=ttyS0,115200`（`loglevel=4`），所以冒烟测试和日常排障都能拿到内核输出。

## 改内核

只改 `configs/kernel-fragment.config`，push 即重编。例如加驱动：

```
CONFIG_MY_DRIVER=y
```

注意两点：

1. 这个文件是 `merge_config.sh` 合并进 `x86_64_defconfig` 的，依赖没满足的项会被 `olddefconfig` 悄悄丢掉 —— 所以 `STRICT=1` 会把它变成硬失败
2. 换内核版本用 Run workflow 填版本号，别改文件；头文件与内核版本在纯内核构建里不涉及，不会重演 Buildroot 那次 `linux-headers 2.6` 的坑

## 已知限制

- 镜像固定 2.5G（root 分区就这么大）；要扩容：`growpart /dev/sda 2 && resize2fs /dev/sda2`
- 没有 initramfs，所以 `CONFIG_SATA_AHCI` / `CONFIG_BLK_DEV_SD` / `CONFIG_EXT4_FS` 必须保持 `=y`
- 冒烟测试只证明「能引导」，不证明 `i915` 硬解和 Waydroid 可用 —— 那需要真显卡，得在实机验
- 想改成「装到硬盘」而不是 U 盘：把 `build-image.sh` 里的 `--removable --no-nvram` 去掉并写入 NVRAM，或保留 removable 直接把镜像 dd 到硬盘（本方案天然支持，硬盘走同一条 UEFI 路径）
