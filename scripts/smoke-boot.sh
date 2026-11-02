#!/usr/bin/env bash
# QEMU 冒烟启动：证明这张盘真的能从 GRUB 拉起内核、挂上 root、进 init
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
BIOS_ARGS=()
if [ -n "$VARS_TMPL" ]; then
  BIOS_ARGS=("pflash:$OVMF:$VARS_TMPL")
else
  BIOS_ARGS=("bios:$OVMF")
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX")
IMG="$WORK/img"
# 串口日志放在 WORK 之外：干净退出时 WORK 会被删掉，留着它才能诊断失败
LOG="$LOG_DIR/serial.log"; : > "$LOG"
QPID=""
cleanup() {
  set +e
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> 解压镜像"
zcat "$IMG_GZ" > "$IMG"

# 组装固件参数：pflash 需要一份可写的 VARS 副本
case "${BIOS_ARGS[0]}" in
  pflash:*)
    IFS=: read -r _ CODE VARS <<< "${BIOS_ARGS[0]}"
    cp "$VARS" "$WORK/vars.fd"
    BIOS_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=$CODE" \
               -drive "if=pflash,format=raw,file=$WORK/vars.fd")
    ;;
  bios:*)
    BIOS_ARGS=(-bios "${BIOS_ARGS[0]#bios:}")
    ;;
esac

echo "==> QEMU 版本: $(qemu-system-x86_64 --version | head -1)"
echo "==> 固件: ${BIOS_ARGS[*]}"
echo "==> QEMU 启动（OVMF: $OVMF，最长 ${MAX_WAIT}s，日志 $LOG）"
# 有 KVM 就用，没有就退 TCG；-cpu max 在 TCG 下最保险
ACCEL=(-cpu max)
if [ -w /dev/kvm ]; then ACCEL=(-enable-kvm -cpu host); fi
qemu-system-x86_64 \
  -machine pc "${ACCEL[@]}" -m 1024 \
  -display none -monitor none -no-reboot -no-shutdown \
  -serial "file:$LOG" \
  "${BIOS_ARGS[@]}" \
  -drive "file=$IMG,format=raw,if=ide,index=0" \
  -net none &
QPID=$!

READY=0
for _ in $(seq 1 $((MAX_WAIT / 2))); do
  if grep -q "Run /sbin/init as init process" "$LOG" 2>/dev/null; then READY=1; sleep 2; break; fi
  if grep -qi "Kernel panic" "$LOG" 2>/dev/null; then break; fi
  kill -0 "$QPID" 2>/dev/null || break
  sleep 2
done
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
QPID=""

echo "----- 串口日志（头 20 行） -----"
head -n 20 "$LOG" 2>/dev/null || echo "(无输出)"
echo "----- 串口日志（尾 60 行） -----"
tail -n 60 "$LOG" 2>/dev/null || echo "(无输出)"
echo "---------------------------"
echo "==> 完整日志留在: $LOG"

fail() { echo "!! $*"; exit 1; }

if grep -qi "Kernel panic" "$LOG"; then
  fail "内核 panic，镜像起不来"
fi

echo "==> 检查启动证据"
grep -q "Linux version" "$LOG" || fail "串口没看到内核启动信息（GRUB 没引导起来？）"
grep -q "Kernel command line" "$LOG" || fail "拿不到内核命令行"
grep -q "root=PARTUUID=" "$LOG" || fail "内核命令行里没有 root=PARTUUID，GRUB 配置没生效"
ok_line=$(grep -m1 "Kernel command line" "$LOG")
echo "   $ok_line"
grep -qE "EXT4-fs \((sda|sdb|hda|vda)2\): mounted filesystem" "$LOG" \
  || fail "root 分区没挂上（第 2 分区未识别或 fstab 有误）"
echo "   [OK] root 分区挂载成功"
[ "$READY" = "1" ] || fail "没走到 init（内核起来了但 rootfs 不可用）"
echo "   [OK] 已进入 /sbin/init"

echo
echo "==> 冒烟测试通过：这张盘能引导、能挂 root、能进 init"
