#!/usr/bin/env bash
# ============================================================
#  ImmortalWrt 25.12 x86-64 (daed) 本地构建 — .223 专用
#
#  与 GitHub Actions 版 build.sh 的区别：
#    1. 把「设置快照」(fw-settings.tar.gz) 整体烘进镜像
#       —— 含 PPPoE、ACME 帐号/证书、daed wing.db、dropbear 主机密钥、
#          wechatpush key、ddns key、全部 /etc/config/*
#    2. 产物发布到 LAN HTTP 目录，供路由器内网 OTA 下载
#    3. 生成 latest.json 供 fw-ota 比对
#
#  用法:
#    ./scripts/local-build.sh              # 正常构建
#    SKIP_PULL=1 ./scripts/local-build.sh  # 不 git pull
#    NO_PUBLISH=1 ./scripts/local-build.sh # 不发布（只构建）
# ============================================================
set -euo pipefail

VERSION_NAME="${VERSION_NAME:-25.12-SNAPSHOT}"
PROFILE="${PROFILE:-generic}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-daede}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"
PARALLEL="${PARALLEL:-$(nproc 2>/dev/null || echo 4)}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-/home/zhoujian/x86build-secrets}"
OUT_DIR="${OUT_DIR:-/home/zhoujian/x86build-out}"
WORK="${WORK:-/home/zhoujian/x86build-work}"

SNAPSHOT="$SECRETS_DIR/fw-settings.tar.gz"
IB_URL="https://downloads.immortalwrt.org/releases/${VERSION_NAME}/targets/x86/64/immortalwrt-imagebuilder-${VERSION_NAME}-x86-64.Linux-x86_64.tar.zst"
IB_ARCHIVE="$WORK/imagebuilder.tar.zst"
IB_DIR="$WORK/imagebuilder"

# 版本号：epoch 秒（单调递增，fw-ota 直接数值比较）
FW_VERSION="${FW_VERSION:-$(date +%s)}"
BUILT_AT="$(date -Iseconds)"

mkdir -p "$WORK" "$OUT_DIR"

echo "============================================================"
echo " 本地构建（.223）"
echo "============================================================"
echo " 版本名:   $VERSION_NAME"
echo " Profile:  $PROFILE"
echo " 构建号:   $FW_VERSION  ($(date -d @"$FW_VERSION" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-'))"
echo " 仓库:     $ROOT_DIR"
echo " 密钥:     $SECRETS_DIR"
echo " 输出:     $OUT_DIR"
echo "============================================================"

# ---------- 0. 更新仓库 ----------
if [ "${SKIP_PULL:-0}" != "1" ] && [ -d "$ROOT_DIR/.git" ]; then
  echo "[0/9] 更新仓库..."
  git -C "$ROOT_DIR" fetch --quiet origin 2>/dev/null || true
  git -C "$ROOT_DIR" pull --ff-only --quiet origin main 2>/dev/null || echo "  (pull 跳过)"
  echo "  HEAD: $(git -C "$ROOT_DIR" log --oneline -1)"
fi

[ -s "$SNAPSHOT" ] || { echo "❌ 缺少设置快照: $SNAPSHOT"; exit 1; }

# ---------- 1. 下载 ImageBuilder ----------
if [ ! -s "$IB_ARCHIVE" ]; then
  echo "[1/9] 下载 ImageBuilder..."
  curl -fL --retry 8 --retry-delay 5 --connect-timeout 30 -o "$IB_ARCHIVE" "$IB_URL"
else
  echo "[1/9] ImageBuilder 已缓存 ($(du -h "$IB_ARCHIVE" | cut -f1))"
fi

# ---------- 2. 解压 ----------
echo "[2/9] 解压 ImageBuilder..."
rm -rf "$IB_DIR"; mkdir -p "$IB_DIR"
tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$IB_DIR" --strip-components=1

# ---------- 3. 准备 files 覆盖层 ----------
echo "[3/9] 准备 files 覆盖层..."
rm -rf "$WORK/files"
cp -a "$ROOT_DIR/files" "$WORK/files"

# ---------- 4. 烘入设置快照 ----------
echo "[4/9] 烘入设置快照..."
rm -rf "$WORK/snapshot"
mkdir -p "$WORK/snapshot"
tar xzf "$SNAPSHOT" -C "$WORK/snapshot"

SNAP_ROOT="$WORK/snapshot/fw-settings"
[ -d "$SNAP_ROOT" ] || { echo "❌ 快照结构异常"; exit 1; }

# 4a. /etc 与 /root 下的内容整体覆盖
for d in etc root; do
  [ -d "$SNAP_ROOT/$d" ] || continue
  cp -a "$SNAP_ROOT/$d/." "$WORK/files/$d/" 2>/dev/null || {
    mkdir -p "$WORK/files/$d"
    cp -a "$SNAP_ROOT/$d/." "$WORK/files/$d/"
  }
done

echo "  已覆盖:"
( cd "$SNAP_ROOT" && find . -mindepth 1 -maxdepth 2 -type d | sed 's|^\./|    |' | head -20 )

