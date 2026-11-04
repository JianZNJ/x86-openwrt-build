# x86-openwrt-build

ImmortalWrt **25.12-SNAPSHOT** x86-64 固件，基于 **ImageBuilder** 快速构建（约 15 分钟），
内置 **daed**（dae eBPF 透明代理）替代 OpenClash。

---

## 相比旧版（24.10 + OpenClash）的变化

| 项目 | 旧版 | 现在 |
|------|------|------|
| 基础系统 | 24.10（源码编译，5 小时） | **25.12-SNAPSHOT（ImageBuilder，15 分钟）** |
| 内核 | 6.6.159 | **6.12.x** |
| BTF | ❌ 无 | ✅ **内置**（`/sys/kernel/btf/vmlinux`） |
| 代理 | OpenClash | **dae + daed** |
| 包管理 | opkg / ipk | **apk** |
| 直连开销 | 有 | **零**（eBPF 在 tc ingress 分流） |
| 内存（代理） | 80–150 MB | **42 MB** |

---

## 仓库结构

```
.github/workflows/x86.yml     GitHub Actions 构建流水线
config/packages.txt           96 个软件包
apks/                         第三方预编译 APK（feed 中没有的）
  lucky / luci-app-lucky
  wrtbwmon / luci-app-wrtbwmon
  luci-app-wechatpush（Server酱）
files/etc/uci-defaults/       首次启动配置脚本
  98-set-network              LAN/WAN/PPPoE/flow offloading/IPv6
  99-set-root-password        root 密码
  99-daede-init               daed 数据目录 + 启用
  99-wrtbwmon-guard           wrtbwmon 单实例修复
  99-adblock-tune             adblock-fast 列表 + 超时 + 定时
  99-banip-sources            banip 4 个黑名单源 + 定时
  99-firewall-4443            Lucky 端口放行
  99-docker-data-root         Docker 数据根 → /mnt/data
files/etc/sysctl.d/            nlbwmon 缓冲修复
files/usr/sbin/fw-ota           OTA 主脚本
files/www/.../view/fw-ota.js   OTA LuCI 界面
files/usr/share/luci/menu.d    OTA 菜单
files/usr/share/rpcd/acl.d    OTA ACL
scripts/build.sh              构建脚本（本地 / CI 通用）
out/                          产物
```

---

## GitHub Secrets

| Secret | 用途 |
|--------|------|
| `PPPOE_USER` | 宽带账号 |
| `PPPOE_PASS` | 宽带密码 |
| `ROOT_PASS`  | root 密码 |

未设置时使用占位值（`pppoe` / `pppoe` / `openwrt`），首次启动后需手动改。

---

## 本地构建（.223 / EQ12）

在编译机（`192.168.2.130`，仓库在 `~/x86build`）上执行：

```bash
./scripts/local-build.sh                          # 默认 minimal
FIRMWARE_PROFILE=full ./scripts/local-build.sh    # 旧行为：烘白名单配置
SKIP_PULL=1 ./scripts/local-build.sh              # 不拉代码，直接用当前工作区
FW_VERSION=1800000000 ./scripts/local-build.sh    # 指定版本号（默认 epoch 秒）
NO_PUBLISH=1 ./scripts/local-build.sh             # 只构建不发布
```

依赖：`zstd`、`qemu-utils`、`curl`、`rsync`、`mtools`、`sgdisk`。

产物发布到 `~/x86build-out/`（由 `x86build-http.service` 在 `192.168.2.130:8080` 提供）：

```
immortalwrt-25.12-snapshot-...-daede-x86-64-generic-squashfs-combined-efi.img.gz  ~123 MB
*.manifest        软件包清单
latest.json       OTA 清单（fw-ota 比对 version）
sha256sums        校验和
```

### 两种 profile

| 内容 | `minimal`（默认） | `full` |
|---|---|---|
| `/etc/config/*` 烘焙 | ❌ 不烘 | ✅ 12 个白名单 |
| `wing.db` / ACME 证书 / dropbear 主机密钥 | ❌ 不烘 | ✅ 烘 |
| uci-defaults | **只留 `98-set-network`** | 全部 14 个 |
| root 密码哈希 | ❌ 不设（首启 LuCI 提示设置） | ✅ 烘 `/etc/shadow` 哈希 |
| 适用 | 日常 OTA，配置靠「保留配置」继承 | 需要开箱即用的整盘新装 |

**为什么默认 minimal**

