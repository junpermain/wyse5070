#!/bin/sh
# 由 cage 拉起：等容器就绪 → 起会话 → 全屏启动 MyTV
until waydroid status 2>/dev/null | grep -q "Android with user 0 is ready"; do
    sleep 2
done
waydroid session start >/dev/null 2>&1 &
sleep 3
waydroid prop set persist.waydroid.multi_windows false
waydroid app launch com.mytv.tv
