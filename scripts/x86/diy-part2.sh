#!/bin/bash
# diy-part2: feeds update 之后、install 之前执行（cwd = openwrt 源码根目录）
set -euo pipefail

echo "==> 检查第三方 feed 是否拉取成功"
for d in feeds/openclash feeds/lucky; do
  if [ -d "$d" ]; then
    echo "    OK   $d"
  else
    echo "    WARN $d 不存在"
  fi
done

echo "==> OpenAppFilter 目录"
ls -1 package/OpenAppFilter
