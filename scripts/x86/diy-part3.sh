#!/bin/bash
# diy-part3: feeds install 之后、make defconfig 之前执行（cwd = openwrt 源码根目录）
set -euo pipefail

echo "==> 1. 默认 IP 改为 192.168.2.1"
sed -i 's/192\.168\.1\.1/192.168.2.1/g' package/base-files/files/bin/config_generate
grep -n '192.168.2.1' package/base-files/files/bin/config_generate || echo "    WARN 未找到替换点"

echo "==> 2. 默认 root 密码 password"
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-set-root-password <<'EOF'
#!/bin/sh
[ -f /etc/.rootpw_done ] && exit 0
echo -e 'password\npassword' | passwd root >/dev/null 2>&1
touch /etc/.rootpw_done
exit 0
EOF
chmod +x files/etc/uci-defaults/99-set-root-password

echo "==> 3. 关闭 flow offloading（OAF 需要）+ 开启 FullCone"
cat > files/etc/uci-defaults/98-firewall-tune <<'EOF'
#!/bin/sh
# OAF 的 DPI 需要看到每个包，必须关闭软件/硬件加速
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
# NAT1 完全锥形：fw4 的 fullcone 选项（immortalwrt 原生支持）
uci set firewall.@zone[1].fullcone='1'
uci commit firewall
exit 0
EOF
chmod +x files/etc/uci-defaults/98-firewall-tune

echo "==> 4. 版本标识"
if [ -f package/base-files/files/etc/openwrt_release ]; then
  sed -i "s/DISTRIB_DESCRIPTION='*.*'/DISTRIB_DESCRIPTION='x86 N3710 NAT1 build $(date +%Y%m%d)'/g" \
    package/base-files/files/etc/openwrt_release || true
fi

echo "==> 5. 生成的自定义文件"
find files -type f | sed 's/^/    /'
echo "==> diy-part3 完成"
