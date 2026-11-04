#!/usr/bin/env bash
# ============================================================
#  ImmortalWrt 25.12 x86-64 (daed) 本地构建 — .223 专用
#
#  ★ 默认策略 minimal：镜像只管包，配置靠「保留配置刷机」从旧系统还原
#
#  背景：烘焙整棵 /etc/config/* 会把运行中系统的状态（dnsmasq 的 serversfile、
#  fstab 的 /dev/sda3、docker0 网络、已卸载服务残留的配置）一起带进镜像，
#  刷完直接不通。
#
#  而 sysupgrade 的「保留配置」会备份/还原 89 项（来自各包 /lib/upgrade/keep.d）：
#    /etc/config/**、/etc/daed/wing.db、/etc/acme/**、/etc/nginx/**、
#    /etc/crontabs/、/etc/rc.local、/etc/dropbear/*、/etc/shadow…
#  所以烘焙配置对 keep 刷机是无效的（备份在后、会覆盖镜像），还会被镜像里的
#  uci-defaults 在每次 OTA 后重跑一遍、把已保留的配置又盖掉。
#
#  minimal（默认）：
#    - 不烘任何 /etc/config
#    - 不注入 wing.db / ACME 证书 / dropbear 主机密钥
#    - uci-defaults 只保留 98-set-network（仅作「不保留配置」时的网络兜底：
#      LAN 192.168.2.1/24、eth1-3 桥接、eth0 PPPoE）
#  full（FIRMWARE_PROFILE=full）：恢复旧的白名单烘焙 + 全部 uci-defaults。
#
#  用法:
#    ./scripts/local-build.sh                        # minimal（默认）
#    FIRMWARE_PROFILE=full ./scripts/local-build.sh  # 旧行为：烘配置 + 全量 uci-defaults
#    SKIP_PULL=1 ./scripts/local-build.sh
# ============================================================
set -euo pipefail

VERSION_NAME="${VERSION_NAME:-25.12-SNAPSHOT}"
PROFILE="${PROFILE:-generic}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-daede}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"
PARALLEL="${PARALLEL:-$(nproc 2>/dev/null || echo 4)}"
# minimal = 只带网络兜底；full = 旧行为（烘白名单配置 + 全部 uci-defaults）
FIRMWARE_PROFILE="${FIRMWARE_PROFILE:-minimal}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-/home/zhoujian/x86build-secrets}"
OUT_DIR="${OUT_DIR:-/home/zhoujian/x86build-out}"
WORK="${WORK:-/home/zhoujian/x86build-work}"

SNAPSHOT="$SECRETS_DIR/fw-settings.tar.gz"
IB_URL="https://downloads.immortalwrt.org/releases/${VERSION_NAME}/targets/x86/64/immortalwrt-imagebuilder-${VERSION_NAME}-x86-64.Linux-x86_64.tar.zst"
IB_ARCHIVE="$WORK/imagebuilder.tar.zst"
IB_DIR="$WORK/imagebuilder"

FW_VERSION="${FW_VERSION:-$(date +%s)}"
BUILT_AT="$(date -Iseconds)"

# ★ 白名单：只在 full 模式下烘这些 uci 配置（服务凭据/参数类）
if [ "$FIRMWARE_PROFILE" = "full" ]; then
  BAKE_CONFIGS="acme ddns daed wechatpush adblock-fast banip ksmbd upnpd vlmcsd wrtbwmon nginx microsocks"
else
  BAKE_CONFIGS=""
fi

mkdir -p "$WORK" "$OUT_DIR"

echo "============================================================"
echo " 本地构建（.223）— profile: $FIRMWARE_PROFILE"
echo "============================================================"
echo " 构建号: $FW_VERSION  ($(date -d @"$FW_VERSION" '+%F %T' 2>/dev/null || echo -))"
echo " 输出:   $OUT_DIR"
echo "============================================================"

if [ "${SKIP_PULL:-0}" != "1" ] && [ -d "$ROOT_DIR/.git" ]; then
  echo "[0/9] 更新仓库..."
  git -C "$ROOT_DIR" fetch --quiet origin 2>/dev/null || true
  git -C "$ROOT_DIR" pull --ff-only --quiet origin main 2>/dev/null || echo "  (pull 跳过)"
fi

[ -s "$SNAPSHOT" ] || { echo "❌ 缺少快照: $SNAPSHOT"; exit 1; }

