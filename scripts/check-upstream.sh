#!/usr/bin/env bash
# ============================================================
#  上游 ImmortalWrt 更新检测 — .223 专用
#
#  对比 downloads.immortalwrt.org 的 version.buildinfo
#  与仓库 config/upstream-revision.txt，变化则触发本地构建。
#
#  由 systemd timer 每 6 小时调用一次。
# ============================================================
set -euo pipefail

REPO_DIR="/home/zhoujian/x86build"
OUT_DIR="/home/zhoujian/x86build-out"
LOG="/home/zhoujian/x86build-out/upstream-check.log"
STAMP="$OUT_DIR/.upstream-rev"
URL="https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/targets/x86/64/version.buildinfo"

mkdir -p "$OUT_DIR"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# 只保留最近 500 行日志
[ -f "$LOG" ] && tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

REMOTE=$(curl -fsSL --max-time 60 "$URL" 2>/dev/null | sed -n 's/^REVISION=//p' | tr -d '"[:space:]')
if [ -z "$REMOTE" ]; then
    log "拉取上游 version.buildinfo 失败，跳过"
    exit 0
fi
log "上游版本: $REMOTE"

LOCAL=$(cat "$STAMP" 2>/dev/null || echo "")
if [ "$REMOTE" = "$LOCAL" ]; then
    log "无变化（$REMOTE）"
    exit 0
fi

log "检测到上游更新: ${LOCAL:-<空>} -> $REMOTE"

# 更新仓库里的版本戳
echo "$REMOTE" > "$REPO_DIR/config/upstream-revision.txt" 2>/dev/null || true
if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" add config/upstream-revision.txt 2>/dev/null || true
    git -C "$REPO_DIR" -c user.name="x86build-bot" -c user.email="bot@localhost" \
        commit -m "chore: 上游更新到 $REMOTE" 2>/dev/null || true
    git -C "$REPO_DIR" push origin main 2>/dev/null || log "推送失败（忽略）"
fi

echo "$REMOTE" > "$STAMP"
log "开始本地构建…"

if SKIP_PULL=1 "$REPO_DIR/scripts/local-build.sh" >> "$LOG" 2>&1; then
    log "✅ 构建成功"
else
    log "❌ 构建失败，详情见 $LOG"
    exit 1
fi