# 4b. 敏感文件权限收紧
chmod 600 "$WORK/files/etc/dropbear/"* 2>/dev/null || true
chmod 600 "$WORK/files/etc/acme/"*/[a-z]*.key 2>/dev/null || true
chmod 600 "$WORK/files/etc/acme/ca/"*/*/account.key 2>/dev/null || true
chmod 600 "$WORK/files/etc/daed/wing.db" 2>/dev/null || true

# ---------- 5. 用哈希重置 root 密码 ----------
echo "[5/9] 注入 root 密码哈希..."
HASH_FILE="$SNAP_ROOT/root-password-hash.txt"
if [ -s "$HASH_FILE" ]; then
  ROOT_HASH="$(cat "$HASH_FILE" | tr -d '\n\r')"
  cat > "$WORK/files/etc/uci-defaults/99-set-root-password" <<EOF
#!/bin/sh
# 由 local-build.sh 从路由器 /etc/shadow 提取的哈希生成
sed -i 's|^root:[^:]*:|root:${ROOT_HASH}:|' /etc/shadow
exit 0
EOF
  chmod +x "$WORK/files/etc/uci-defaults/99-set-root-password"
  echo "  ✅ 哈希已注入（${#ROOT_HASH} 字符）"
else
  echo "  ⚠️ 无密码哈希，跳过"
fi

# ---------- 6. 精简 uci-defaults ----------
echo "[6/9] 精简 uci-defaults（配置已由快照提供）..."
KEEP="99-apk-repo 99-nginx-setup 99-fw-ota 99-set-root-password"
for f in "$WORK/files/etc/uci-defaults/"*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case " $KEEP " in
    *" $b "*) echo "    keep   $b" ;;
    *)        rm -f "$f"; echo "    drop   $b" ;;
  esac
done

chmod +x "$WORK/files/etc/uci-defaults/"* 2>/dev/null || true

# ---------- 7. 版本戳 ----------
echo "[7/9] 写入版本戳..."
echo "$FW_VERSION" > "$WORK/files/etc/fw-version"
UPSTREAM_REV="$(cat "$ROOT_DIR/config/upstream-revision.txt" 2>/dev/null | tr -d '[:space:]')"
[ -z "$UPSTREAM_REV" ] && UPSTREAM_REV="unknown"
echo "$UPSTREAM_REV" > "$WORK/files/etc/fw-upstream"
echo "  fw-version  = $FW_VERSION"
echo "  fw-upstream = $UPSTREAM_REV"

# ---------- 8. 构建 ----------
echo "[8/9] 构建..."
mkdir -p "$IB_DIR/packages"
if compgen -G "$ROOT_DIR/apks/*.apk" > /dev/null; then
  cp -f "$ROOT_DIR/apks/"*.apk "$IB_DIR/packages/"
  echo "  第三方 APK: $(ls -1 "$IB_DIR/packages/"*.apk | wc -l) 个"
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
echo "  包数: $(echo "$PACKAGES" | wc -w)"

rm -rf "$WORK/bindir"; mkdir -p "$WORK/bindir"

# 包下载偶发中断（wget: exited with error 4 -> unexpected end of file）
# ImageBuilder 自身不重试，这里整体重试最多 4 次
BUILD_OK=0
for attempt in 1 2 3 4; do
  echo "  --- 第 $attempt 次尝试 ---"
  if make image \
      PROFILE="$PROFILE" \
      PACKAGES="$PACKAGES" \
      FILES="$WORK/files" \
      BIN_DIR="$WORK/bindir" \
      EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME" \
      ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" \
      -j"$PARALLEL"; then
    BUILD_OK=1
    break
  fi
  echo "  ⚠️ 第 $attempt 次失败，清理后重试…"
  rm -f "$IB_DIR"/build_dir/target-*/root-*/.pkginfo 2>/dev/null || true
  sleep 15
done

if [ "$BUILD_OK" != "1" ]; then
  echo "❌ 构建失败（已重试 4 次）"
  exit 1
fi

# ---------- 9. 发布 ----------
echo "[9/9] 发布到 LAN 目录..."
IMG=$(ls "$WORK/bindir"/*combined-efi.img.gz 2>/dev/null | head -1)
[ -n "$IMG" ] || { echo "❌ 未找到 combined-efi.img.gz"; exit 1; }

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

# 清理旧镜像（只留最近 3 个）
ls -1t "$OUT_DIR"/*combined-efi.img.gz 2>/dev/null | tail -n +4 | while read -r old; do
  echo "  清理旧镜像: $(basename "$old")"
  rm -f "$old"
done

echo ""
echo "============================================================"
echo " ✅ 构建完成"
echo "============================================================"
echo "  镜像:   $IMG_NAME"
echo "  大小:   $((SIZE / 1024 / 1024)) MB"
echo "  sha256: $SHA256"
echo "  版本:   $FW_VERSION"
echo "  上游:   $UPSTREAM_REV"
echo "  发布:   $OUT_DIR"
echo "  下载:   http://192.168.2.130:8080/$IMG_NAME"
echo "============================================================"

# ---------- 自检 ----------
RROOT="$IB_DIR/build_dir/target-x86_64_musl/root-x86"
echo " 自检:"
for f in usr/sbin/fw-ota etc/fw-version etc/config/network etc/config/ddns \
         etc/config/acme etc/daed/wing.db etc/config/wechatpush etc/nginx/nginx.conf; do
  if [ -e "$RROOT/$f" ]; then
    echo "   ✅ $f"
  else
    echo "   ❌ $f 缺失"
  fi
done
MAN=$(ls "$WORK/bindir"/*.manifest 2>/dev/null | head -1)
[ -n "$MAN" ] && echo "   包总数: $(wc -l < "$MAN")"
