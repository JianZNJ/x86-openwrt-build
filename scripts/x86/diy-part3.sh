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
CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
mkdir -p files/etc/openclash/core
CORE_TMP=$(mktemp -d)
if curl -fsSL --retry 3 --connect-timeout 20 -o "$CORE_TMP/core.tar.gz" "$CORE_URL"; then
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