1. `sysupgrade` 的「保留配置」会备份/还原 **89 项**（来自各包 `/lib/upgrade/keep.d`）：`/etc/config/**`、`/etc/daed/wing.db`、`/etc/acme/**`、`/etc/nginx/**`、`/etc/crontabs/`、`/etc/rc.local`、`/etc/dropbear/*`、`/etc/shadow`…烘焙的配置刷完就被旧配置覆盖，等于白带。
2. 镜像里的 uci-defaults **每次 OTA 后都会重跑一遍**（它们属于新 rootfs），`99-nginx-setup` 之类会把已还原的 `nginx.conf` / `conf.d/*` 又盖掉。minimal 直接把它们挡在镜像外。

`98-set-network` 是唯一保留的脚本，只在「不保留配置」刷机时兜底：

| 项 | 值 |
|---|---|
| LAN | `br-lan` = `eth1 eth2 eth3` → `192.168.2.1/24` |
| WAN | `eth0` → PPPoE（凭据由构建时注入，占位符 `__PPPOE_USER__` / `__PPPOE_PASS__`） |
| 其它 | flow offloading 开、IPv6 关 |

> 没有它的话，「不保留配置」刷机后由 board.d 生成默认的 `192.168.1.1` + DHCP WAN，得手动把电脑改到 192.168.1.x 才能登录。

---

## 刷机

```bash
gunzip -c *squashfs-combined-efi.img.gz | dd of=/dev/sda bs=4M status=progress conv=fsync
```

⚠️ **整盘覆盖会清空数据分区（如 sda3）。**

### 保留数据分区的写法

镜像约 1.1 GB，若旧数据分区从 2.1 GB（扇区 4325888）开始：

```bash
# 1. 只写前 1.2 GB
gunzip -c *.img.gz | dd of=/dev/sda bs=1M count=1200 conv=fsync

# 2. 重启后把 GPT 备份头移到盘尾
apk add gdisk
gdisk /dev/sda      # x → e → w → y

# 3. 重建数据分区（起始扇区按原值）
gdisk /dev/sda      # n → 3 → 4325888 → 回车 → 回车 → w → y

# 4. fstab 持久化 + 重启
uci add fstab mount
uci set fstab.@mount[-1].target='/mnt/data'
uci set fstab.@mount[-1].device='/dev/sda3'
uci set fstab.@mount[-1].fstype='ext4'
uci set fstab.@mount[-1].enabled='1'
uci commit fstab
reboot
```

---

---

## 固件 OTA

镜像内置 `fw-ota`，可从 GitHub Releases 自动检查/下载/校验/刷写。

### LuCI 界面

```
LuCI → 系统 → 固件升级 (OTA)
```

四个按钮：**检查更新** / **开始下载** / **取消** / **确认刷入并重启**，带实时进度条。

### 命令行

```bash
/usr/sbin/fw-ota version     # 本地构建号
/usr/sbin/fw-ota check       # 检查（0=有新版 1=已最新 2=出错）
/usr/sbin/fw-ota download    # 下载 + sha256 校验（后台）
/usr/sbin/fw-ota progress    # 进度 JSON
/usr/sbin/fw-ota install     # 刷入（需先 ready）
/usr/sbin/fw-ota cancel      # 取消
/usr/sbin/fw-ota update      # 下载+校验+交互确认刷机
/usr/sbin/fw-ota force       # 同上但跳过版本比较
```

### 工作流程

```
check  → 比对 /etc/fw-version 与 Release tag（x86-<run_number>）
         ↓ 有新版本
download → 后台下载 combined-efi.img.gz → sha256sums 校验
         ↓ 状态 ready
install → sysupgrade（保留配置）→ 重启
```

### 状态机

`idle` → `downloading` → `verifying` → `ready` → `installing`

出错进入 `error`；已最新时进入 `latest`。

### 自动检查

`/etc/crontabs/root`：

```
0 4 * * 6 /usr/sbin/fw-ota check >> /var/log/fw-ota.log 2>&1
```

每周六 04:00 只检查不刷机，日志写入 `/var/log/fw-ota.log`。

### 注意

- 镜像下载走路由器默认出口；若开启了 daed 且节点不稳定，建议把
  `github.com` / `objects.githubusercontent.com` 加入直连规则
- `sysupgrade` 保留配置，但**跨大版本**（如 24.10 → 25.12）建议全新刷写
- 工作目录 `/tmp/fw-ota`（内存盘，重启清空）

---

## daed / dae 配置体系（重要）

### ⚠️ daed 与 dae 不是同一个配置文件

| 组件 | 配置源 | 说明 |
|------|--------|------|
| `dae`（独立命令行） | `/etc/dae/config.dae` | 直接读文本文件 |
| **`daed`（守护进程）** | **`/etc/daed/wing.db`**（SQLite） | **不读 config.dae** |

