#!/bin/sh
# Alpine 初始化脚本 —— 在 Wyse 5070 的 Alpine 根分区里跑一次
# 用法：chroot 进根分区后执行  sh -e /alpine-setup.sh
set -e

echo "==> 1. apk 镜像源（阿里云）"
sed -i 's|^#community|community|' /etc/apk/repositories
sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories
apk update && apk upgrade

echo "==> 2. 基础软件包"
apk add openrc e2fsprogs iptables curl wget tzdata

echo "==> 3. 图形/音频/固件"
apk add mesa mesa-va-gallium intel-media-driver linux-firmware-i915 \
        pipewire pipewire-pulse wireplumber \
        cage greetd sway

echo "==> 4. Waydroid"
apk add waydroid waydroid-openrc
rc-update add waydroid-container default

echo "==> 5. 时区与主机名"
setup-timezone -z Asia/Shanghai
echo wyse5070 > /etc/hostname

echo "==> 6. kiosk 用户（cage 以它跑）"
adduser -D -s /bin/sh kiosk || true
echo 'kiosk:kiosk' | chpasswd
# 用户服务：pipewire / waydroid session 归 kiosk
mkdir -p /home/kiosk/.config
cat > /home/kiosk/.profile <<'EOF'
# cage kiosk：起 pipewire + waydroid 会话，再全屏
exec cage /usr/local/bin/start_mytv.sh
EOF
chown -R kiosk:kiosk /home/kiosk

echo "==> 7. 启动脚本"
cat > /usr/local/bin/start_mytv.sh <<'EOF'
#!/bin/sh
# 等待 waydroid 容器就绪
until waydroid status 2>/dev/null | grep -q "Android with user 0 is ready"; do
    sleep 2
done
# 会话与容器须同用户态可用；session 后台起
waydroid session start >/dev/null 2>&1 &
sleep 3
waydroid prop set persist.waydroid.multi_windows false
waydroid app launch com.mytv.tv
EOF
chmod +x /usr/local/bin/start_mytv.sh

echo "==> 8. tty1 自动登录 kiosk 并进 cage"
# OpenRC 下改 inittab 第一行
sed -i 's|^tty1:.*|tty1::respawn:/sbin/agetty --autologin kiosk --noclear tty1 linux|' /etc/inittab

echo "==> 9. Waydroid 首次初始化（不带谷歌套件）"
# 需要 waydroid-container 已启动；chroot 环境下跳过，改为首启执行
cat > /etc/local.d/waydroid-init.firstboot <<'EOF'
#!/bin/sh
rc-service waydroid-container start
sleep 5
waydroid init -s GAPPS_OFFLINE 2>/dev/null || waydroid init
EOF
chmod +x /etc/local.d/waydroid-init.firstboot
rc-update add local default

echo "==> 10. MyTV APK 安装提示"
cat <<'EOF'

------------------------------------------------------------
初始化完成。首次开机进系统后（网络通了）执行一次：
  rc-service waydroid-container start
  waydroid init          # 下载 Android 镜像
  wget https://gitee.com/mytv-android/mytvbeta/releases/download/v3.0.0.235/mytv-android-tv-3.0.0.235-x86_64-sdk23-original.apk
  waydroid app install mytv-android-tv-3.0.0.235-x86_64-sdk23-original.apk

MyTV 配置：
  M3U: shturl.cc/ftaYXKQI4tSUsFZ0RCiyGWtz
  EPG: http://epg.51zmt.top:8000/api/epg.xml
------------------------------------------------------------
EOF
