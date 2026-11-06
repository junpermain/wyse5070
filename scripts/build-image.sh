#!/usr/bin/env bash
# 用 dist/ 里编好的内核 + Alpine minirootfs 打一个可启动镜像
# 用法: sudo ./scripts/build-image.sh
set -euo pipefail
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

if [ "$EUID" -ne 0 ]; then
  echo "需要 root 运行（挂载 loop 设备）: sudo $0"; exit 1
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO/dist"
OUT="$REPO/out"
BUILD="$REPO/build/image"
IMG_MB="${IMG_MB:-2560}"
# Alpine 源：默认走阿里云镜像。dl-cdn.alpinelinux.org 在国内常出现
# "OpenSSL SSL_read: unexpected eof" 之类的中途断流，重试也未必能过。
# 国外环境可用 ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine 覆盖。
ALPINE_MIRROR="${ALPINE_MIRROR:-https://mirrors.aliyun.com/alpine}"
ALPINE_BASE="${ALPINE_BASE:-$ALPINE_MIRROR/latest-stable/releases/x86_64}"
APK_MIRROR="${APK_MIRROR:-$ALPINE_MIRROR}"
DNS_SERVERS="${DNS_SERVERS:-223.5.5.5 119.29.29.29}"

KERNEL=$(ls "$DIST"/bzImage-* 2>/dev/null | head -1 || true)
[ -n "$KERNEL" ] || { echo "找不到 $DIST/bzImage-*"; exit 1; }
KVER=$(basename "$KERNEL" | sed 's/^bzImage-//')
MODTAR="$DIST/modules-${KVER}.tar.gz"
[ -f "$MODTAR" ] || { echo "找不到 $MODTAR"; exit 1; }

# 镜像名里嵌入提交号，方便追溯"这张盘是哪次提交打出来的"；本地构建留空
SUFFIX=""
if [ -n "${GIT_SHA:-}" ]; then
  SUFFIX="-g$(printf '%s' "$GIT_SHA" | cut -c1-7)"
fi

echo "==> 内核版本 $KVER, 镜像 ${IMG_MB}MiB"
rm -rf "$BUILD"; mkdir -p "$BUILD/root" "$OUT"

IMG="$BUILD/wyse5070.img"
truncate -s "${IMG_MB}M" "$IMG"
# 双引导布局：p1 ESP(UEFI) / p2 root / p3 bios_grub(Legacy BIOS 的 core.img 嵌入区)
# root 收在 (IMG_MB-3)MiB，最后留 3MiB 给 BIOS 引导分区；分区编号保持 p1/p2 不变，
# grub.cfg/fstab 全部动态取 PARTUUID，不受影响
BIOS_PART_START="$((IMG_MB - 3))MiB"
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart ESP fat32 1MiB 257MiB
parted -s "$IMG" set 1 esp on
parted -s "$IMG" mkpart root ext4 257MiB "$BIOS_PART_START"
parted -s "$IMG" mkpart biosboot "$BIOS_PART_START" 100%
parted -s "$IMG" set 3 bios_grub on

LOOP=$(losetup -Pf --show "$IMG")
cleanup() {
  set +e
  umount -R "$BUILD/root" 2>/dev/null
  losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

mkfs.vfat -F32 -n WYSEESP "${LOOP}p1" >/dev/null
mkfs.ext4 -F -q -L wyse-root "${LOOP}p2"
# p3 是 bios_grub 裸分区，不打文件系统
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${LOOP}p2")
ROOT_FSUUID=$(blkid -s UUID -o value "${LOOP}p2")
[ -n "$ROOT_PARTUUID" ] && [ -n "$ROOT_FSUUID" ] || { echo "取不到 root 分区 UUID"; exit 1; }

mount "${LOOP}p2" "$BUILD/root"
mkdir -p "$BUILD/root/boot/efi"
mount "${LOOP}p1" "$BUILD/root/boot/efi"

echo "==> 下载 Alpine minirootfs"
FILE=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors "$ALPINE_BASE/latest-releases.yaml" \
       | grep -m1 'file: alpine-minirootfs' | awk '{print $2}')
[ -n "$FILE" ] || { echo "!! 取不到 minirootfs 文件名（源: $ALPINE_BASE）"; exit 1; }
echo "    $FILE"
curl -fL --retry 5 --retry-delay 2 --retry-all-errors -o "$BUILD/alpine.tar.gz" "$ALPINE_BASE/$FILE"
tar xzf "$BUILD/alpine.tar.gz" -C "$BUILD/root"

# Alpine 3.24+ 的 minirootfs 不再自带 openrc（inittab 却仍引用 /sbin/openrc），
# 不补装的话开机卡在 "can't run '/sbin/openrc'"
# chroot 内的 DNS 与 apk 源都要单独配：宿主机的 resolv.conf 常是 127.0.0.53 这类
# 本地 stub，chroot 里解析不了会一直重试把 job 挂死；源也换成镜像站，避免断流。
echo "==> 补装 openrc（新版 minirootfs 已移除）"
printf 'nameserver %s\n' $DNS_SERVERS > "$BUILD/root/etc/resolv.conf"
mkdir -p "$BUILD/root/etc/apk"
cat > "$BUILD/root/etc/apk/repositories" <<EOF
$APK_MIRROR/latest-stable/main
$APK_MIRROR/latest-stable/community
EOF
timeout 300 chroot "$BUILD/root" /sbin/apk add --no-cache --no-progress openrc >/dev/null 2>&1 \
  || { echo "!! apk add openrc 失败（300s 超时或网络不可达）"; exit 1; }
rm -f "$BUILD/root/etc/resolv.conf"
[ -e "$BUILD/root/sbin/openrc" ] || { echo "!! openrc 未落位"; exit 1; }