echo "[1/9] ImageBuilder..."
if [ ! -s "$IB_ARCHIVE" ]; then
  curl -fL --retry 8 --retry-delay 5 --connect-timeout 30 -o "$IB_ARCHIVE" "$IB_URL"
else
  echo "  已缓存 ($(du -h "$IB_ARCHIVE" | cut -f1))"
fi

echo "[2/9] 解压..."
rm -rf "$IB_DIR"; mkdir -p "$IB_DIR"
tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$IB_DIR" --strip-components=1

echo "[3/9] 复制仓库 files/ ..."
rm -rf "$WORK/files"
cp -a "$ROOT_DIR/files" "$WORK/files"

# ---------- 4. 只烘白名单内的配置 ----------
echo "[4/9] 注入白名单配置..."
rm -rf "$WORK/snapshot"; mkdir -p "$WORK/snapshot"
tar xzf "$SNAPSHOT" -C "$WORK/snapshot"
SNAP="$WORK/snapshot/fw-settings"

mkdir -p "$WORK/files/etc/config"
for c in $BAKE_CONFIGS; do
  if [ -f "$SNAP/etc/config/$c" ]; then
    cp -f "$SNAP/etc/config/$c" "$WORK/files/etc/config/$c"
    echo "    + $c"
  fi
done

if [ "$FIRMWARE_PROFILE" = "full" ]; then
# daed 数据库（订阅/节点/路由，必须烘）
if [ -f "$SNAP/etc/daed/wing.db" ]; then
  mkdir -p "$WORK/files/etc/daed"
  cp -f "$SNAP/etc/daed/wing.db" "$WORK/files/etc/daed/wing.db"
  chmod 600 "$WORK/files/etc/daed/wing.db"
  echo "    + daed/wing.db ($(du -h "$WORK/files/etc/daed/wing.db" | cut -f1))"
fi

