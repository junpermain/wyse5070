#!/usr/bin/env bash
# 编译 Wyse 5070/3040 用的 x86_64 内核（直接用 host gcc，无需交叉工具链）
# 用法: KVER=6.12.115 ./scripts/build-kernel.sh
set -euo pipefail
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KVER="${KVER:-6.12.115}"
JOBS="${JOBS:-$(nproc)}"
WORK="${WORK:-$REPO_DIR/build/kernel}"
DIST="${DIST:-$REPO_DIR/dist}"
FRAG="${FRAG:-configs/kernel-fragment.config}"

mkdir -p "$WORK" "$DIST"

# 片段路径统一按仓库根目录解析
case "$FRAG" in
  /*) : ;;
  *)  FRAG="$REPO_DIR/$FRAG" ;;
esac
[ -f "$FRAG" ] || { echo "!! 找不到内核片段: $FRAG"; exit 1; }

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

echo "==> 合并片段 $FRAG"
scripts/kconfig/merge_config.sh -m .config "$FRAG" >/dev/null
make ARCH=x86_64 olddefconfig >/dev/null

echo "==> 校验关键项"
MISSING=()
for opt in CONFIG_ANDROID_BINDERFS CONFIG_ANDROID_BINDER_IPC CONFIG_NF_NAT \
           CONFIG_IP_NF_TARGET_MASQUERADE CONFIG_DRM_I915 CONFIG_SND_HDA_CODEC_HDMI \
           CONFIG_R8169 CONFIG_MMC_SDHCI_ACPI CONFIG_USB_XHCI_HCD CONFIG_BLK_DEV_SD \
           CONFIG_BLK_DEV_NVME CONFIG_EXT4_FS; do
  val=$(grep -E "^${opt}=" .config | head -1 || true)
  if [ -z "$val" ]; then
    echo "   [缺失] $opt"
    MISSING+=("$opt")
  else
    echo "   $val"
  fi
done
# STRICT=1（CI 用）：缺一项就退出，别浪费二十分钟编出一个跑不起来的盘
if [ "${STRICT:-0}" = "1" ] && [ ${#MISSING[@]} -gt 0 ]; then
  echo "!! 关键配置缺失: ${MISSING[*]}"
  echo "!! 先看 configs/kernel-fragment.config 里这一项的依赖是否没满足"
  exit 1
fi

echo "==> 编译 bzImage + 模块 (-j$JOBS)"
# 可选 ccache：CI 上靠它把"只改了片段里一两项"的重编压到几分钟
MAKE_ARGS=()
if [ "${CCACHE:-0}" = "1" ]; then
  command -v ccache >/dev/null || { echo "!! 要求 CCACHE=1 但没装 ccache"; exit 1; }
  ccache -M 2G >/dev/null 2>&1 || true
  ccache -z >/dev/null 2>&1 || true
  MAKE_ARGS=("CC=ccache gcc" "HOSTCC=ccache gcc")
  echo "    ccache 已启用"
fi
make ARCH=x86_64 -j"$JOBS" "${MAKE_ARGS[@]}" bzImage modules

echo "==> 安装模块到临时目录"
rm -rf "$WORK/modules"
make ARCH=x86_64 "${MAKE_ARGS[@]}" INSTALL_MOD_PATH="$WORK/modules" modules_install >/dev/null

if [ "${CCACHE:-0}" = "1" ]; then
  echo "==> ccache 统计"
  ccache -s | sed 's/^/    /'
fi

mkdir -p "$DIST"
cp arch/x86/boot/bzImage "$DIST/bzImage-${KVER}"
cp .config "$DIST/kernel-config-${KVER}"
tar -C "$WORK/modules/lib/modules" -czf "$DIST/modules-${KVER}.tar.gz" "${KVER}"

# 片段里被 olddefconfig 丢掉的项，会在这里现原形（CI 里直接判失败）
echo "==> 产物:"
ls -lh "$DIST"
