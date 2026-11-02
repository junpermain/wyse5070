#!/usr/bin/env bash
# 用 dist/ 里编好的内核 + Alpine minirootfs 打一个可启动镜像
# 用法: sudo ./scripts/build-image.sh
set -euo pipefail

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

mount "${LOOP}p2" "$BUILD/root"
mkdir -p "$BUILD/root/boot/efi"
mount "${LOOP}p1" "$BUILD/root/boot/efi"

echo "==> 下载 Alpine minirootfs"
FILE=$(curl -fsSL "$ALPINE_BASE/latest-releases.yaml" \
       | grep -m1 'file: alpine-minirootfs' | awk '{print $2}')
curl -fL --retry 3 -o "$BUILD/alpine.tar.gz" "$ALPINE_BASE/$FILE"
tar xzf "$BUILD/alpine.tar.gz" -C "$BUILD/root"

echo "==> 放入内核模块"
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

mkdir -p "$BUILD/root/boot/grub"
sed "s|__ROOT_PARTUUID__|$ROOT_PARTUUID|g" "$REPO/configs/grub.cfg" \
  > "$BUILD/root/boot/grub/grub.cfg"

sync
umount -R "$BUILD/root"
losetup -d "$LOOP"
trap - EXIT

echo "==> 压缩"
gzip -1 -c "$IMG" > "$OUT/wyse5070-$KVER.img.gz"
rm -f "$IMG"
ls -lh "$OUT"