```
/etc/config/dae  (UCI 源)
      ↓ gen-dae-config.sh generate
/etc/dae/config.dae  (导出产物，仅 dae 服务读取)
      ✗  daed 不读

/etc/daed/wing.db  (SQLite)
      ↑ daed Web UI (:2023) 写入
      ✅ daed 读这里
```

**改 daed 配置必须用 Web UI (`:2023`) 或写 `wing.db`，改 `config.dae` 完全无效。**

验证方法（无损）：把 `config.dae` 的 `log_level` 改成 `debug` 再重启 daed，日志级别不会变。

### wing.db 结构

```sql
configs(id, name, global, selected, version)
dns(id, name, dns, selected, version)
routings(id, name, routing, selected, version)
subscriptions / nodes / groups / systems ...
```

读取当前配置：

```bash
sqlite3 /etc/daed/wing.db "select dns from dns where selected=1;" | sed 's/\\u000a/\n/g'
```

---

## adblock-fast 与 daed 的 DNS 冲突（已解决）

### 问题

daed 自带的 DNS 模块在 tc ingress 抢在 dnsmasq 之前，导致 **adblock-fast 的 50 万条规则对局域网客户端完全失效**。

实测对比：

| 域名 | 路由器本机（dnsmasq） | 局域网客户端（被 dae 拦截） |
|------|----------------------|---------------------------|
| `google-analytics.com` | NXDOMAIN ✅ | 解析成功 ❌ |

### 解决方案

```
LAN 客户端 → dae eBPF → dnsmasq:53
                          ├─ adblock-fast 过滤 50 万条 → NXDOMAIN ✅
                          └─ 未命中 → 223.5.5.5 / 119.29.29.29
                                          ↓ pname(dnsmasq) -> must_direct（防循环）
                          ↓
                     dae 按域名路由：
                          geosite:cn → direct
                          其他       → proxy（按域名拨号，节点侧解析）
```

### 固件已固化的部分

`files/etc/uci-defaults/99-dns-adblock-integration`：

```ini
# dnsmasq 上游（忽略 ISP 下发）
server:   223.5.5.5, 119.29.29.29
noresolv: 1
```

以及 `/etc/config/dae`（给 dae 后端用）：
```ini
dae.dns.cn_upstream='udp://127.0.0.1:53'
dae.dns.fallback_upstream='udp://127.0.0.1:53'
dae.routing.cn_direct='0'
```

### ⚠️ 需要手动设置的（daed 后端）

`wing.db` 里含订阅/节点，无法固化。请在 **daed Web UI (`:2023`)** 设置：

**配置 → DNS**

```
上游服务器：
  dnsmasq    udp://127.0.0.1:53

进阶模式路由：
  qname(geosite:cn) -> dnsmasq
  fallback: dnsmasq
```

**配置 → 路由**

```dae
routing {
  pname(NetworkManager, systemd-resolved, dnsmasq) -> must_direct
  dip(geoip:private) -> direct
  domain(geosite:cn) -> direct
  fallback: proxy
  # ★ 必须删除 dip(geoip:cn) -> direct
}
```

**为什么必须删 `dip(geoip:cn)`**：国内 DNS 会把国外域名污染成国内 IP，若保留这条规则，被污染的 IP 会命中它 → 误判直连 → 网站打不开。因为 `dial_mode: domain`，代理连接用域名、由节点侧解析，所以删掉 IP 判断反而更准。

### 效果

| 测试 | 结果 |
|------|------|
| `google-analytics.com` | NXDOMAIN ✅ |
| `pagead2.googlesyndication.com` | NXDOMAIN ✅ |
| DNS 解析延迟 | 1–2 ms |
| baidu / taobao | 200 / 58–81 ms（直连） |
| google / github / youtube | 200 / 231–436 ms（代理） |

> `googletagmanager.com` 不在 Hagezi Pro 列表里是**有意**的（GTM 被正常网站广泛使用）。如需拦截，在 `adblock-fast` 的 `blocked_domains` 手动添加。

---

## ⚠️ 凭据安全

**仓库是 public（OTA 需要），任何凭据都不得入库。**

| 凭据 | 存放位置 | 是否入库 |
|------|----------|----------|
| PPPoE 账号/密码 | GitHub Secrets → build.sh 注入 | ✅ Secrets |
| root 密码 | GitHub Secrets | ✅ Secrets |
| **阿里云 AccessKey**（ACME DNS-01） | **路由器 `/etc/config/acme`** | ❌ **绝不同步** |
| **阿里云 AccessKey**（DDNS） | **路由器 `/etc/config/ddns`** | ❌ **绝不同步** |
| daed 订阅链接/节点 | 路由器 `/etc/daed/wing.db` | ❌ **绝不同步** |

