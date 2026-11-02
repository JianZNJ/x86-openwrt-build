#!/bin/bash
# diy-part3: feeds install 之后、make defconfig 之前执行（cwd = openwrt 源码根目录）
set -euo pipefail

echo "==> 1. 默认 IP 改为 192.168.2.1"
sed -i 's/192\.168\.1\.1/192.168.2.1/g' package/base-files/files/bin/config_generate
grep -n '192.168.2.1' package/base-files/files/bin/config_generate || echo "    WARN 未找到替换点"

mkdir -p files/etc/uci-defaults

echo "==> 2. 默认 root 密码 Za831021."
cat > files/etc/uci-defaults/99-set-root-password <<'EOF'
#!/bin/sh
[ -f /etc/.rootpw_done ] && exit 0
echo -e 'Za831021.\nZa831021.' | passwd root >/dev/null 2>&1
touch /etc/.rootpw_done
exit 0
EOF
chmod +x files/etc/uci-defaults/99-set-root-password

echo "==> 3. 网络拓扑：eth0=WAN(PPPoE)，eth1-3=LAN 桥接"
cat > files/etc/uci-defaults/97-network <<'EOF'
#!/bin/sh
# ---------- WAN: eth0, PPPoE ----------
uci -q set network.wan=interface
uci -q set network.wan.device='eth0'
uci -q set network.wan.proto='pppoe'
uci -q set network.wan.username='njkd107257593'
uci -q set network.wan.password='84318564'
uci -q set network.wan.ipv6='0'

uci -q set network.wan6=interface
uci -q set network.wan6.device='eth0'
uci -q set network.wan6.proto='dhcpv6'
uci -q set network.wan6.auto='0'

# ---------- LAN: br-lan, 192.168.2.1 ----------
uci -q set network.lan.device='br-lan'
uci -q set network.lan.proto='static'
uci -q set network.lan.ipaddr='192.168.2.1'
uci -q set network.lan.netmask='255.255.255.0'
uci -q delete network.lan.ip6assign

# ---------- br-lan 桥接 eth1/eth2/eth3 ----------
existing=$(uci -q get network.@device[0].name || true)
if [ "$existing" = "br-lan" ]; then
    uci -q delete network.@device[0].ports
    dev="network.@device[0]"
else
    sec=$(uci add network device)
    uci -q set "network.$sec.name"='br-lan'
    uci -q set "network.$sec.type"='bridge'
    dev="network.$sec"
fi
uci -q add_list "$dev.ports"='eth1'
uci -q add_list "$dev.ports"='eth2'
uci -q add_list "$dev.ports"='eth3'

uci -q commit network
exit 0
EOF
chmod +x files/etc/uci-defaults/97-network

echo "==> 4. 启用 KMS 服务（vlmcsd，TCP 1688）"
cat > files/etc/uci-defaults/96-vlmcsd <<'EOF'
#!/bin/sh
[ -x /etc/init.d/vlmcsd ] || exit 0
uci -q set vlmcsd.config.enabled='1'
uci -q set vlmcsd.config.autoactivate='1'
uci commit vlmcsd
/etc/init.d/vlmcsd enable
/etc/init.d/vlmcsd restart
exit 0
EOF
chmod +x files/etc/uci-defaults/96-vlmcsd

echo "==> 5. 开启 flow offloading（OAF 已移除）+ 开启 FullCone"
cat > files/etc/uci-defaults/98-firewall-tune <<'EOF'
#!/bin/sh
# OAF 已移除，不再需要为 DPI 让路
# OAF 已移除，开启软件流转发加速（性能最大化）
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='0'
# NAT1 完全锥形（immortalwrt 原生支持）
uci set firewall.@zone[1].fullcone='1'
uci commit firewall
exit 0
EOF
chmod +x files/etc/uci-defaults/98-firewall-tune

echo "==> 6. 版本标识 + 构建号"
if [ -f package/base-files/files/etc/openwrt_release ]; then
  sed -i "s/DISTRIB_DESCRIPTION='*.*'/DISTRIB_DESCRIPTION='x86 N3710 NAT1 build $(date +%Y%m%d)'/g" \
    package/base-files/files/etc/openwrt_release || true