# ACME 帐号与证书（省一次签发 + 保留 account key）
if [ -d "$SNAP/etc/acme" ]; then
  mkdir -p "$WORK/files/etc/acme"
  cp -a "$SNAP/etc/acme/." "$WORK/files/etc/acme/"
  rm -f "$WORK/files/etc/acme/"*.bak.* "$WORK/files/etc/acme/acme-sh.lock" 2>/dev/null || true
  chmod 600 "$WORK/files/etc/acme/"*/[a-z]*.key 2>/dev/null || true
  chmod 600 "$WORK/files/etc/acme/ca/"*/*/account.key 2>/dev/null || true
  echo "    + acme/ (证书 + 帐号密钥)"
fi

# dropbear 主机密钥（刷机后 SSH 指纹不变）
if [ -d "$SNAP/etc/dropbear" ]; then
  mkdir -p "$WORK/files/etc/dropbear"
  cp -a "$SNAP/etc/dropbear/." "$WORK/files/etc/dropbear/"
  chmod 600 "$WORK/files/etc/dropbear/"* 2>/dev/null || true
  echo "    + dropbear 主机密钥"
fi
else
  echo "    (minimal: 不烘 wing.db / acme / dropbear 主机密钥)"
fi

# ---------- 5. 注入凭据（PPPoE / root 密码哈希）----------
echo "[5/9] 注入凭据..."

PPP_USER=$(sed -n 's/^pppoe_user=//p' "$SNAP/META.txt" 2>/dev/null)
PPP_PASS=$(sed -n 's/^pppoe_pass=//p' "$SNAP/META.txt" 2>/dev/null)
ROOT_HASH=$(cat "$SNAP/root-password-hash.txt" 2>/dev/null | tr -d '\n\r')

for f in "$WORK/files/etc/uci-defaults/"*; do
  [ -f "$f" ] || continue
  [ -n "$PPP_USER" ] && sed -i "s|__PPPOE_USER__|$PPP_USER|g" "$f"
  [ -n "$PPP_PASS" ] && sed -i "s|__PPPOE_PASS__|$PPP_PASS|g" "$f"
done

# root 密码用 shadow 哈希（比明文更稳）—— 仅 full 模式；minimal 下首启由 LuCI 提示设置
if [ "$FIRMWARE_PROFILE" = "full" ] && [ -n "$ROOT_HASH" ]; then
  cat > "$WORK/files/etc/uci-defaults/99-set-root-password" <<EOF
#!/bin/sh
sed -i 's|^root:[^:]*:|root:${ROOT_HASH}:|' /etc/shadow
exit 0
EOF
  echo "    + root 密码哈希"
fi
echo "    + PPPoE 凭据 (${PPP_USER:-未取到})"

# ---------- 6. 保证 uci-defaults 全部可执行 ----------
echo "[6/9] uci-defaults 清单..."

# minimal：只留 98-set-network（网络兜底），其余服务初始化脚本不进镜像
# —— 否则它们会在每次 OTA 后重跑，把「保留配置」还原出来的配置又盖掉
if [ "$FIRMWARE_PROFILE" != "full" ]; then
  echo "    minimal: 只保留 98-set-network，删除其余 uci-defaults"
  for f in "$WORK/files/etc/uci-defaults/"*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      98-set-network) ;;
      *) rm -f "$f" ;;
    esac
  done
fi

chmod +x "$WORK/files/etc/uci-defaults/"* 2>/dev/null || true
ls -1 "$WORK/files/etc/uci-defaults/" | sed 's/^/    /'

# ---------- 7. 版本戳 ----------
echo "[7/9] 版本戳..."
echo "$FW_VERSION" > "$WORK/files/etc/fw-version"
UPSTREAM_REV="$(cat "$ROOT_DIR/config/upstream-revision.txt" 2>/dev/null | tr -d '[:space:]')"
[ -z "$UPSTREAM_REV" ] && UPSTREAM_REV="unknown"
echo "$UPSTREAM_REV" > "$WORK/files/etc/fw-upstream"
echo "    fw-version  = $FW_VERSION"
echo "    fw-upstream = $UPSTREAM_REV"

# ---------- 8. 构建 ----------
echo "[8/9] 构建..."
mkdir -p "$IB_DIR/packages"
if compgen -G "$ROOT_DIR/apks/*.apk" > /dev/null; then
  cp -f "$ROOT_DIR/apks/"*.apk "$IB_DIR/packages/"
  echo "    第三方 APK: $(ls -1 "$IB_DIR/packages/"*.apk | wc -l) 个"
fi

cd "$IB_DIR"
sed -i \
  -e 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' \
  -e 's/^CONFIG_TARGET_ROOTFS_TARGZ=y/# CONFIG_TARGET_ROOTFS_TARGZ is not set/' \
  -e 's/^CONFIG_VDI_IMAGES=y/# CONFIG_VDI_IMAGES is not set/' \
  -e 's/^CONFIG_VHDX_IMAGES=y/# CONFIG_VHDX_IMAGES is not set/' \
  -e 's/^CONFIG_ISO_IMAGES=y/# CONFIG_ISO_IMAGES is not set/' \
  -e 's/^CONFIG_GRUB_IMAGES=y/# CONFIG_GRUB_IMAGES is not set/' \
  .config 2>/dev/null || true

PACKAGES="$(tr '\n' ' ' < "$ROOT_DIR/config/packages.txt" | tr -s ' ')"
echo "    包数: $(echo "$PACKAGES" | wc -w)"

rm -rf "$WORK/bindir"; mkdir -p "$WORK/bindir"

BUILD_OK=0
for attempt in 1 2 3 4; do
  echo "    --- 第 $attempt 次 ---"
  if make image PROFILE="$PROFILE" PACKAGES="$PACKAGES" FILES="$WORK/files" \
      BIN_DIR="$WORK/bindir" EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME" \
      ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" -j"$PARALLEL"; then
    BUILD_OK=1; break
  fi
  echo "    ⚠️ 失败，15 秒后重试"
  sleep 15
done
[ "$BUILD_OK" = "1" ] || { echo "❌ 构建失败"; exit 1; }

# ---------- 9. 发布 ----------
echo "[9/9] 发布..."
IMG=$(ls "$WORK/bindir"/*combined-efi.img.gz 2>/dev/null | head -1)
[ -n "$IMG" ] || { echo "❌ 未找到镜像"; exit 1; }
IMG_NAME="$(basename "$IMG")"
cp -f "$IMG" "$OUT_DIR/$IMG_NAME"
cp -f "$WORK/bindir"/*.manifest "$OUT_DIR/" 2>/dev/null || true

SIZE=$(wc -c < "$OUT_DIR/$IMG_NAME" | tr -d ' ')
SHA256=$(sha256sum "$OUT_DIR/$IMG_NAME" | awk '{print $1}')
( cd "$OUT_DIR" && sha256sum "$IMG_NAME" > sha256sums )

cat > "$OUT_DIR/latest.json" <<EOF
{
  "version": $FW_VERSION,
  "built": "$BUILT_AT",
  "upstream": "$UPSTREAM_REV",
  "file": "$IMG_NAME",
  "size": $SIZE,
  "sha256": "$SHA256"
}
EOF

echo ""
echo "============================================================"
echo " ✅ 构建完成"
echo "============================================================"
echo "  镜像:   $IMG_NAME"
echo "  大小:   $((SIZE / 1024 / 1024)) MB"
echo "  sha256: $SHA256"
echo "  版本:   $FW_VERSION"
echo "============================================================"

RROOT="$IB_DIR/build_dir/target-x86_64_musl/root-x86"
echo " 自检（profile: $FIRMWARE_PROFILE）:"

chk_has() { [ -e "$RROOT/$1" ] && echo "   ✅ $1" || echo "   ❌ $1 缺失"; }
chk_gone() { [ -e "$RROOT/$1" ] && echo "   ❌ $1 不该烘进来" || echo "   ✅ $1 未烘"; }

chk_has usr/sbin/fw-ota
chk_has etc/fw-version
chk_has etc/fw-ota.conf

echo -n "   uci-defaults: "
ls "$RROOT/etc/uci-defaults/" 2>/dev/null | tr '\n' ' '; echo

if [ "$FIRMWARE_PROFILE" = "full" ]; then
  for f in etc/config/ddns etc/config/acme etc/config/daed etc/daed/wing.db etc/config/wechatpush; do
    chk_has "$f"
  done
else
  # 注意：acme/daed/ddns/nginx/microsocks 这些包的默认 /etc/config 本来就在，
  # 要判断「有没有被烘」只能跟快照比内容，不能看文件在不在
  echo "   烘焙内容（minimal 下必须等于包默认值，不能与快照一致）:"
  for c in acme ddns daed wechatpush nginx microsocks; do
    img="$RROOT/etc/config/$c"; snap="$SNAP/etc/config/$c"
    if [ ! -e "$img" ]; then
      echo "   ✅ etc/config/$c 不存在"
    elif [ -e "$snap" ] && cmp -s "$img" "$snap"; then
      echo "   ❌ etc/config/$c 与快照一致（被烘了）"
    else
      echo "   ✅ etc/config/$c 是包默认值"
    fi
  done
  [ -e "$RROOT/etc/daed/wing.db" ] && echo "   ❌ etc/daed/wing.db 被烘了" || echo "   ✅ etc/daed/wing.db 未烘"
  [ -n "$(ls -A "$RROOT/etc/acme" 2>/dev/null)" ] && echo "   ❌ etc/acme 有内容（证书被烘了）" || echo "   ✅ etc/acme 为空"
  [ -n "$(ls -A "$RROOT/etc/dropbear" 2>/dev/null)" ] && echo "   ❌ etc/dropbear 有内容（主机密钥被烘了）" || echo "   ✅ etc/dropbear 为空"
fi

echo " 网络兜底（不保留配置刷机时生效）:"
if [ -f "$RROOT/etc/uci-defaults/98-set-network" ]; then
  echo -n "   PPPoE 用户名: "
  grep -m1 "network.wan.username" "$RROOT/etc/uci-defaults/98-set-network" 2>/dev/null | sed "s/.*='//;s/'//"
  grep -q "__PPPOE" "$RROOT/etc/uci-defaults/98-set-network" 2>/dev/null \
    && echo "   ❌ 仍含 __PPPOE__ 占位符（凭据没注入）" \
    || echo "   ✅ 凭据已注入"
  echo -n "   LAN: "; grep -m1 "network.lan.ipaddr" "$RROOT/etc/uci-defaults/98-set-network" 2>/dev/null | sed "s/.*='//;s/'//"
  echo -n "   LAN 端口: "; grep -m1 "dev_lan.ports" "$RROOT/etc/uci-defaults/98-set-network" 2>/dev/null | sed "s/.*='//;s/'//"
else
  echo "   ❌ 缺少 98-set-network（不保留配置刷机后将落到 board.d 默认的 192.168.1.1）"
fi
