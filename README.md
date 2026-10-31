# xtwall

VLESS Reality + WS/TLS + Hysteria2 一键安装与运维脚本。
以 [xwall](https://github.com/phlinhng/v2ray-tcp-tls-web) 为骨架，融合 v2 分支的订阅、状态与运维能力，内核只保留 **xray-core**。

## Usage

```sh
bash <(curl -sL https://raw.githubusercontent.com/Yanel85/xtwall/main/install.sh)
```

安装后随时运行：

```sh
xtwall
```

首次通过 `install.sh` 安装时，会自动进入一键安装流程，完成后显示运维菜单。

非交互命令：

```sh
xtwall --status      # 打印状态摘要
xtwall --cert-sync   # 同步 Caddy 证书到 Hysteria2（由 cron 每日调用）
```

## 架构

```
443/TCP   Xray VLESS-Reality（xtls-rprx-vision，SNI = 直连域）
          └─ 非 Reality 握手原样中继 → 127.0.0.1:8443
443/UDP   Hysteria2（QUIC，obfs salamander，SNI = 直连域）
8443/TCP  Caddy（仅本机监听，按 SNI 选站点）
          ├─ 直连域站点：/ws → 8080、/tj → 8081、/sub/<uri> → 订阅文件、/sub?... → 25500、/ → 伪装站
          ├─ CDN 域站点 ：与直连域站点路由一致
          └─ 兜底站点   ：供 Hysteria2 masquerade 使用
80/TCP    Caddy（ACME HTTP-01 验证 + 301 跳转，两个域名各一个）
```

Reality 的 `dest` 指向本地 Caddy，非 Reality 流量不会离开本机；对外只需放行 443/TCP 与 443/UDP（80 仅签发/续期证书时需要，Cloudflare 回源也走 443/TCP）。

订阅文件存放在 `/usr/local/etc/xtwall/sub`，由 Caddy 以 `/sub/<uri>` 直读该目录，因此替换伪装站点或清空 `/var/www/html` 都不会影响订阅链接；`/sub?url=...&target=` 仍由 subconverter 处理。

伪装站点默认为 mikutap 单页模板，可用 `XTWALL_WEB_TEMPLATE` 指向其他压缩包覆盖。菜单中的“更新伪装站点模板”支持输入本地压缩包路径或下载 URL（留空回车即恢复默认模板），压缩包需包含根目录 `index.html`，支持 ZIP、TAR、TAR.GZ 和 TGZ 格式。Hysteria2 的 masquerade 固定反代到本地兜底站点，不再退化为内置静态页。

## 本地测试

域名解析到私网地址时无法通过 ACME 回源（Let's Encrypt 会直接拒绝），可改用 Caddy 本地 CA 签发：

```sh
XTWALL_TLS_MODE=internal bash <(curl -sL https://raw.githubusercontent.com/Yanel85/xtwall/main/install.sh)
```

安装后也可通过菜单“本地测试证书 (tls internal) 开关”随时切换。注意本地 CA 证书默认仅 12 小时有效期，需配合定时 `xtwall --cert-sync`，且客户端要信任该 CA 根证书或跳过校验。

## 端口冲突处理

安装时若端口已被占用，脚本会列出占用进程并给出处理方式：

- `80/tcp`：可终止占用进程，或选择跳过 http 站点（写入 `caddy.httpBlock=false`，放弃 ACME HTTP-01 与 301 跳转）；待 80 重新空闲后再执行安装会自动恢复该站点
- `443/tcp`、`443/udp`、`8443`、`8080`、`8081`：无法回落，必须终止占用进程或手动释放，否则中止安装

运行中替换伪装站点模板时，脚本会短暂停止 caddy 再原子替换 `/var/www/html`，替换完成后自动拉起（caddy 的 `ReadWritePaths` 会以 bind mount 占住该目录，无法直接重命名），并重新写入订阅文件，订阅链接不会失效。

## 两个域名模型

| 域名 | Cloudflare 状态 | 承载内容 |
| :--- | :--- | :--- |
| 直连域（安装时输入，必填） | 必须 `DNS Only`（灰云） | VLESS Reality、Hysteria2、Caddy 主站证书、直连形态分享链接 |
| CDN 域（菜单 7 配置，可选） | 必须开启橙云 | VLESS-WS、Trojan-WS、订阅链接、subconverter |

原因：Reality 依赖真实 TLS 握手与 SNI 校验，Hysteria2 跑在 QUIC/UDP 上，二者**都无法经过 HTTP CDN**；而 WS 类协议与订阅页可以。

Caddy 只在 `127.0.0.1:8443` 监听，按 SNI 选择站点：Reality 把非认证握手原样中继过来时命中直连域站点，Cloudflare 回源带的是 CDN 域 SNI，命中 CDN 域站点。两个站点共享同一个伪装站目录与 WS 反代，各自独立签发证书。

订阅链接在开启 CDN 后只给出 CDN 域；关闭后回到直连域。CF 优选节点（菜单 8）仅作为 CDN 节点的**连接地址**，SNI 与 Host 始终是 CDN 域。

## 目录结构

```
install.sh              安装器：下载脚本、初始化状态文件
src/xtwall.sh           主脚本（唯一入口）
config/xtwall.json      状态文件模板
tools/rm_xtwall.sh      卸载
tools/set_swap.sh       设置 Swap
tools/vps_tools.sh      VPS 工具集（加速 / Swap / WARP / 云盾 / 跑分）
tools/WARP.sh           WARP 管理（封装上游 fscarmen/warp-sh）
```

## 支持系统

- Debian 9+
- Ubuntu 16+
- CentOS 7+ / Rocky / AlmaLinux（systemd 必需）
- 架构：x86_64 / arm64 / armv7

## 注意事项

1. **Cloudflare**：直连域必须是 `DNS Only`（灰云），开启橙云会让 Reality 与 Hysteria2 直接失效；CDN 域相反，必须橙云。
2. **域名一致性**：直连域 = Caddy 主站 = Reality `serverNames` = Hysteria2 `sni`；CDN 域只需能通过 80 端口完成 HTTP-01 验证。两者不允许相同，脚本会拒绝。
3. **证书**：由 Caddy 自动签发与续期，证书存放于 `/usr/local/etc/xtwall/caddy`；Hysteria2 只读取副本，每日 04:30 由 cron 同步。
4. **端口**：Caddy 的 8443 仅监听 `127.0.0.1`，无需在防火墙放行；若使用云厂商安全组，只需放行 443/TCP、443/UDP、80/TCP。
5. **下载**：脚本优先从 GitHub 直链下载；直链失败时再尝试 gh-proxy。可用环境变量 `XTWALL_GH_PROXY` 覆盖代理地址。

## Credit

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [apernet/hysteria](https://github.com/apernet/hysteria)
- [phlinhng/v2ray-tcp-tls-web](https://github.com/phlinhng/v2ray-tcp-tls-web)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)
