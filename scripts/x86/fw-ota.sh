#!/bin/sh
# ============================================================
#  fw-ota — 从 GitHub Releases 检查并升级 OpenWrt x86 固件
#
#  用法:
#    fw-ota check    检查是否有新版本（只读，不改动系统）
#    fw-ota update   下载 + 校验 sha256 + 交互确认后刷机
#    fw-ota force    下载 + 校验后直接刷机（跳过确认）
#    fw-ota start    后台静默升级（供 LuCI 调用，避免 XHR 超时）
#    fw-ota progress 输出进度 JSON（state/bytes/total/percent/tag）
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

pick_size() {
    # $1=json  $2=文件名片段  —— 从 release JSON 里取出资产字节数
    echo "$1" | tr '{' '\n' | grep "$2" | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2
}

# 文件字节数（busybox stat 不支持 -c）
filesize() {
    wc -c < "$1" 2>/dev/null | tr -d ' '
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

    # 记录总大小与状态，供进度查询使用
    total=$(pick_size "$json" "combined-efi")
    echo "${total:-0}" > "$WORKDIR/total"
    echo "$tag" > "$WORKDIR/tag"
    echo "downloading" > "$WORKDIR/state"
    rm -f "$fw" "$WORKDIR/progress.err"

    log "下载固件…"
    if ! fetch_url "$img_url" "$fw"; then
        echo "error" > "$WORKDIR/state"
        log "下载失败"; return 4
    fi
    [ -s "$fw" ] || { echo "error" > "$WORKDIR/state"; log "下载结果为空"; return 4; }

    echo "verifying" > "$WORKDIR/state"
    if [ -n "$sum_url" ]; then
        sums="$WORKDIR/sha256sums"
        fetch_url "$sum_url" "$sums"
        want=$(basename "$img_url")
        expect=$(WANT="$want" awk '{f=$NF; sub(/^\*/,"",f); if (f==ENVIRON["WANT"]) {print $1; exit}}' "$sums" 2>/dev/null)
        if [ -n "$expect" ]; then
            actual=$(sha256sum "$fw" | awk '{print $1}')
            if [ "$expect" != "$actual" ]; then
                echo "error" > "$WORKDIR/state"
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
    echo "installing" > "$WORKDIR/state"
    sysupgrade "$fw"
}

# 输出进度 JSON（供 LuCI 轮询）
do_progress() {
    state="idle"
    bytes=0
    total=0
    tag=""

    [ -f "$WORKDIR/state" ] && state=$(cat "$WORKDIR/state" 2>/dev/null)
    [ -f "$WORKDIR/total" ] && total=$(cat "$WORKDIR/total" 2>/dev/null)
    [ -f "$WORKDIR/tag" ]   && tag=$(cat "$WORKDIR/tag" 2>/dev/null)
    [ -f "$WORKDIR/firmware.img.gz" ] && bytes=$(filesize "$WORKDIR/firmware.img.gz")

    # 没有活跃进程时纠正状态（busybox grep 不支持 \| 交替，分开判断）
    running=0
    ps w 2>/dev/null | grep -q "[f]w-ota force"  && running=1
    ps w 2>/dev/null | grep -q "[f]w-ota update" && running=1
    if [ "$running" = "0" ]; then
        case "$state" in
            downloading|verifying)
                # 进程消失但文件仍在且大小吻合 => 可能已完成或中断
                if [ "$total" -gt 0 ] 2>/dev/null && [ "$bytes" -ge "$total" ] 2>/dev/null; then
                    state="verifying"
                else
                    state="idle"
                fi
                ;;
        esac
    fi

    [ "$total" -gt 0 ] 2>/dev/null || total=0
    [ "$bytes" -gt 0 ] 2>/dev/null || bytes=0

    percent=0
    if [ "$total" -gt 0 ] 2>/dev/null; then
        percent=$((bytes * 100 / total))
        [ "$percent" -gt 100 ] && percent=100
    fi

    printf '{"state":"%s","bytes":%s,"total":%s,"percent":%s,"tag":"%s"}\n' \
        "$state" "$bytes" "$total" "$percent" "$tag"
}

# 后台启动升级（供 LuCI 使用，避免 XHR 超时）
do_start() {
    mkdir -p "$WORKDIR"
    echo "downloading" > "$WORKDIR/state"
    rm -f "$WORKDIR/state.done"
    nohup /usr/sbin/fw-ota force > /var/log/fw-ota-update.log 2>&1 &
    echo "started"
}

case "${1:-check}" in
    check)    do_check; exit $? ;;
    update)   do_update 0; exit $? ;;
    force)    do_update 1; exit $? ;;
    start)    do_start; exit 0 ;;
    progress) do_progress; exit 0 ;;
    version)  echo "本地版本: $(local_ver)"; exit 0 ;;
    *)        echo "用法: $0 {check|update|force|start|progress|version}"; exit 1 ;;
esac
