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
          ├─ 直连域站点：/ws → 8080、/tj → 8081、/ → 伪装站
          ├─ CDN 域站点 ：/ws → 8080、/tj → 8081、/sub → 25500、/ → 伪装站
          └─ 兜底站点   ：供 Hysteria2 masquerade 使用
80/TCP    Caddy（ACME HTTP-01 验证 + 301 跳转，两个域名各一个）
```

Reality 的 `dest` 指向本地 Caddy，非 Reality 流量不会离开本机；对外只需放行 443/TCP 与 443/UDP（80 仅签发/续期证书时需要，Cloudflare 回源也走 443/TCP）。

菜单中的“更新伪装站点模板”支持输入本地压缩包路径或下载 URL，压缩包需包含根目录 `index.html`，支持 ZIP、TAR、TAR.GZ 和 TGZ 格式。

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
5. **镜像**：脚本下载仓库文件时依次尝试 jsdelivr → raw.githubusercontent.com → gh-proxy，可用环境变量 `XTWALL_GH_PROXY` 覆盖代理地址。

## Credit

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [apernet/hysteria](https://github.com/apernet/hysteria)
- [phlinhng/v2ray-tcp-tls-web](https://github.com/phlinhng/v2ray-tcp-tls-web)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)
