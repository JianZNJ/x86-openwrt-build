#!/bin/bash
# diy-part1: 更新 feeds 之前执行（cwd = openwrt 源码根目录）
set -euo pipefail

echo "==> 追加第三方 feed"

if ! grep -q 'openclash' feeds.conf.default; then
  echo 'src-git openclash https://github.com/vernesong/OpenClash.git;master' >> feeds.conf.default
  echo "    + openclash"
fi

if ! grep -q 'luci-app-lucky' feeds.conf.default; then
  echo 'src-git lucky https://github.com/gdy666/luci-app-lucky.git;main' >> feeds.conf.default
  echo "    + lucky"
fi

echo "==> 克隆 OpenAppFilter（含 kmod-oaf 内核模块）"
rm -rf package/OpenAppFilter
git clone --depth 1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter
echo "    内容:"
ls -1 package/OpenAppFilter

echo "==> 当前 feeds:"
cat feeds.conf.default