fi
mkdir -p files/etc
echo "${GITHUB_RUN_NUMBER:-0}" > files/etc/fw-version
echo "    构建号: $(cat files/etc/fw-version)"

echo "==> 7. 安装 OTA 工具 fw-ota"
mkdir -p files/usr/sbin
install -m 0755 "$GITHUB_WORKSPACE/scripts/x86/fw-ota.sh" files/usr/sbin/fw-ota
echo "    $(wc -c < files/usr/sbin/fw-ota) 字节"

echo "==> 8. 每周检查更新（只检查，不自动刷）"
mkdir -p files/etc/crontabs
cat > files/etc/crontabs/root <<'EOF'
# 每周六 04:00 检查固件更新，结果写入 /var/log/fw-ota.log
0 4 * * 6 /usr/sbin/fw-ota check >> /var/log/fw-ota.log 2>&1
EOF
chmod 600 files/etc/crontabs/root

echo "==> 9. 预置 OpenClash 内核（mihomo meta, linux-amd64）"
mkdir -p files/etc/openclash/core
CORE_TMP=$(mktemp -d)
CORE_OK=0
for u in \
  "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" \
  "https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/meta/clash-linux-amd64-compatible.tar.gz" \
  "https://ghproxy.net/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" \
  "https://mirror.ghproxy.com/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" ; do
  echo "    trying: $u"
  if curl -fsSL --retry 2 --connect-timeout 20 --max-time 180 -o "$CORE_TMP/core.tar.gz" "$u"; then
    CORE_OK=1
    echo "    downloaded from: $u"
    break
  fi
done
if [ "$CORE_OK" = "1" ]; then
  if tar -xzf "$CORE_TMP/core.tar.gz" -C "$CORE_TMP" && [ -f "$CORE_TMP/clash" ]; then
    install -m 0755 "$CORE_TMP/clash" files/etc/openclash/core/clash_meta
    echo "    内核已安装: $(du -h files/etc/openclash/core/clash_meta | cut -f1)"
  else
    echo "    WARN 解压失败或未找到 clash 二进制，跳过"
  fi
else
  echo "    WARN 内核下载失败，跳过（首次启动需在 UI 手动下载）"
fi
rm -rf "$CORE_TMP"

echo "==> 10. 生成的自定义文件"
find files -type f | sed 's/^/    /'
echo "==> diy-part3 完成"
# ============================================================
# SECURITY-PRESET: banip / adblock-fast / WireGuard 固化为出厂配置
# ============================================================
echo "==> Preset banip"
cat > files/etc/uci-defaults/90-banip <<'EOF'
#!/bin/sh
uci set banip.global.ban_enabled=1
uci set banip.global.ban_autodetect=1
uci set banip.global.ban_logchain=1
uci set banip.global.ban_icmplimit=10
uci set banip.global.ban_synlimit=10
uci set banip.global.ban_nftexpiry=1d
uci set banip.global.ban_logexpiry=1d
uci -q delete banip.global.ban_feed
uci add_list banip.global.ban_feed=dshield
uci add_list banip.global.ban_feed=threat
uci add_list banip.global.ban_feed=greensnow
uci add_list banip.global.ban_feed=firehol1
uci -q delete banip.global.ban_logterm
uci add_list banip.global.ban_logterm='Exit before auth from'
uci add_list banip.global.ban_logterm='luci: failed login'
uci add_list banip.global.ban_logterm='error: maximum authentication attempts exceeded'
uci add_list banip.global.ban_logterm='pam_unix(sshd:auth): authentication failure'
uci commit banip
/etc/init.d/banip enable
/etc/init.d/banip restart
exit 0
EOF
chmod +x files/etc/uci-defaults/90-banip

echo "==> Preset adblock-fast"
cat > files/etc/uci-defaults/91-adblock <<'EOF'
#!/bin/sh
uci set adblock-fast.config.enabled=1
for i in 0 1 2 3 4 5 6 7 8; do
  uci -q get adblock-fast.@file_url[$i] >/dev/null 2>&1 && uci set adblock-fast.@file_url[$i].enabled=1
done
for i in 0 1 2 3 4 5 6 7 8; do
  uci -q get adblock-fast.@domains[$i] >/dev/null 2>&1 && uci set adblock-fast.@domains[$i].enabled=1
