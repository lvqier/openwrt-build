# OpenWrt 二次打包

基于 OpenWrt 官方 ImageBuilder 对 release 固件做二次打包。

## 构建目标

见 [`device.list`](device.list)，每行 `<target> <subtarget> <profile>`：

| 设备 | target / subtarget | profile |
|------|--------------------|---------|
| Xiaomi Redmi Router AX6000 | mediatek / filogic | `xiaomi_redmi-router-ax6000-ubootmod` |
| JDCloud AX6600 (RE-CP-03) | mediatek / filogic | `jdcloud_re-cp-03` |
| Xiaomi Redmi Router AC2100 | ramips / mt7621 | `xiaomi_redmi-router-ac2100` |
| Xiaomi Mi Router 3G | ramips / mt7621 | `xiaomi_mi-router-3g` |

默认 OpenWrt 版本 `25.12.5`。

## 额外安装的软件

在官方源基础上增减，见 `build.sh` 的 `PACKAGES`（`-` 前缀为移除）。

### LuCI / Web 管理界面

- `luci` — LuCI Web 管理界面

### 无线（补丁 / 漫游 / 热点）

- `wpad-mbedtls` + `-wpad-basic-mbedtls` — 替换为完整版无线认证守护进程（支持 802.11r/k/v 等高级特性）
- `luci-app-usteer` — usteer 的 LuCI 界面，多 AP 间无线漫游引导（band/steering）
- `hostapd-utils` — hostapd 命令行工具（hostapd_cli 等，配合 usteer/AP 管理）

### 网络中继

- `luci-proto-relay` — relayd 中继协议的 LuCI 界面（无线中继/无线桥接）

### VPN

- `luci-proto-wireguard` — WireGuard 的 LuCI 界面

### DNS / DHCP

- `dnsmasq-full` + `-dnsmasq` — 替换为完整版 dnsmasq（含 ipset 等高级特性）
- [luci-app-dnsmasq-ipset](https://github.com/lvqier/luci-app-dnsmasq-ipset)（源码构建，见 [`package.list`](package.list)）— dnsmasq-full IPSet 的 LuCI 控制界面，按域名生成 ipset 用于分流

### 动态域名（DDNS）

- `luci-app-ddns` — DDNS 的 LuCI 界面
- `ddns-scripts-dnspod-v3` — DNSPod 动态域名脚本

### 远程访问 / 诊断

- `openssh-sftp-server` — SFTP 服务端（配合 SSH 进行文件传输）
- `tcpdump` — 抓包工具
- `ethtool` — 网卡参数查询与设置
- `telnet-bsd` — Telnet 客户端

## 文件

- `build.sh` / `build-packages.sh` / `common.sh` — 构建脚本
- `device.list` — 构建目标清单
- `package.list` — 从源码构建的第三方包清单
- `files/` — 预置到固件根目录的自定义文件
- `packages/` — 注入镜像的自定义软件包（含源码构建产物）
- `.github/workflows/` — CI（`build.yml` 构建、`release.yml` 发布）

## 本地构建

```bash
./build.sh --all                    # 构建所有目标
./build.sh --arch mediatek filogic  # 只构建指定架构
./build.sh                          # 默认单设备
```

> ImageBuilder 与 SDK 为 Linux-x86_64 环境，需在 Linux 主机运行。

## GitHub Actions

- **build.yml** — 构建：
  - 每个 **target/subtarget** 一个构建任务（避免重复下载与 package 构建），构建该架构所有 profile，产物暂存到中间 artifact。
  - 每个 **profile** 一个轻量节点从中间 artifact 拆出独立产物 `openwrt-<dist>-<profile>`，结构为 `targets/<t>/<s>/`（固件）+ `packages/<t>/<s>/`（源码构建的 apk）。
  - 同架构多 profile 共享 `build/` 缓存。
- **release.yml** — 手动触发：构建 → 打 tag → 创建 GitHub Release 并为每个 profile 附加一个 zip。
