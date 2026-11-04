#!/usr/bin/env bash
# ============================================================
#  在 .223 安装：LAN HTTP 服务 + 上游检测 timer
#  用法: sudo bash scripts/install-223-services.sh
# ============================================================
set -euo pipefail

REPO_DIR="/home/zhoujian/x86build"
OUT_DIR="/home/zhoujian/x86build-out"
BIND_IP="192.168.2.130"
PORT="8080"

[ "$(id -u)" = "0" ] || { echo "需要 root: sudo bash $0"; exit 1; }
mkdir -p "$OUT_DIR"

# --- HTTP 服务 ---
cat > /etc/systemd/system/x86build-http.service <<EOF
[Unit]
Description=x86build LAN HTTP (固件 OTA 下载)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=zhoujian
WorkingDirectory=$OUT_DIR
ExecStart=/usr/bin/python3 -m http.server $PORT --bind $BIND_IP --directory $OUT_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# --- 上游检测 ---
cat > /etc/systemd/system/x86build-upstream.service <<EOF
[Unit]
Description=x86build 上游更新检测
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=zhoujian
WorkingDirectory=$REPO_DIR
ExecStart=/usr/bin/env bash $REPO_DIR/scripts/check-upstream.sh
TimeoutStartSec=3600
EOF

cat > /etc/systemd/system/x86build-upstream.timer <<EOF
[Unit]
Description=x86build 上游更新检测（每 6 小时）

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

chmod +x "$REPO_DIR/scripts/local-build.sh" "$REPO_DIR/scripts/check-upstream.sh"

systemctl daemon-reload
systemctl enable --now x86build-http.service
systemctl enable --now x86build-upstream.timer

echo "✅ 已安装："
systemctl is-active x86build-http.service   | sed 's/^/  http.service: /'
systemctl is-active x86build-upstream.timer | sed 's/^/  upstream.timer: /'
echo "  HTTP: http://$BIND_IP:$PORT/"