刷机后需手动配置阿里云 Key（ACME 与 DDNS 各一处）。

---
## 容器访问国外（microsocks SOCKS5 代理）

### 问题

Docker 容器流量走 `docker0 → MASQUERADE → pppoe-wan`（直连），**不经过 daed**，
因此只能访问国内站点。

> 实测：把 `docker0` 加进 daed 的 `lan_interface` 会**打断容器的 DNS 和 TCP**
> （ICMP 仍通），不可行，已放弃。

### 方案：宿主机上的 SOCKS5 代理

```
容器 → 172.17.0.1:1080 (microsocks)
     → microsocks 进程 = 路由器本机流量
     → 被 daed 的 wan_interface 拦截 → 走代理 → 国外 ✅
```

`microsocks` 仅 **8 KB**，源码编译（不在 apk feed 中）。

### 固件已固化

- `apks/microsocks-1.0.5-r2.apk`
- `files/etc/uci-defaults/99-microsocks-proxy`
  - 监听 `172.17.0.1:1080`（**仅 docker 网桥，LAN/WAN 不可达**）
  - 启用 SOCKS5 用户名口令认证
  - **密码首次启动随机生成** → `/etc/microsocks.pass`（600）

### 读取代理密码

```bash
cat /etc/microsocks.pass
```

用户名为 `svc`。

### 配置各应用

**Sonarr / Radarr**（通过 API，最可靠）：

```bash
K=$(grep -o '<ApiKey>[^<]*' /mnt/data/Configs/Sonarr/config.xml | sed 's/<ApiKey>//')
curl -s -H "X-Api-Key: $K" http://192.168.2.1:8989/api/v3/config/host > /tmp/h.json
jq '.proxyEnabled=true | .proxyType="socks5" | .proxyHostname="172.17.0.1"
    | .proxyPort=1080 | .proxyUsername="svc" | .proxyPassword="<从 /etc/microsocks.pass 读>"
    | .proxyBypassFilter="192.168.2.0/24,172.17.0.0/16,127.0.0.1"
    | .proxyBypassLocalAddresses=true' /tmp/h.json > /tmp/h2.json
curl -s -X PUT -H "X-Api-Key: $K" -H "Content-Type: application/json" \
     --data @/tmp/h2.json http://192.168.2.1:8989/api/v3/config/host
```

**Jackett**（`ProxyType` 数值含义）：

```json
"ProxyType": 2,              // 2 = SOCKS5（1 是 HTTP，会失败）
"ProxyUrl": "172.17.0.1",
"ProxyPort": 1080,
"ProxyUsername": "svc",
"ProxyPassword": "<同上>",
"ProxyIsAnonymous": false
```

配置文件：`/mnt/data/Configs/Jackett/Jackett/ServerConfig.json`，改完 `docker restart jackett`。

> ⚠️ **`ProxyType` 的坑**：设 `1` 时 Jackett 会发 HTTP CONNECT 给 SOCKS5 服务，
> 报 `EstablishProxyTunnelAsync ... The response ended prematurely`。**必须用 `2`**。

### 验证

```bash
# 代理连接日志（临时关 quiet）
uci set microsocks.config.quiet='0'; uci commit microsocks
/etc/init.d/microsocks restart
logread | grep microsocks      # 应看到 "connected to xxx:443"
uci set microsocks.config.quiet='1'; uci commit microsocks
/etc/init.d/microsocks restart
```

**实测结果**：

| 应用 | 测试 | 结果 |
|------|------|------|
| Jackett | thepiratebay 搜索 | ✅ 100 条 |
| Sonarr | TVDB lookup | ✅ Breaking Bad (2008) |
| Radarr | TMDB lookup | ✅ Inception (2010) |

### FlareSolverr（解决 Cloudflare 挑战）

部分 indexer（eztv、1337x 等）启用了 Cloudflare 挑战，需要 FlareSolverr。

```bash
docker run -d --name flaresolverr \
  --restart unless-stopped \
  --network host \
  -e LOG_LEVEL=info -e TZ=Asia/Shanghai \
  -e HOST=172.17.0.1 -e PORT=8191 -e HEADLESS=true \
  ghcr.io/flaresolverr/flaresolverr:latest
```

