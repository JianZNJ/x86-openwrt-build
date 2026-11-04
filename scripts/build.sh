#!/usr/bin/env bash
# ============================================================
#  ImmortalWrt 25.12 x86-64 (daed) ImageBuilder 构建脚本
#  本地与 GitHub Actions 通用
# ============================================================
set -euo pipefail

VERSION="${VERSION:-25.12-SNAPSHOT}"
PROFILE="${PROFILE:-generic}"
OUT="${OUT:-$PWD/out}"
WORK="${WORK:-$PWD/work}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-daede}"
PARALLEL="${PARALLEL:-$(nproc 2>/dev/null || echo 4)}"

IB_URL="${IB_URL:-https://downloads.immortalwrt.org/releases/${VERSION}/targets/x86/64/immortalwrt-imagebuilder-${VERSION}-x86-64.Linux-x86_64.tar.zst}"

# 凭据（GitHub Secrets 注入；本地构建可直接 export）
PPPOE_USER="${PPPOE_USER:-pppoe}"
PPPOE_PASS="${PPPOE_PASS:-pppoe}"
ROOT_PASS="${ROOT_PASS:-openwrt}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IB_DIR="$WORK/imagebuilder"
IB_ARCHIVE="$WORK/imagebuilder.tar.zst"

mkdir -p "$WORK" "$OUT"

echo "============================================================"
echo " 版本:     $VERSION"
echo " Profile:  $PROFILE"
echo " 根分区:   ${ROOTFS_PARTSIZE} MB"
echo " 输出:     $OUT"
echo "============================================================"

# ---------- 1. 下载 ImageBuilder ----------
if [ ! -s "$IB_ARCHIVE" ]; then
  echo "[1/6] 下载 ImageBuilder..."
  curl -fL --retry 8 --retry-delay 5 --connect-timeout 30 -o "$IB_ARCHIVE" "$IB_URL"
else
  echo "[1/6] ImageBuilder 已缓存"
fi
ls -lh "$IB_ARCHIVE"

# ---------- 2. 解压 ----------
echo "[2/6] 解压..."
rm -rf "$IB_DIR"
mkdir -p "$IB_DIR"
tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$IB_DIR" --strip-components=1

# ---------- 3. 准备 files 覆盖层（注入凭据） ----------
echo "[3/6] 准备 files 覆盖层..."
rm -rf "$WORK/files"
cp -a "$ROOT_DIR/files" "$WORK/files"

subst() {
  # $1=文件  $2=占位符  $3=值
  sed -i "s|$2|$3|g" "$1"
}
for f in "$WORK/files/etc/uci-defaults/"*; do
  [ -f "$f" ] || continue
  subst "$f" "__PPPOE_USER__" "$PPPOE_USER"
  subst "$f" "__PPPOE_PASS__" "$PPPOE_PASS"
  subst "$f" "__ROOT_PASS__"  "$ROOT_PASS"
done
[ -n "${WG_SRV_PRIV:-}" ] && echo "  (未使用 WireGuard 自动化)"

chmod +x "$WORK/files/etc/uci-defaults/"* 2>/dev/null || true

# 写入构建号（OTA 版本比对用）
BUILD_NUM="${GITHUB_RUN_NUMBER:-0}"
echo "$BUILD_NUM" > "$WORK/files/etc/fw-version"
echo "  构建号 fw-version = $BUILD_NUM"
chmod 644 "$WORK/files/etc/fw-version"
# 上游版本戳（ImmortalWrt 构建号）
UPSTREAM_REV="$(cat "$ROOT_DIR/config/upstream-revision.txt" 2>/dev/null | tr -d '[:space:]')"
[ -z "$UPSTREAM_REV" ] && UPSTREAM_REV="unknown"
echo "$UPSTREAM_REV" > "$WORK/files/etc/fw-upstream"
echo "  上游版本 fw-upstream = $UPSTREAM_REV"
chmod 644 "$WORK/files/etc/fw-upstream"

# ---------- 4. 加入第三方 APK ----------
echo "[4/6] 加入第三方 APK..."
mkdir -p "$IB_DIR/packages"
if compgen -G "$ROOT_DIR/apks/*.apk" > /dev/null; then
  cp -f "$ROOT_DIR/apks/"*.apk "$IB_DIR/packages/"
  ls -1 "$IB_DIR/packages/"*.apk | sed 's|.*/|  + |'
