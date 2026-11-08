#!/usr/bin/env bash
# ============================================================
#  ImmortalWrt 25.12 x86-64 (daed) 本地构建 — .223 专用
#
#  ★ 策略（2026-11-08 起）：镜像只改管理地址，其余全部保持软件默认
#    - files/ 里只有 98-set-network：把 LAN 从 192.168.1.1 改成 192.168.2.1
#    - 不烘任何 /etc/config（acme/ddns/daed/nginx/… 全用包默认值）
#    - 不注入 wing.db / ACME 证书 / dropbear 主机密钥 / PPPoE 凭据 / root 密码
#    - 不需要 x86build-secrets 快照即可构建
#    - 只补 GEO 数据（daed 必需的数据文件，不是配置）
#
#  用法:
#    ./scripts/local-build.sh                        # 默认
#    SKIP_PULL=1 ./scripts/local-build.sh
#    PARALLEL=8 ./scripts/local-build.sh
# ============================================================
set -euo pipefail

VERSION_NAME="${VERSION_NAME:-25.12-SNAPSHOT}"
PROFILE="${PROFILE:-generic}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-daede}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"
PARALLEL="${PARALLEL:-$(nproc 2>/dev/null || echo 4)}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-/home/zhoujian/x86build-out}"
WORK="${WORK:-/home/zhoujian/x86build-work}"

IB_URL="https://downloads.immortalwrt.org/releases/${VERSION_NAME}/targets/x86/64/immortalwrt-imagebuilder-${VERSION_NAME}-x86-64.Linux-x86_64.tar.zst"
IB_ARCHIVE="$WORK/imagebuilder.tar.zst"
IB_DIR="$WORK/imagebuilder"

FW_VERSION="${FW_VERSION:-$(date +%s)}"
BUILT_AT="$(date -Iseconds)"

mkdir -p "$WORK" "$OUT_DIR"

echo "============================================================"
echo " 本地构建（.223）— 只改管理地址，其余默认"
echo "============================================================"
echo " 构建号: $FW_VERSION  ($(date -d @"$FW_VERSION" '+%F %T' 2>/dev/null || echo -))"
echo " 输出:   $OUT_DIR"
echo "============================================================"

if [ "${SKIP_PULL:-0}" != "1" ] && [ -d "$ROOT_DIR/.git" ]; then
  echo "[0/6] 更新仓库..."
  git -C "$ROOT_DIR" fetch --quiet origin 2>/dev/null || true
  git -C "$ROOT_DIR" pull --ff-only --quiet origin main 2>/dev/null || echo "  (pull 跳过)"
fi

echo "[1/6] ImageBuilder..."
if [ ! -s "$IB_ARCHIVE" ]; then
  curl -fL --retry 8 --retry-delay 5 --connect-timeout 30 -o "$IB_ARCHIVE" "$IB_URL"
else
  echo "  已缓存 ($(du -h "$IB_ARCHIVE" | cut -f1))"
fi

echo "[2/6] 解压..."
rm -rf "$IB_DIR"; mkdir -p "$IB_DIR"
tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$IB_DIR" --strip-components=1

echo "[3/6] 复制仓库 files/ ..."
rm -rf "$WORK/files"
cp -a "$ROOT_DIR/files" "$WORK/files"

# ---------- 3b. GEO 数据（每次构建取最新）----------
# 地址与 LuCI「服务 → daede → 更新」页一致（/usr/share/luci-app-daede/update-geo.sh）：
#   https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/{geoip,geosite}.dat
echo "[3b/6] 下载 GEO 数据（Loyalsoldier 最新）..."
GEO_BASE="${GEO_BASE:-https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download}"
GEO_CACHE="$WORK/geo-cache"
mkdir -p "$GEO_CACHE"
for g in geoip geosite; do
  dst="$GEO_CACHE/$g.dat"
  if curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 300 \
       -o "$dst.new" "$GEO_BASE/$g.dat" 2>/dev/null; then
    size=$(wc -c < "$dst.new")
    magic=$(od -An -tx1 -N1 "$dst.new" | tr -d ' \n')
    if [ "$size" -gt 1024 ] && [ "$magic" = "0a" ]; then
      mv "$dst.new" "$dst"
      echo "    $g.dat  ${size} 字节（新下载）"
    else
      rm -f "$dst.new"
      echo "    ⚠️ $g.dat 校验失败（size=$size magic=$magic），回退缓存"
    fi
  else
    echo "    ⚠️ $g.dat 下载失败，回退缓存"
  fi
  [ -s "$dst" ] || { echo "❌ 没有可用的 $g.dat（下载失败且无缓存）"; exit 1; }
