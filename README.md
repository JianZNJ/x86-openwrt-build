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

## 本地构建

```bash
export PPPOE_USER='...'
export PPPOE_PASS='...'
export ROOT_PASS='...'
bash scripts/build.sh
```

依赖：`zstd`、`qemu-utils`、`curl`、`rsync`。

产物在 `out/`：

```
immortalwrt-25.12-snapshot-...-daede-x86-64-generic-squashfs-combined-efi.img.gz  ~127 MB
*.manifest        软件包清单
sha256sums        校验和
```

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

GitHub Actions 构建：每周六 02:00 CST。

---

## License

构建脚本 MIT；固件内容遵循 ImmortalWrt 及各软件包原有许可。