else
  echo "  警告：apks/ 为空"
fi

# ---------- 5. 精简镜像格式（只留 squashfs-efi） ----------
echo "[5/6] 精简镜像格式..."
cd "$IB_DIR"
sed -i \
  -e 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' \
  -e 's/^CONFIG_TARGET_ROOTFS_TARGZ=y/# CONFIG_TARGET_ROOTFS_TARGZ is not set/' \
  -e 's/^CONFIG_VDI_IMAGES=y/# CONFIG_VDI_IMAGES is not set/' \
  -e 's/^CONFIG_VHDX_IMAGES=y/# CONFIG_VHDX_IMAGES is not set/' \
  -e 's/^CONFIG_ISO_IMAGES=y/# CONFIG_ISO_IMAGES is not set/' \
  -e 's/^CONFIG_GRUB_IMAGES=y/# CONFIG_GRUB_IMAGES is not set/' \
  .config 2>/dev/null || true

# ---------- 6. 构建 ----------
echo "[6/6] 构建..."
PACKAGES="$(tr '\n' ' ' < "$ROOT_DIR/config/packages.txt" | tr -s ' ')"
echo "  包数: $(echo "$PACKAGES" | wc -w)"

make image \
  PROFILE="$PROFILE" \
  PACKAGES="$PACKAGES" \
  FILES="$WORK/files" \
  BIN_DIR="$OUT" \
  EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME" \
  ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" \
  -j"$PARALLEL"

echo ""
echo "============================================================"
echo " 构建完成"
echo "============================================================"
ls -lh "$OUT" | grep -vE '^total|^d'
echo ""
if [ -f "$OUT/sha256sums" ]; then
  ( cd "$OUT" && sha256sum -c sha256sums --ignore-missing 2>&1 | tail -5 ) || true
fi

# ---------- 7. 验证凭据已注入 ----------
echo "[7/7] 验证凭据注入..."
CHK="$IB_DIR/build_dir/target-x86_64_musl/root-x86/etc/uci-defaults/98-set-network"
if [ -f "$CHK" ]; then
  if grep -q '__PPPOE_USER__' "$CHK"; then
    echo "  ❌ 凭据未注入：占位符仍存在（请检查 Secrets）"
    exit 1
  fi
  echo "  ✅ PPPoE 凭据已注入"
  grep -c "option\|uci set network.wan" "$CHK" >/dev/null 2>&1 || true
else
  echo "  ⚠️ 未找到 staging rootfs，跳过验证"
fi

CHKPW="$IB_DIR/build_dir/target-x86_64_musl/root-x86/etc/uci-defaults/99-set-root-password"
if [ -f "$CHKPW" ]; then
  grep -q '__ROOT_PASS__' "$CHKPW" && { echo "  ❌ root 密码未注入"; exit 1; }
  echo "  ✅ root 密码已注入"
fi

# ---------- 8. 校验 daed 关键包 ----------
echo "[8/8] 校验关键包..."
MAN=$(ls "$OUT"/*.manifest 2>/dev/null | head -1)
if [ -n "$MAN" ]; then
  for p in dae daed luci-app-daede lucky wrtbwmon luci-app-wechatpush kmod-nft-fullcone; do
    if grep -qE "^\s*$p\s+-" "$MAN"; then
      echo "  ✅ $p"
    else
      echo "  ❌ $p 缺失"
    fi
  done
  echo "  包总数: $(wc -l < "$MAN")"
fi

# ---------- 9. 校验 OTA 组件 ----------
echo "[9/9] 校验 OTA 组件..."
RROOT="$IB_DIR/build_dir/target-x86_64_musl/root-x86"
for f in \
  "usr/sbin/fw-ota" \
  "www/luci-static/resources/view/fw-ota.js" \
  "usr/share/luci/menu.d/luci-app-fw-ota.json" \
  "usr/share/rpcd/acl.d/luci-app-fw-ota.json" \
  "etc/fw-version" ; do
  if [ -e "$RROOT/$f" ]; then
    echo "  ✅ $f"
  else
    echo "  ❌ $f 缺失"
  fi
done
[ -f "$RROOT/etc/fw-version" ] && echo "  fw-version = $(cat "$RROOT/etc/fw-version")"