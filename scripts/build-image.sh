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
ALPINE_BASE="${ALPINE_BASE:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64}"

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
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart ESP fat32 1MiB 257MiB
parted -s "$IMG" set 1 esp on
parted -s "$IMG" mkpart root ext4 257MiB 100%

LOOP=$(losetup -Pf --show "$IMG")
cleanup() {
  set +e
  umount -R "$BUILD/root" 2>/dev/null
  losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

mkfs.vfat -F32 -n WYSEESP "${LOOP}p1" >/dev/null
mkfs.ext4 -F -q -L wyse-root "${LOOP}p2"
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${LOOP}p2")
ROOT_FSUUID=$(blkid -s UUID -o value "${LOOP}p2")
[ -n "$ROOT_PARTUUID" ] && [ -n "$ROOT_FSUUID" ] || { echo "取不到 root 分区 UUID"; exit 1; }

mount "${LOOP}p2" "$BUILD/root"
mkdir -p "$BUILD/root/boot/efi"
mount "${LOOP}p1" "$BUILD/root/boot/efi"

echo "==> 下载 Alpine minirootfs"
FILE=$(curl -fsSL "$ALPINE_BASE/latest-releases.yaml" \
       | grep -m1 'file: alpine-minirootfs' | awk '{print $2}')
curl -fL --retry 3 -o "$BUILD/alpine.tar.gz" "$ALPINE_BASE/$FILE"
tar xzf "$BUILD/alpine.tar.gz" -C "$BUILD/root"

# Alpine 3.24+ 的 minirootfs 不再自带 openrc（inittab 却仍引用 /sbin/openrc），
# 不补装的话开机卡在 "can't run '/sbin/openrc'"
echo "==> 补装 openrc（新版 minirootfs 已移除）"
cp -L /etc/resolv.conf "$BUILD/root/etc/resolv.conf" 2>/dev/null || true
chroot "$BUILD/root" /sbin/apk add --no-cache openrc >/dev/null 2>&1 \
  || { echo "!! apk add openrc 失败"; exit 1; }
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

echo "==> 安装 GRUB (UEFI, removable)"
grub-install --target=x86_64-efi \
  --efi-directory="$BUILD/root/boot/efi" \
  --boot-directory="$BUILD/root/boot" \
  --removable --no-nvram --no-floppy >/dev/null 2>&1

# --removable 装出来的 BOOTX64.EFI 内嵌 prefix 指向 ESP 上的 /EFI/BOOT，
# 所以 grub.cfg 必须同时放到 ESP，否则真机上是直接掉进 rescue shell。
mkdir -p "$BUILD/root/boot/grub" "$BUILD/root/boot/efi/EFI/BOOT"
sed -e "s|__ROOT_PARTUUID__|$ROOT_PARTUUID|g" \
    -e "s|__ROOT_FSUUID__|$ROOT_FSUUID|g" "$REPO/configs/grub.cfg" \
  > "$BUILD/root/boot/grub/grub.cfg"
cp "$BUILD/root/boot/grub/grub.cfg" "$BUILD/root/boot/efi/EFI/BOOT/grub.cfg"

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
