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

echo "==> 5. 关闭 flow offloading（OAF 需要）+ 开启 FullCone"
cat > files/etc/uci-defaults/98-firewall-tune <<'EOF'
#!/bin/sh
# OAF 的 DPI 需要看到每个包，必须关闭软件/硬件加速
uci set firewall.@defaults[0].flow_offloading='0'
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
cat > files/etc/uci-defaults/92-wireguard <<'EOF'
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
cat > files/www/luci-static/resources/view/fw-ota.js <<'EOF'
'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return fs.exec('/usr/sbin/fw-ota', [ 'version' ]).catch(function() {
			return { stdout: '', stderr: '' };
		});
	},

	handleRun: function(arg) {
		var node = document.getElementById('ota-out');
		node.textContent = '执行中，请稍候...';
		return fs.exec('/usr/sbin/fw-ota', [ arg ]).then(function(res) {
			node.textContent = (res.stdout || '') + (res.stderr ? '\n' + res.stderr : '');
		}).catch(function(e) {
			node.textContent = '执行失败: ' + e.message;
		});
	},

	render: function(res) {
		var self = this;
		var ver = (res.stdout || '').trim() || '未知';

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('固件 OTA 升级')),
			E('div', { 'class': 'cbi-map-descr' },
				_('从 GitHub Release 检查并升级固件。升级会重启设备，请确保网络稳定。')),

			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ E('strong', {}, _('当前版本：')), ver ]),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, 'handleRun', 'check')
					}, [ _('检查更新') ]),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(self, 'handleRun', 'update')
					}, [ _('立即升级并重启') ])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('输出')),
				E('pre', {
					'id': 'ota-out',
					'style': 'white-space:pre-wrap;background:#f5f5f5;padding:10px;border-radius:4px;min-height:80px'
				}, [ '' ])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
EOF
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