done
uci commit adblock-fast
/etc/init.d/adblock-fast enable
exit 0
EOF
chmod +x files/etc/uci-defaults/91-adblock

echo "==> Preset WireGuard (wg0 server + one client)"
cat > files/etc/uci-defaults/92-wireguard <<EOF
#!/bin/sh
uci -q delete network.wg0
uci set network.wg0=interface
uci set network.wg0.proto=wireguard
uci set network.wg0.private_key='${WG_SRV_PRIV}'
uci set network.wg0.listen_port=51820
uci add_list network.wg0.addresses=10.88.0.1/24
uci -q delete network.wgclient
uci set network.wgclient=wireguard_wg0
uci set network.wgclient.description=phone
uci set network.wgclient.public_key='${WG_CLI_PUB}'
uci set network.wgclient.preshared_key='${WG_PSK}'
uci add_list network.wgclient.allowed_ips=10.88.0.2/32
uci commit network
uci -q delete firewall.wg
uci set firewall.wg=zone
uci set firewall.wg.name=wg
uci set firewall.wg.input=ACCEPT
uci set firewall.wg.output=ACCEPT
uci set firewall.wg.forward=ACCEPT
uci set firewall.wg.masq=1
uci set firewall.wg.network=wg0
uci -q delete firewall.wg_fwd
uci set firewall.wg_fwd=forwarding
uci set firewall.wg_fwd.src=wg
uci set firewall.wg_fwd.dest=wan
uci -q delete firewall.wg_allow
uci set firewall.wg_allow=rule
uci set firewall.wg_allow.name=Allow-WireGuard
uci set firewall.wg_allow.src=wan
uci set firewall.wg_allow.proto=udp
uci set firewall.wg_allow.dest_port=51820
uci set firewall.wg_allow.target=ACCEPT
# WireGuard 到局域网的双向转发（关键：否则 VPN 客户端只能访问路由器，访问不了内网设备）
uci -q delete firewall.wg_lan
uci set firewall.wg_lan=forwarding
uci set firewall.wg_lan.src=wg
uci set firewall.wg_lan.dest=lan
uci -q delete firewall.lan_to_wg
uci set firewall.lan_to_wg=forwarding
uci set firewall.lan_to_wg.src=lan
uci set firewall.lan_to_wg.dest=wg
uci commit firewall
exit 0
EOF
chmod +x files/etc/uci-defaults/92-wireguard
# ============================================================
# OTA-UI: fw-ota 的 LuCI 界面
# ============================================================
echo "==> Install fw-ota LuCI page"
mkdir -p files/usr/share/luci/menu.d files/usr/share/rpcd/acl.d files/www/luci-static/resources/view
cat > files/usr/share/luci/menu.d/luci-app-fw-ota.json <<'EOF'
{
	"admin/system/fw-ota": {
		"title": "固件升级 (OTA)",
		"order": 60,
		"action": {
			"type": "view",
			"path": "fw-ota"
		},
		"depends": {
			"acl": [ "luci-app-fw-ota" ]
		}
	}
}
EOF
cat > files/usr/share/rpcd/acl.d/luci-app-fw-ota.json <<'EOF'
{
	"luci-app-fw-ota": {
		"description": "Grant access to fw-ota",
		"read": {
			"file": {
				"/usr/sbin/fw-ota": [ "exec" ]
			}
		},
		"write": {
			"file": {
				"/usr/sbin/fw-ota": [ "exec" ]
			}
		}
	}
}
EOF
# 从仓库拷贝 fw-ota 的 LuCI 界面（含下载进度条）
install -m 0644 "$GITHUB_WORKSPACE/scripts/x86/fw-ota.js" files/www/luci-static/resources/view/fw-ota.js
echo "    fw-ota.js $(wc -c < files/www/luci-static/resources/view/fw-ota.js) 字节"
chmod 644 files/usr/share/luci/menu.d/luci-app-fw-ota.json files/usr/share/rpcd/acl.d/luci-app-fw-ota.json files/www/luci-static/resources/view/fw-ota.js
# ============================================================
# NLBWMON-FIX: netlink 缓冲不足导致 "No buffer space available"
# 根因: nlbwmon 请求 512KB 缓冲，但 net.core.rmem_max 默认只有 208KB
# ============================================================
echo "==> nlbwmon netlink buffer fix"
mkdir -p files/etc/sysctl.d
cat > files/etc/sysctl.d/99-nlbwmon.conf <<'EOF'
# nlbwmon netlink 缓冲修复（默认 rmem_max 208KB 不足以容纳 nlbwmon 的 512KB 请求）
net.core.rmem_max = 4194304
net.core.rmem_default = 524288
net.core.netdev_max_backlog = 4096
EOF

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/93-nlbwmon <<'EOF'
#!/bin/sh
# 降低 conntrack dump 频率，减轻 netlink 压力
uci -q set nlbwmon.@nlbwmon[0].refresh_interval='120'
uci -q set nlbwmon.@nlbwmon[0].netlink_buffer_size='1048576'
uci commit nlbwmon
/etc/init.d/nlbwmon restart >/dev/null 2>&1
exit 0
EOF
chmod +x files/etc/uci-defaults/93-nlbwmon
# ============================================================
# WG_KEY_CHECK: 校验密钥确实被注入（否则 heredoc 引号问题会静默失败）
# ============================================================
if grep -q '\${WG_SRV_PRIV}' files/etc/uci-defaults/92-wireguard 2>/dev/null; then
  echo "    ERROR: WG_SRV_PRIV 未被替换！heredoc 引号有问题"
  echo "    请检查 GitHub Secrets 是否配置"
