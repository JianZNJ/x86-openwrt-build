#!/usr/bin/env bash
# 在 .223 提供 x86build-out 的 LAN HTTP 服务（8080）。
# 幂等：已在监听则直接退出；供 cron @reboot 与每分钟巡检调用。
OUT=/home/zhoujian/x86build-out
IP=192.168.2.130
PORT=8080
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p "$OUT"
if ss -lnt 2>/dev/null | grep -q "[.:]$PORT "; then
	exit 0
fi
cd "$OUT" || exit 1
setsid nohup /usr/bin/python3 -m http.server "$PORT" --bind "$IP" --directory "$OUT" \
	>> "$OUT/http.log" 2>&1 < /dev/null &
exit 0