done

# 两处放同一份：/usr/share/v2ray 是 daede 页面认的数据路径（它靠 mtime/size 判断更新完成），
# /etc/daed 是 daed 的搜索路径 —— 后两者用软链接，避免镜像里多存 28 MB
mkdir -p "$WORK/files/usr/share/v2ray" "$WORK/files/etc/daed"
cp -f "$GEO_CACHE/geoip.dat"   "$WORK/files/usr/share/v2ray/geoip.dat"
cp -f "$GEO_CACHE/geosite.dat" "$WORK/files/usr/share/v2ray/geosite.dat"
ln -sf /usr/share/v2ray/geoip.dat   "$WORK/files/etc/daed/geoip.dat"
ln -sf /usr/share/v2ray/geosite.dat "$WORK/files/etc/daed/geosite.dat"
echo "    → /usr/share/v2ray/*.dat + /etc/daed/*.dat(软链)"

# ---------- 4. uci-defaults 只留网络地址 ----------
echo "[4/6] uci-defaults 清单..."
for f in "$WORK/files/etc/uci-defaults/"*; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    98-set-network) ;;
    *) rm -f "$f" ;;
  esac
done

chmod +x "$WORK/files/etc/uci-defaults/"* 2>/dev/null || true
# 防止仓库里丢执行位（曾经因为 fw-ota 变成 644，刷完机 OTA 直接 Permission denied）
chmod 755 "$WORK/files/usr/sbin/"* 2>/dev/null || true
[ -f "$WORK/files/etc/rc.local" ] && chmod 755 "$WORK/files/etc/rc.local"
ls -1 "$WORK/files/etc/uci-defaults/" | sed 's/^/    /'

# ---------- 5. 版本戳 ----------
echo "[5/6] 版本戳..."
echo "$FW_VERSION" > "$WORK/files/etc/fw-version"
UPSTREAM_REV="$(cat "$ROOT_DIR/config/upstream-revision.txt" 2>/dev/null | tr -d '[:space:]')"
[ -z "$UPSTREAM_REV" ] && UPSTREAM_REV="unknown"
echo "$UPSTREAM_REV" > "$WORK/files/etc/fw-upstream"
echo "    fw-version  = $FW_VERSION"
echo "    fw-upstream = $UPSTREAM_REV"

# ---------- 6. 构建 ----------
echo "[6/6] 构建..."
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

# ---------- 7. 发布 ----------
echo "[7/7] 发布..."
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
echo " 自检（只改管理地址）:"
chk_has() { [ -e "$RROOT/$1" ] && echo "   ✅ $1" || echo "   ❌ $1 缺失"; }

chk_has usr/sbin/fw-ota
chk_has etc/fw-version
chk_has etc/fw-ota.conf

echo "   GEO 数据:"
for g in geoip geosite; do
  if [ -s "$RROOT/usr/share/v2ray/$g.dat" ]; then
    echo "     ✅ usr/share/v2ray/$g.dat ($(wc -c < "$RROOT/usr/share/v2ray/$g.dat") 字节)"
  else
    echo "     ❌ usr/share/v2ray/$g.dat 缺失"
  fi
  if [ -L "$RROOT/etc/daed/$g.dat" ]; then
    echo "     ✅ etc/daed/$g.dat → $(readlink "$RROOT/etc/daed/$g.dat")"
  else
    echo "     ❌ etc/daed/$g.dat 缺失"
  fi
done

echo -n "   uci-defaults: "
ls "$RROOT/etc/uci-defaults/" 2>/dev/null | tr '\n' ' '; echo

echo "   网络兜底:"
if [ -f "$RROOT/etc/uci-defaults/98-set-network" ]; then
  echo -n "     LAN: "; grep -m1 "network.lan.ipaddr" "$RROOT/etc/uci-defaults/98-set-network" | sed "s/.*='//;s/'//"
  echo -n "     设置项: "; grep -c "^uci set" "$RROOT/etc/uci-defaults/98-set-network"
else
  echo "     ❌ 缺少 98-set-network（刷完会落到 192.168.1.1）"
fi

echo "   镜像内 /etc/config（应全为包默认值）:"
ls "$RROOT/etc/config/" 2>/dev/null | tr '\n' ' '; echo