else
  echo "    WireGuard 密钥注入 OK"
fi
# ============================================================
# adblock-fast-ACL: 补 /etc/crontabs/root 的 file 权限
# 原因: luci-app-adblock-fast 的 ACL 缺 file 权限，导致网页里
#       "定时更新" 保存失败（syncCron 需要写 crontab）
# ============================================================
echo "==> adblock-fast ACL fix"
ACL_ADB=/usr/share/rpcd/acl.d/luci-app-adblock-fast.json
# 在构建目录里预置补丁后的 ACL（只有包存在时才生效）
mkdir -p files/usr/share/rpcd/acl.d
if [ -f "$BUILD_DIR/package/luci-app-adblock-fast/root/usr/share/rpcd/acl.d/luci-app-adblock-fast.json" ] 2>/dev/null; then
  SRC="$BUILD_DIR/package/luci-app-adblock-fast/root/usr/share/rpcd/acl.d/luci-app-adblock-fast.json"
elif [ -f "feeds/luci/applications/luci-app-adblock-fast/root/usr/share/rpcd/acl.d/luci-app-adblock-fast.json" ]; then
  SRC="feeds/luci/applications/luci-app-adblock-fast/root/usr/share/rpcd/acl.d/luci-app-adblock-fast.json"
else
  SRC=""
fi
if [ -n "$SRC" ] && [ -f "$SRC" ]; then
  python3 - "$SRC" files/usr/share/rpcd/acl.d/luci-app-adblock-fast.json <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
key = list(d.keys())[0]
d[key].setdefault('read', {}).setdefault('file', {})['/etc/crontabs/root'] = ['read']
d[key].setdefault('write', {}).setdefault('file', {})['/etc/crontabs/root'] = ['write']
json.dump(d, open(dst, 'w'), indent=1, ensure_ascii=False)
print("    ACL patched ->", dst)
PYEOF
else
  echo "    跳过：找不到 luci-app-adblock-fast 的 ACL 源文件"
fi

# ============================================================
# nlbwmon 已完成；此处顺带设置 adblock-fast 的下载超时
# ============================================================
# ============================================================
# adblock-fast-TIMEOUT: 默认 10 秒下载超时太短
# AdguardTeam CNAME 列表有 9.6MB，GitHub 慢时下不完
# ============================================================
echo "==> adblock-fast download timeout"
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/94-adblock-timeout <<'EOF'
#!/bin/sh
uci -q set adblock-fast.config.download_timeout='60'
uci -q set adblock-fast.config.download_connect_timeout='20'
uci -q set adblock-fast.config.curl_retry='5'
uci -q set adblock-fast.config.curl_max_file_size='50000000'
# 延迟启动，避免首启时下载列表阻塞 LuCI（adblock-fast 的 ubus handler 会被锁住）
uci -q set adblock-fast.config.start_delay='60'
uci commit adblock-fast
exit 0
EOF
chmod +x files/etc/uci-defaults/94-adblock-timeout
