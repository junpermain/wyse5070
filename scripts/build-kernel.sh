#!/usr/bin/env bash
# 编译 Wyse 5070 用的 x86_64 内核（host gcc 直接编，无需交叉工具链）
# 用法: KVER=6.12.115 ./scripts/build-kernel.sh
set -euo pipefail

KVER="${KVER:-6.12.115}"
JOBS="${JOBS:-$(nproc)}"
WORK="${WORK:-$PWD/build/kernel}"
DIST="${DIST:-$PWD/dist}"
FRAG="${FRAG:-configs/kernel-fragment.config}"

mkdir -p "$WORK" "$DIST"

MAJOR="${KVER%%.*}"
TARBALL="linux-${KVER}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"

cd "$WORK"
if [ ! -f "$TARBALL" ] || ! xz -t "$TARBALL" >/dev/null 2>&1; then
  echo "==> 下载 $URL"
  rm -f "$TARBALL"
  curl -fL --retry 3 --retry-delay 5 -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi

if [ ! -d "linux-${KVER}" ]; then
  echo "==> 解包"
  tar xf "$TARBALL"
fi

cd "linux-${KVER}"

echo "==> x86_64_defconfig"
make ARCH=x86_64 x86_64_defconfig >/dev/null

if [ -f "$OLDPWD/$FRAG" ]; then
  FRAG_PATH="$OLDPWD/$FRAG"
elif [ -f "$FRAG" ]; then
  FRAG_PATH="$FRAG"
elif [ -f "../../$FRAG" ]; then
  FRAG_PATH="../../$FRAG"
else
  echo "!! 找不到内核片段 $FRAG"; exit 1
fi

echo "==> 合并片段 $FRAG_PATH"
scripts/kconfig/merge_config.sh -m .config "$FRAG_PATH" >/dev/null
make ARCH=x86_64 olddefconfig >/dev/null

echo "==> 校验关键项"
for opt in CONFIG_ANDROID_BINDERFS CONFIG_ANDROID_BINDER_IPC CONFIG_NF_NAT \
           CONFIG_IP_NF_TARGET_MASQUERADE CONFIG_DRM_I915 CONFIG_SND_HDA_CODEC_HDMI \
           CONFIG_R8169 CONFIG_SDHCI_ACPI CONFIG_USB_XHCI_HCD CONFIG_BLK_DEV_SD; do
  val=$(grep -E "^${opt}=" .config | head -1 || true)
  if [ -z "$val" ]; then
    echo "   [缺失] $opt"
  else
    echo "   $val"
  fi
done

echo "==> 编译 bzImage (-j$JOBS)"
make ARCH=x86_64 -j"$JOBS" bzImage

echo "==> 安装模块到临时目录"
rm -rf "$WORK/modules"
make ARCH=x86_64 INSTALL_MOD_PATH="$WORK/modules" modules_install >/dev/null

mkdir -p "$DIST"
cp arch/x86/boot/bzImage "$DIST/bzImage-${KVER}"
cp .config "$DIST/kernel-config-${KVER}"
tar -C "$WORK/modules/lib/modules" -czf "$DIST/modules-${KVER}.tar.gz" "${KVER}"

echo "==> 产物:"
ls -lh "$DIST"
