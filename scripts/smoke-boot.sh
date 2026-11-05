#!/usr/bin/env bash
# QEMU 冒烟启动：证明这张盘真的能从 GRUB 拉起内核、挂上 root、进 init
# 双引导镜像跑两遍：OVMF(UEFI) + SeaBIOS(Legacy BIOS)，两边都必须进 init
# 只验证"起得来"，不验证 Waydroid（那要真显卡和网络）
# 用法: ./scripts/smoke-boot.sh out/wyse5070-6.12.115.img.gz
set -euo pipefail
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

IMG_GZ="${1:-}"
if [ -z "$IMG_GZ" ] || [ ! -f "$IMG_GZ" ]; then
  echo "用法: $0 <path/to/*.img.gz>"; exit 1
fi
MAX_WAIT="${MAX_WAIT:-240}"   # 秒，TCG 模拟下内核启动约 30–90s，公共 runner 上留足余量
LOG_DIR="${SMOKE_LOG_DIR:-$(cd "$(dirname "$IMG_GZ")" 2>/dev/null && pwd)}"
[ -w "$LOG_DIR" ] || LOG_DIR="${TMPDIR:-/tmp}"

find_ovmf() {
  for f in /usr/share/OVMF/OVMF_CODE_4M.fd \
           /usr/share/OVMF/OVMF_CODE.fd \
           /usr/share/ovmf/OVMF.fd \
           /usr/share/edk2/x64/OVMF_CODE.fd \
           /usr/share/qemu/OVMF.fd; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}
OVMF=$(find_ovmf) || { echo "!! 找不到 OVMF 固件，装一下 ovmf 包"; exit 1; }
# OVMF_CODE_* 是纯代码段，必须走 pflash（code + vars 双盘）；只有整包 OVMF.fd 才能用 -bios
VARS_TMPL=""
for v in "${OVMF%_CODE*}_VARS"* "/usr/share/OVMF/OVMF_VARS_4M.fd" "/usr/share/OVMF/OVMF_VARS.fd" "/usr/share/OVMF/OVMF_VARS.ms.fd"; do
  [ -f "$v" ] && { VARS_TMPL="$v"; break; }
done

# 有 KVM 就用，没有就退 TCG；-cpu max 在 TCG 下最保险
ACCEL=(-cpu max)
if [ -w /dev/kvm ]; then ACCEL=(-enable-kvm -cpu host); fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX")
IMG="$WORK/img"
cleanup() {
  set +e
  [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> 解压镜像"
zcat "$IMG_GZ" > "$IMG"

# ---------------------------------------------------------------- 引导一轮
# 参数: run_boot <日志路径> <额外 QEMU 参数...>（固件相关参数由调用方传入）
run_boot() {
  local LOG="$1"; shift
  : > "$LOG"
  QPID=""
  echo "==> QEMU 版本: $(qemu-system-x86_64 --version | head -1)"
  echo "==> QEMU 启动（最长 ${MAX_WAIT}s，日志 $LOG）"
  qemu-system-x86_64 \
    -machine pc "${ACCEL[@]}" -m 1024 \
    -display none -monitor none -no-reboot -no-shutdown \
    -serial "file:$LOG" \
    "$@" \
    -drive "file=$IMG,format=raw,if=ide,index=0" \
    -net none &
  QPID=$!

  local READY=0
  for _ in $(seq 1 $((MAX_WAIT / 2))); do
    if grep -q "Run /sbin/init as init process" "$LOG" 2>/dev/null; then READY=1; sleep 2; break; fi
    if grep -qi "Kernel panic" "$LOG" 2>/dev/null; then break; fi
    kill -0 "$QPID" 2>/dev/null || break
    sleep 2
  done
  kill "$QPID" 2>/dev/null || true
  wait "$QPID" 2>/dev/null || true
  QPID=""

  echo "----- 串口日志（头 10 行） -----"
  head -n 10 "$LOG" 2>/dev/null || echo "(无输出)"
  echo "----- 串口日志（尾 40 行） -----"
  tail -n 40 "$LOG" 2>/dev/null || echo "(无输出)"
  echo "---------------------------"
  [ "$READY" = "1" ] || return 1
  return 0
}

# ---------------------------------------------------------------- 证据检查
fail() { echo "!! $*"; exit 1; }

check_evidence() {
  local LOG="$1" MODE="$2"
  if grep -qi "Kernel panic" "$LOG"; then
    fail "[$MODE] 内核 panic，镜像起不来"
  fi
  grep -q "Linux version" "$LOG" || fail "[$MODE] 串口没看到内核启动信息（GRUB 没引导起来？）"
  grep -q "Kernel command line" "$LOG" || fail "[$MODE] 拿不到内核命令行"
  grep -q "root=PARTUUID=" "$LOG" || fail "[$MODE] 内核命令行里没有 root=PARTUUID，GRUB 配置没生效"
  ok_line=$(grep -m1 "Kernel command line" "$LOG")
  echo "   $ok_line"
  grep -qE "EXT4-fs \((sda|sdb|hda|vda)2\): mounted filesystem" "$LOG" \
    || fail "[$MODE] root 分区没挂上（第 2 分区未识别或 fstab 有误）"
  echo "   [OK] root 分区挂载成功"
  grep -q "Run /sbin/init as init process" "$LOG" || fail "[$MODE] 没走到 init（内核起来了但 rootfs 不可用）"
  echo "   [OK] 已进入 /sbin/init"
}

# ---------------------------------------------------------------- 1) UEFI
UEFI_LOG="$LOG_DIR/serial-uefi.log"
BIOS_ARGS=()
if [ -n "$VARS_TMPL" ]; then
  cp "$VARS_TMPL" "$WORK/vars.fd"
  BIOS_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF" \
             -drive "if=pflash,format=raw,file=$WORK/vars.fd")
else
  BIOS_ARGS=(-bios "$OVMF")
fi
echo "==> 固件: OVMF (UEFI) —— $OVMF"
if run_boot "$UEFI_LOG" "${BIOS_ARGS[@]}"; then
  check_evidence "$UEFI_LOG" "UEFI"
  echo "   ==> UEFI 引导冒烟通过"
else
  check_evidence "$UEFI_LOG" "UEFI"   # 内部会 fail 并给出原因
fi

# ---------------------------------------------------------------- 2) Legacy BIOS
BIOS_LOG="$LOG_DIR/serial-bios.log"
echo "==> 固件: SeaBIOS (Legacy BIOS)"
if run_boot "$BIOS_LOG"; then
  check_evidence "$BIOS_LOG" "BIOS"
  echo "   ==> BIOS 引导冒烟通过"
else
  check_evidence "$BIOS_LOG" "BIOS"
fi

echo
echo "==> 冒烟测试通过：UEFI 与 Legacy BIOS 两条引导链都能起、能挂 root、能进 init"