echo "==> 放入内核模块"
mkdir -p "$BUILD/root/lib/modules" "$BUILD/root/boot"
tar -C "$BUILD/root/lib/modules" -xzf "$MODTAR"

echo "==> 放入内核与脚本"
cp "$KERNEL" "$BUILD/root/boot/vmlinuz-wyse5070"
mkdir -p "$BUILD/root/root/setup"
cp "$REPO/rootfs/alpine-setup.sh" "$BUILD/root/root/setup/" 2>/dev/null || true
cp "$REPO/rootfs/start_mytv.sh"   "$BUILD/root/root/setup/" 2>/dev/null || true
mkdir -p "$BUILD/root/etc/apk"

cat > "$BUILD/root/etc/fstab" <<EOF
PARTUUID=$ROOT_PARTUUID  /       ext4  defaults,noatime  0 1
tmpfs                    /tmp    tmpfs defaults,nosuid,nodev 0 0
EOF

cat > "$BUILD/root/etc/motd" <<'EOF'
Wyse 5070 IPTV 镜像
首启请执行:  sh /root/setup/alpine-setup.sh
EOF

# 不用 grub-install：发行版签名版 grub 的内嵌引导逻辑不统一
#   （Ubuntu 的会先 search /.disk/info 找不到就掉 shell，Debian 的行为又不同），
# 用 grub-mkstandalone 把带 UUID 的完整 grub.cfg 直接嵌进 EFI 二进制，
# 任何发行版上打出来的镜像引导行为都一致，也不依赖 ESP 上有没有配置文件。
mkdir -p "$BUILD/root/boot/grub" "$BUILD/root/boot/efi/EFI/BOOT"
sed -e "s|__ROOT_PARTUUID__|$ROOT_PARTUUID|g" \
    -e "s|__ROOT_FSUUID__|$ROOT_FSUUID|g" "$REPO/configs/grub.cfg" \
  > "$BUILD/root/boot/grub/grub.cfg"
cp "$BUILD/root/boot/grub/grub.cfg" "$BUILD/root/boot/efi/EFI/BOOT/grub.cfg"

echo "==> 生成独立 GRUB EFI (grub-mkstandalone)"
grub-mkstandalone -O x86_64-efi \
  -o "$BUILD/root/boot/efi/EFI/BOOT/BOOTX64.EFI" \
  --modules="part_gpt part_msdos ext2 fat linux search search_fs_uuid search_label normal configfile echo test boot gzio all_video serial" \
  "boot/grub/grub.cfg=$BUILD/root/boot/grub/grub.cfg"
[ -s "$BUILD/root/boot/efi/EFI/BOOT/BOOTX64.EFI" ] || { echo "!! BOOTX64.EFI 生成失败"; exit 1; }

# BIOS/Legacy 引导。
# 不能用 grub-mkstandalone：它把 grub.cfg 以 memdisk 形式整个内嵌，i386-pc 的
# core.img 编译完约 3MB，直接撞上 "核心镜像过大 (0x2f8d73 > 0x78000)" 的硬上限
# （i386-pc 的 core 只能占 480KiB，这块空间要挤在 MBR 之后）。
# 标准做法：grub-mkimage 生成不含配置的 core.img，prefix 指向 root 分区上的
# /boot/grub，再用 grub-bios-setup 写 MBR（保留分区表）+ bios_grub 分区，
# 并回填 core.img 的真实起始 LBA——手工 dd 是补不上这个 LBA 的，只会读到错位置。
echo "==> 生成 BIOS/Legacy 引导 (core.img + grub-bios-setup)"
BIOS_DIR="$BUILD/bios"
mkdir -p "$BIOS_DIR"
grub-mkimage -O i386-pc -o "$BIOS_DIR/core.img" \
  -p '(hd0,gpt2)/boot/grub' \
  biosdisk part_gpt part_msdos ext2 fat linux search search_fs_uuid search_label normal configfile echo test boot gzio all_video serial
[ -s "$BIOS_DIR/core.img" ] || { echo "!! BIOS core.img 生成失败"; exit 1; }
CORE_SIZE=$(stat -c%s "$BIOS_DIR/core.img")
echo "    core.img $CORE_SIZE 字节（上限 480KiB）"
[ "$CORE_SIZE" -lt $((480 * 1024)) ] || { echo "!! core.img ($CORE_SIZE B) 超过 i386-pc 的 480KiB 上限"; exit 1; }
echo "(hd0) $LOOP" > "$BIOS_DIR/device.map"
# Debian/Ubuntu 把 grub-bios-setup 装在 /usr/lib/grub/i386-pc 下（不进 PATH），
# 上游/Gentoo 则是 /usr/sbin，两处都探一下
GRUB_BIOS_SETUP=$(command -v grub-bios-setup 2>/dev/null || true)
[ -n "$GRUB_BIOS_SETUP" ] || GRUB_BIOS_SETUP=/usr/lib/grub/i386-pc/grub-bios-setup
[ -x "$GRUB_BIOS_SETUP" ] || { echo "!! 找不到 grub-bios-setup（需 grub-pc-bin）"; exit 1; }
cp -f /usr/lib/grub/i386-pc/boot.img "$BIOS_DIR/boot.img"
"$GRUB_BIOS_SETUP" -d "$BIOS_DIR" -m "$BIOS_DIR/device.map" "$LOOP"
sync

echo "==> 卸载并压缩"
sync
umount -R "$BUILD/root" 2>/dev/null || true
losetup -d "$LOOP" 2>/dev/null || true
trap - EXIT

IMAGE_FILE="$OUT/wyse5070-${KVER}${SUFFIX}.img.gz"
gzip -1 -c "$IMG" > "$IMAGE_FILE"
rm -f "$IMG"
ls -lh "$OUT"
echo "$IMAGE_FILE"