> **必须用 `--network host`**：FlareSolverr 的 Chromium 需要访问被墙站点，
> host 网络下它的流量等于路由器本机流量，会被 daed 自动代理。
> `HOST=172.17.0.1` 保证只监听 docker 网桥，不外露。

在 Jackett 的 `ServerConfig.json` 填：

```json
"FlareSolverrUrl": "http://172.17.0.1:8191",
"FlareSolverrMaxTimeout": 60000
```

#### ⚠️ FlareSolverr 的凭据格式坑

FlareSolverr 3.5.2 **只识别 URL 内嵌凭据**，忽略分离的字段：

| 传入方式 | 结果 |
|---|---|
| `{"proxy":{"url":"socks5://svc:pass@172.17.0.1:1080"}}` | ✅ 正常 |
| `{"proxy":{"url":"socks5://172.17.0.1:1080","username":"svc","password":"..."}}` | ❌ `ERR_SOCKS_CONNECTION_FAILED` |

而 Jackett 传的正是**分离字段**，所以如果 microsocks 启用了认证，
FlareSolverr 侧必然失败。

**结论**：microsocks 不启用认证（仅靠 `listenip=172.17.0.1` 限界）。

#### 实测

| indexer | 结果 |
|---|---|
| eztv | ✅ 有结果 |
| thepiratebay | ✅ 100 条 |
| 1337x | ❌ Cloudflare 对代理出口 IP 直接 403（`curl https://1337x.to` 就是 403），非配置问题 |
| yts | ❌ `movies-api` 域名自身问题 |

---
### 已知限制

部分 indexer 需要 **FlareSolverr**（Cloudflare 挑战），与代理无关：

```
1337x / eztv → "Challenge detected but FlareSolverr is not configured"
```

需要另装 FlareSolverr 容器并在 Jackett 里填 `FlareSolverrUrl`。

---
## 已知修复

### wrtbwmon 多实例

`wrtbwmon -d` 会自 daemonize（fork 后父进程退出），与 procd 的 `respawn` 以及
`/etc/hotplug.d/iface/99-wrtbwmon` 的 `restart` 叠加，会累积多个实例。

修复（`99-wrtbwmon-guard`）：

1. 禁用 procd 服务：`/etc/init.d/wrtbwmon disable`
2. 禁用 hotplug：`chmod -x /etc/hotplug.d/iface/99-wrtbwmon`
3. 改由 `/etc/rc.local` 用 `pidof` 守卫启动单实例

> 注意：`ps | grep -c wrtbwmon` 会显示 **2**，这是主进程 + 其子进程，属正常。

### adblock-fast 列表下载超时

默认 `download_timeout=10`，走代理时容易超时导致域名数腰斩（506k → 247k）。

修复：`download_timeout=180`、`download_connect_timeout=60`、`curl_retry=8`。

### banip 源不加载

`ban_sources` 配置后 `restart` 不触发重新下载，**必须 `reboot` 或 `boot` 模式**才生效。
预期结果：`element_count ≈ 5,800`，`active_feeds` 含 4 个源。

### daed + WireGuard

dae 默认只 hook `lan_interface`，WireGuard（`wg0`）流量不经代理。

在 daed 控制台 `:2023` → 全局设置 → 拦截接口填：

```
br-lan,wg0
```

**多个接口用英文逗号分隔**，保存后重载。

---

## 定时任务

```
0 4 * * 0   /etc/init.d/adblock-fast dl     # 广告列表
0 3 * * 0   /etc/init.d/banip reload        # IP 黑名单
17 4 * * *  daed-sub-update.sh              # daed 订阅
```

GitHub Actions 构建：**不再定时**，改为上游驱动的自动同步。

### 上游同步机制

```
upstream-check.yml（每 6 小时，cron 17 */6 * * *）
        ↓ 拉取 upstream version.buildinfo
        ↓ 与 config/upstream-revision.txt 比对
   变化 ─┴─ 无变化 → 结束
        ↓
   提交新的 upstream-revision.txt 并 push
        ↓
x86.yml 由 push 触发（paths: config/**）
        ↓
   7 分钟后产出 Release x86-<run_number>
```

| 项目 | 说明 |
|------|------|
| 上游版本戳 | `https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/targets/x86/64/version.buildinfo` |
| 本地记录 | `config/upstream-revision.txt` |
| 检查频率 | 每 6 小时（`17 */6 * * *`） |
| 镜像内标识 | `/etc/fw-upstream` |
| 手动触发 | Actions → Upstream Check → Run workflow |

也可以用 `workflow_dispatch` 直接手动构建（不走上游检测）。

---

## License

构建脚本 MIT；固件内容遵循 ImmortalWrt 及各软件包原有许可。