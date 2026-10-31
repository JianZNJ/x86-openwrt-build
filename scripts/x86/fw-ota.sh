#!/bin/sh
# ============================================================
#  fw-ota — 从 GitHub Releases 检查并升级 OpenWrt x86 固件
#
#  用法:
#    fw-ota check    检查是否有新版本（只读，不改动系统）
#    fw-ota update   下载 + 校验 sha256 + 交互确认后刷机
#    fw-ota force    下载 + 校验后直接刷机（跳过确认）
#    fw-ota version  显示本地版本
# ============================================================
set -u

REPO="JianZNJ/x86-openwrt-build"
API="https://api.github.com/repos/${REPO}"
VERFILE="/etc/fw-version"
WORKDIR="/tmp/fw-ota"
ASSET_RE="combined-efi\.img\.gz"

log() { echo "[fw-ota] $*"; }

local_ver() {
    if [ -f "$VERFILE" ]; then
        cat "$VERFILE" 2>/dev/null
    else
        echo 0
    fi
}

fetch_url() {
    # $1=url  $2=output file (或 - 表示 stdout)
    if command -v uclient-fetch >/dev/null 2>&1; then
        if [ "$2" = "-" ]; then
            uclient-fetch -q -O - "$1" 2>/dev/null
        else
            uclient-fetch -q -O "$2" "$1" 2>/dev/null
        fi
    elif command -v curl >/dev/null 2>&1; then
        if [ "$2" = "-" ]; then
            curl -fsSL --max-time 60 "$1" 2>/dev/null
        else
            curl -fsSL --max-time 600 -o "$2" "$1" 2>/dev/null
        fi
    else
        if [ "$2" = "-" ]; then
            wget -q -O - "$1" 2>/dev/null
        else
            wget -q -O "$2" "$1" 2>/dev/null
        fi
    fi
}

get_release_json() {
    fetch_url "$API/releases?per_page=1" -
}

pick_url() {
    # $1=json  $2=正则
    echo "$1" | tr ',' '\n' | grep -o "https://[^\"]*$2" | head -1
}

do_check() {
    json=$(get_release_json)
    if [ -z "$json" ]; then
        log "无法访问 GitHub API（检查网络/DNS）"
        return 2
    fi
    tag=$(echo "$json" | jsonfilter -e '@[0].tag_name' 2>/dev/null)
    if [ -z "$tag" ]; then
        log "解析 release tag 失败"
        return 2
    fi
    lv=$(local_ver)
    rv=$(echo "$tag" | sed 's/^x86-//')
    log "本地版本: $lv"
    log "远端版本: $tag"
    if [ "$rv" -gt "$lv" ] 2>/dev/null; then
        log "=> 有新版本可用"
        return 0
    fi
    log "=> 已是最新"
    return 1
}

do_update() {
    force="${1:-0}"
    json=$(get_release_json)
    [ -z "$json" ] && { log "无法访问 GitHub API"; return 2; }

    tag=$(echo "$json" | jsonfilter -e '@[0].tag_name' 2>/dev/null)
    [ -z "$tag" ] && { log "解析 tag 失败"; return 2; }

    lv=$(local_ver)
    rv=$(echo "$tag" | sed 's/^x86-//')
    if ! [ "$rv" -gt "$lv" ] 2>/dev/null; then
        log "已是最新（本地 $lv / 远端 $rv），无需升级"
        return 0
    fi

    img_url=$(pick_url "$json" "combined-efi\.img\.gz")
    sum_url=$(pick_url "$json" "sha256sums")
    [ -z "$img_url" ] && { log "未在 release 中找到 combined-efi.img.gz"; return 3; }

    log "目标版本: $tag"
    mkdir -p "$WORKDIR"
    fw="$WORKDIR/firmware.img.gz"

    log "下载固件…"
    if ! fetch_url "$img_url" "$fw"; then
        log "下载失败"; return 4
    fi
    [ -s "$fw" ] || { log "下载结果为空"; return 4; }

    if [ -n "$sum_url" ]; then
        sums="$WORKDIR/sha256sums"
        fetch_url "$sum_url" "$sums"
        want=$(basename "$img_url")
        expect=$(grep " $want\$" "$sums" 2>/dev/null | awk '{print $1}' | head -1)
        if [ -n "$expect" ]; then
            actual=$(sha256sum "$fw" | awk '{print $1}')
            if [ "$expect" != "$actual" ]; then
                log "sha256 校验失败！已中止（期望 $expect / 实际 $actual）"
                rm -f "$fw"
                return 5
            fi
            log "sha256 校验通过"
        else
            log "警告: sha256sums 中未找到该文件，跳过校验"
        fi
    else
        log "警告: release 中没有 sha256sums，跳过校验"
    fi

    if [ "$force" != "1" ]; then
        printf "确认刷入 %s 并重启？[y/N] " "$tag"
        read ans
        case "$ans" in
            y|Y|yes|YES) ;;
            *) log "已取消"; rm -f "$fw"; return 0 ;;
        esac
    fi

    log "开始 sysupgrade（保留配置），设备即将重启…"
    sysupgrade "$fw"
}

case "${1:-check}" in
    check)   do_check; exit $? ;;
    update)  do_update 0; exit $? ;;
    force)   do_update 1; exit $? ;;
    version) echo "本地版本: $(local_ver)"; exit 0 ;;
    *)       echo "用法: $0 {check|update|force|version}"; exit 1 ;;
esac
