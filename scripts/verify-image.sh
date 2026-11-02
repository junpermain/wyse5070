#!/usr/bin/env bash
# 镜像结构自检：跑在 CI 里，也可以本地手动跑
# 用法: sudo ./scripts/verify-image.sh out/wyse5070-6.12.115.img.gz
set -euo pipefail
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

IMG_GZ="${1:-}"
if [ -z "$IMG_GZ" ] || [ ! -f "$IMG_GZ" ]; then
  echo "用法: sudo $0 <path/to/*.img.gz>"; exit 1
fi

WORK=$(mktemp -d /tmp/verify.XXXXXX)
ROOT="$WORK/root"; ESP="$WORK/esp"; LOOP=""
cleanup() {
  set +e
  umount -R "$ROOT" 2>/dev/null
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "!! $*"; exit 1; }
ok()   { echo "   [OK] $*"; }

echo "==> 1/6 gzip 完整性"
gzip -t "$IMG_GZ" || fail "gzip 校验失败，压缩包是坏的"
ok "gzip -t 通过（$(du -h "$IMG_GZ" | cut -f1)）"

echo "==> 2/6 挂载分区"
IMG="$WORK/img"
zcat "$IMG_GZ" > "$IMG"
LOOP=$(losetup -Pf --show "$IMG") || fail "losetup 失败"
mkdir -p "$ROOT" "$ESP"
mount "${LOOP}p2" "$ROOT" || fail "root 分区挂不上"
mount "${LOOP}p1" "$ESP"  || fail "ESP 挂不上"
ok "两个分区都能挂载"

echo "==> 3/6 UEFI 引导文件"
[ -f "$ESP/EFI/BOOT/BOOTX64.EFI" ] \
  || fail "ESP 缺 EFI/BOOT/BOOTX64.EFI —— 真机根本不会引导"
ok "EFI/BOOT/BOOTX64.EFI"
# grub-install --removable 的 prefix 就指向 /EFI/BOOT，配置不在这儿会掉进 rescue shell
[ -f "$ESP/EFI/BOOT/grub.cfg" ] \
  || fail "ESP 缺 EFI/BOOT/grub.cfg —— --removable 模式下 GRUB 只认这个位置"
ok "EFI/BOOT/grub.cfg"

echo "==> 4/6 PARTUUID / UUID 一致性"
PU=$(blkid -s PARTUUID -o value "${LOOP}p2")
FU=$(blkid -s UUID -o value "${LOOP}p2")
[ -n "$PU" ] && [ -n "$FU" ] || fail "取不到 root 分区标识"
grep -q "$PU" "$ROOT/boot/grub/grub.cfg" || fail "grub.cfg 里没有 PARTUUID=$PU"
grep -q "$PU" "$ROOT/etc/fstab"          || fail "fstab 的 PARTUUID 跟实际分区不一致"
grep -q "$FU" "$ROOT/boot/grub/grub.cfg" || fail "grub.cfg 缺 search --fs-uuid $FU"
if grep -q '__ROOT_' "$ROOT/boot/grub/grub.cfg"; then
  fail "grub.cfg 里还有没替换的占位符"
fi
ok "PARTUUID=$PU  grub.cfg 与 fstab 一致"
ok "fs-uuid=$FU  search 指令在位"

echo "==> 5/6 内核与模块"
[ -f "$ROOT/boot/vmlinuz-wyse5070" ] || fail "缺 /boot/vmlinuz-wyse5070"
ok "内核 $(du -h "$ROOT/boot/vmlinuz-wyse5070" | cut -f1)"
MODDIR=$(ls -d "$ROOT"/lib/modules/*/ 2>/dev/null | head -1 || true)
[ -n "$MODDIR" ] || fail "/lib/modules 是空的"
[ -f "$MODDIR/modules.dep" ] || fail "modules.dep 不存在 —— depmod 没跑成功，模块加载不了"
MODN=$(find "$MODDIR" -name '*.ko*' | wc -l)
[ "$MODN" -gt 0 ] || fail "模块目录里没有任何 .ko"
ok "$(basename "$MODDIR")：$MODN 个模块 + modules.dep"
if [ -n "${KVER:-}" ]; then
  case "$(basename "$MODDIR")" in "$KVER") ok "版本与期望一致 $KVER" ;; *) fail "模块版本 $(basename "$MODDIR") ≠ 期望 $KVER" ;; esac
fi

echo "==> 6/6 用户空间"
[ -f "$ROOT/usr/bin/apk" ]        || fail "没有 /usr/bin/apk，rootfs 不是 Alpine"
[ -e "$ROOT/sbin/init" ]          || fail "没有 /sbin/init，起不来"
[ -f "$ROOT/root/setup/alpine-setup.sh" ] || fail "缺首启脚本 /root/setup/alpine-setup.sh"
ok "Alpine rootfs + init + 首启脚本"

echo
echo "==> 自检全部通过：$IMG_GZ"
