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

非交互命令：

```sh
xtwall --status      # 打印状态摘要
xtwall --cert-sync   # 同步 Caddy 证书到 Hysteria2（由 cron 每日调用）
```

## 架构

```
443/TCP   Xray VLESS-Reality（xtls-rprx-vision）
          └─ 非 Reality 握手原样中继 → 127.0.0.1:8443
443/UDP   Hysteria2（QUIC，obfs salamander）
8443/TCP  Caddy（仅本机监听）
          ├─ /ws   → 127.0.0.1:8080  VLESS over WS
          ├─ /tj   → 127.0.0.1:8081  Trojan over WS
          ├─ /sub  → 127.0.0.1:25500 subconverter（可选）
          └─ /     → /var/www/html   mikutap 伪装站 + 订阅文件
80/TCP    Caddy（ACME HTTP-01 验证 + 301 跳转）
```

Reality 的 `dest` 指向本地 Caddy，非 Reality 流量不会离开本机；对外只需放行 443/TCP 与 443/UDP（80 仅签发/续期证书时需要）。


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

1. **Cloudflare**：使用 CDN 入口时，域名必须为 `DNS Only`（云朵灰色），否则 Reality 与 WS 直连都会失效。
2. **域名一致性**：站点域名、Caddy 证书域名、Reality `serverNames` 必须完全一致，脚本会在安装时强制校验。
3. **证书**：由 Caddy 自动签发与续期，证书存放于 `/usr/local/etc/xtwall/caddy`；Hysteria2 只读取副本，每日 04:30 由 cron 同步。
4. **端口**：Caddy 的 8443 仅监听 `127.0.0.1`，无需在防火墙放行；若使用云厂商安全组，只需放行 443/TCP、443/UDP、80/TCP。
5. **镜像**：脚本下载仓库文件时依次尝试 jsdelivr → raw.githubusercontent.com → gh-proxy，可用环境变量 `XTWALL_GH_PROXY` 覆盖代理地址。

## Credit

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [apernet/hysteria](https://github.com/apernet/hysteria)
- [phlinhng/v2ray-tcp-tls-web](https://github.com/phlinhng/v2ray-tcp-tls-web)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)
