#!/bin/bash
# xtwall - VLESS Reality + WS/TLS + Hysteria2 一键脚本
# 架构: 443/TCP = Xray Reality (dest -> 本地 Caddy:8443)
#       443/UDP = Hysteria2
#       80/TCP + 8443/TCP = Caddy (ACME / 伪装站 / WS 反代)
export LC_ALL=C
export LANG=en_US
export LANGUAGE=en_US.UTF-8

# ============================================================
# 第1节 常量区
# ============================================================
branch="main"
VERSION="1.0.0"
REPO="Yanel85/xtwall"
# 项目源码地址仅供脚本下载使用，不在终端输出。

jsdelivr="cdn.jsdelivr.net/gh"
gh_proxy="${XTWALL_GH_PROXY:-gh-proxy.phlin.workers.dev}"
api_proxy="${XTWALL_API_PROXY:-gh-api.phlin.workers.dev}"

log_path="/var/log/xtwall.log"

config_dir="/usr/local/etc/xtwall"
config_path="${config_dir}/config.json"
caddy_cert_root="${config_dir}/caddy"
web_root="/var/www/html"

xray_bin="/usr/local/bin/xray"
xray_conf_dir="/usr/local/etc/xray"
xray_asset_dir="/usr/local/share/xray"

caddy_bin="/usr/local/bin/caddy"
caddy_conf="/etc/caddy/Caddyfile"

hysteria_bin="/usr/local/bin/hysteria"
hysteria_conf="/etc/hysteria/config.yaml"
hysteria_cert_dir="${config_dir}/certs"

# 端口约定
REALITY_PORT=443
CADDY_HTTPS_PORT=8443
WS_VLESS_PORT=8080
WS_TROJAN_PORT=8081
SUB_API_PORT=25500

cf_node_default="cf.090227.xyz"

# ============================================================
# 第2节 通用函数
# ============================================================
colorStart="\033["
colorEnd="\033[0m"

RED="0;31m"      # Error message
GREEN="0;32m"    # Success message
LGREEN="1;32m"   # Success message 2
YELLOW="0;33m"   # Warning message
LYELLOW="1;33m"  # Info message 1
BLUE="0;36m"     # Info message 2

colorEcho() {
  echo -e "${colorStart}${1}${@:2}${colorEnd}" 1>&2
}

colorEchoFlush() {
  echo -ne "${colorStart}${1}${@:2}${colorEnd}\r" 1>&2
}

writeLog() {
  while IFS= read -r line; do
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${line}"
  done
}

# 保留被记录命令的退出码，避免管道只返回 writeLog 的成功状态
run_logged() (
  set -o pipefail
  "$@" 2>&1 | writeLog >> "${log_path}"
)

die() {
  colorEcho "${RED}" "$*"
  exit 1
}

# read_json [path-to-file] [jq filter]
read_json() {
  jq --raw-output "$2" "$1" 2>/dev/null | tr -d '\n'
}

# write_json [path-to-file] [jq filter] [raw jq value]
write_json() {
  local file="$1" filter="$2" value="$3"
  local tmp
  [ -f "${file}" ] || return 1
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if jq -r "${filter} = ${value}" "${file}" > "${tmp}" 2>/dev/null; then
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${file}"
    return 0
  fi
  rm -f "${tmp}"
  colorEcho "${RED}" "写入配置失败: ${filter}"
  return 1
}

# 把任意字符串安全地转为 jq 字符串字面量
json_quote() {
  printf '%s' "$1" | jq -Rs .
}

state_get() {
  read_json "${config_path}" "$1"
}

state_set() {
  write_json "${config_path}" "$1" "$2"
}

# fetch_repo [repo 内相对路径] [目标文件]
fetch_repo() {
  local path="$1" dest="$2"
  local tmp="${dest}.part.$$"
  local url
  for url in \
    "https://${jsdelivr}/${REPO}@${branch}/${path}" \
    "https://raw.githubusercontent.com/${REPO}/${branch}/${path}" \
    "https://${gh_proxy}/github.com/${REPO}/raw/${branch}/${path}"; do
    if curl -fsSL --connect-timeout 10 --retry 2 -o "${tmp}" "${url}" 2>/dev/null && [ -s "${tmp}" ]; then
      mv -f "${tmp}" "${dest}"
      return 0
    fi
  done
  rm -f "${tmp}"
  return 1
}

# download_file [目标文件] [url...]  依次尝试，全部失败返回 1
download_file() {
  local dest="$1"
  shift
  local tmp="${dest}.part.$$"
  local url
  for url in "$@"; do
    [ -z "${url}" ] && continue
    if curl -fsSL --connect-timeout 10 --retry 2 -o "${tmp}" "${url}" 2>/dev/null && [ -s "${tmp}" ]; then
      mv -f "${tmp}" "${dest}"
      return 0
    fi
  done
  rm -f "${tmp}"
  return 1
}

# download_release [目标文件] [github 上的路径，如 owner/repo/releases/download/tag/file]
download_release() {
  local dest="$1" path="$2"
  download_file "${dest}" \
    "https://${gh_proxy}/github.com/${path}" \
    "https://github.com/${path}"
}

urlEncode() {
  printf '%s' "$1" | jq -s -R -r @uri
}

urlDecode() {
  printf '%s' "${1//%/\\x}"
}

continue_prompt() {
  local choice
  read -rp "继续其他操作 (Y/N)? " choice
  case "${choice}" in
    [yY] ) return 0 ;;
    * ) exit 0;;
  esac
}

# port_in_use [port] [tcp|udp]
port_in_use() {
  local port="$1" proto="${2:-tcp}"
  if command -v ss >/dev/null 2>&1; then
    if [[ "${proto}" == "udp" ]]; then
      ss -lunp 2>/dev/null | awk 'NR>1 {print $5}' | grep -qE "[:.]${port}$"
    else
      ss -ltnp 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}$"
    fi
  else
    if [[ "${proto}" == "udp" ]]; then
      lsof -nP -iUDP:"${port}" >/dev/null 2>&1
    else
      lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    fi
  fi
}

# 生成随机字符串（不依赖 uuid 文件）
random_hex() {
  local len="${1:-16}"
  if [ -f "/proc/sys/kernel/random/uuid" ]; then
    cat "/proc/sys/kernel/random/uuid" | sed -e 's/-//g' | tr '[:upper:]' '[:lower:]' | head -c "${len}"
  else
    openssl rand -hex 16 | head -c "${len}"
  fi
}

random_uuid() {
  if [ -f "/proc/sys/kernel/random/uuid" ]; then
    cat "/proc/sys/kernel/random/uuid"
  else
    openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
  fi
}

# ============================================================
# 第3节 环境检测
# ============================================================
require_root() {
  if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    colorEcho "${YELLOW}" "您不是 root 用户！请先输入 sudo -i 切换至 root 用户再运行本脚本"
    exit 1
  fi
}

identify_the_operating_system_and_architecture() {
  if [[ "$(uname)" != 'Linux' ]]; then
    die "error: 仅支持 Linux 系统"
  fi

  case "$(uname -m)" in
    'amd64' | 'x86_64')
      XRAY_MACHINE='64'
      BIN_ARCH='amd64'
      ;;
    'armv8' | 'aarch64' | 'arm64')
      XRAY_MACHINE='arm64-v8a'
      BIN_ARCH='arm64'
      ;;
    'armv7l' | 'armv7')
      XRAY_MACHINE='arm32-v7a'
      BIN_ARCH='arm'
      ;;
    *)
      die "error: 不支持的 CPU 架构 $(uname -m)"
      ;;
  esac

  if [[ ! -f '/etc/os-release' ]]; then
    die "error: 请不要使用过旧的 Linux 发行版"
  fi

  if [[ -z "$(ls -l /sbin/init 2>/dev/null | grep systemd)" ]]; then
    die "error: 仅支持使用 systemd 的 Linux 发行版"
  fi

  if [[ "$(command -v apt)" ]]; then
    PACKAGE_MANAGEMENT_UPDATE='apt update'
    PACKAGE_MANAGEMENT_INSTALL='apt install'
    PACKAGE_MANAGEMENT_REMOVE='apt remove'
  elif [[ "$(command -v dnf)" ]]; then
    PACKAGE_MANAGEMENT_UPDATE='dnf makecache'
    PACKAGE_MANAGEMENT_INSTALL='dnf install'
    PACKAGE_MANAGEMENT_REMOVE='dnf remove'
  elif [[ "$(command -v yum)" ]]; then
    PACKAGE_MANAGEMENT_UPDATE='yum makecache'
    PACKAGE_MANAGEMENT_INSTALL='yum install'
    PACKAGE_MANAGEMENT_REMOVE='yum remove'
  elif [[ "$(command -v zypper)" ]]; then
    PACKAGE_MANAGEMENT_UPDATE='zypper refresh'
    PACKAGE_MANAGEMENT_INSTALL='zypper install'
    PACKAGE_MANAGEMENT_REMOVE='zypper remove'
  elif [[ "$(command -v pacman)" ]]; then
    PACKAGE_MANAGEMENT_UPDATE='pacman -Sy'
    PACKAGE_MANAGEMENT_INSTALL='pacman -S --noconfirm'
    PACKAGE_MANAGEMENT_REMOVE='pacman -R'
  else
    die "error: 当前系统的包管理器不受支持"
  fi
}

install_dependencies() {
  ${PACKAGE_MANAGEMENT_UPDATE} -y 2>&1 | writeLog >> "${log_path}"
  ${PACKAGE_MANAGEMENT_INSTALL} curl wget unzip jq lsof coreutils tar openssl -y 2>&1 | writeLog >> "${log_path}"
  local cmd
  for cmd in curl jq unzip tar; do
    command -v "${cmd}" >/dev/null 2>&1 || die "error: 依赖 ${cmd} 安装失败"
  done
  if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
    die "error: 依赖 ss 或 lsof 安装失败"
  fi
}

# ============================================================
# 第4节 状态层
# ============================================================
state_default() {
  cat <<-EOF
{
  "version": "${VERSION}",
  "domain": "",
  "acmeEmail": "",
  "caddy": {
    "installed": false,
    "httpsPort": ${CADDY_HTTPS_PORT},
    "certPath": ""
  },
  "xray": {
    "installed": false,
    "uuid": "",
    "reality": {
      "privateKey": "",
      "publicKey": "",
      "shortId": "",
      "serverNames": []
    },
    "ws": {
      "vlessPort": ${WS_VLESS_PORT},
      "vlessPath": "/ws",
      "trojanPort": ${WS_TROJAN_PORT},
      "trojanPath": "/tj",
      "trojanPassword": ""
    }
  },
  "hysteria": {
    "installed": false,
    "password": "",
    "obfsPassword": "",
    "port": 443
  },
  "sub": {
    "enabled": false,
    "uri": "",
    "cdn": false,
    "cdnDomain": "",
    "cfNode": "${cf_node_default}",
    "nodes": {
      "reality": "",
      "ws": "",
      "trojan": "",
      "hysteria": ""
    },
    "api": {
      "installed": false,
      "port": ${SUB_API_PORT}
    }
  }
}
EOF
}

state_init() {
  mkdir -p "${config_dir}" "${hysteria_cert_dir}"

  if [ ! -f "${config_path}" ]; then
    if ! fetch_repo "config/xtwall.json" "${config_path}" 2>/dev/null; then
      state_default > "${config_path}"
    fi
  fi

  if ! jq -e . "${config_path}" >/dev/null 2>&1; then
    [ -f "${config_path}" ] && cp -f "${config_path}" "${config_path}.corrupt.$(date +%s)"
    state_default > "${config_path}"
    colorEcho "${YELLOW}" "状态文件损坏，已重建默认配置"
  fi

  # 补齐缺失字段，保证旧版本状态文件可平滑升级
  local tmp
  tmp="$(mktemp "${config_path}.XXXXXX")"
  if jq -r '
      .version //= "'"${VERSION}"'" |
      .domain //= "" |
      .acmeEmail //= "" |
      .caddy.installed //= false |
      .caddy.httpsPort //= '"${CADDY_HTTPS_PORT}"' |
      .caddy.certPath //= "" |
      .xray.installed //= false |
      .xray.uuid //= "" |
      .xray.reality.privateKey //= "" |
      .xray.reality.publicKey //= "" |
      .xray.reality.shortId //= "" |
      .xray.reality.serverNames //= [] |
      .xray.ws.vlessPort //= '"${WS_VLESS_PORT}"' |
      .xray.ws.vlessPath //= "/ws" |
      .xray.ws.trojanPort //= '"${WS_TROJAN_PORT}"' |
      .xray.ws.trojanPath //= "/tj" |
      .xray.ws.trojanPassword //= "" |
      .hysteria.installed //= false |
      .hysteria.password //= "" |
      .hysteria.obfsPassword //= "" |
      .hysteria.port //= 443 |
      .sub.enabled //= false |
      .sub.uri //= "" |
      .sub.cdn //= false |
      .sub.cdnDomain //= "" |
      .sub.cfNode //= "'"${cf_node_default}"'" |
      .sub.cfNode |= if . == "icook.tw" then "'"${cf_node_default}"'" else . end |
      .sub.nodes.reality //= "" |
      .sub.nodes.ws //= "" |
      .sub.nodes.trojan //= "" |
      del(.xray.ws.ssPort, .xray.ws.ssPath, .xray.ws.ssPassword, .sub.nodes.ss) |
      .sub.nodes.hysteria //= "" |
      .sub.api.installed //= false |
      .sub.api.port //= '"${SUB_API_PORT}"'
    ' "${config_path}" > "${tmp}" 2>/dev/null; then
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${config_path}"
  else
    rm -f "${tmp}"
  fi
  chmod 600 "${config_path}"
}

# 证书剩余天数，失败返回空
cert_days_left() {
  local cert_file="${1:-}"
  [ -n "${cert_file}" ] || cert_file="$(state_get '.caddy.certPath')"
  if [ -z "${cert_file}" ] || [ ! -f "${cert_file}" ]; then
    echo ""
    return 1
  fi
  local end_date
  end_date="$(openssl x509 -in "${cert_file}" -noout -enddate 2>/dev/null | cut -d= -f2)"
  [ -z "${end_date}" ] && { echo ""; return 1; }
  local end_ts now_ts
  end_ts="$(date -d "${end_date}" +%s 2>/dev/null)"
  now_ts="$(date +%s)"
  [ -z "${end_ts}" ] && { echo ""; return 1; }
  echo $(( (end_ts - now_ts) / 86400 ))
}

check_status() {
  local domain="" xray_installed="false" caddy_installed="false" hy_installed="false"
  local sub_enabled="false" sub_uri="" cdn="false" cdn_domain=""

  if [ -f "${config_path}" ]; then
    domain="$(state_get '.domain')"
    xray_installed="$(state_get '.xray.installed')"
    caddy_installed="$(state_get '.caddy.installed')"
    hy_installed="$(state_get '.hysteria.installed')"
    sub_enabled="$(state_get '.sub.enabled')"
    sub_uri="$(state_get '.sub.uri')"
    cdn="$(state_get '.sub.cdn')"
    cdn_domain="$(state_get '.sub.cdnDomain')"
  fi

  printf "当前域名: "
  if [ -n "${domain}" ]; then
    colorEcho "${GREEN}" "${domain}"
  else
    colorEcho "${YELLOW}" "未设置"
  fi

  printf "已装组件: "
  local components=()
  [ "${caddy_installed}" == "true" ] && components+=("Caddy")
  [ "${xray_installed}" == "true" ] && components+=("Xray-Reality/WS")
  [ "${hy_installed}" == "true" ] && components+=("Hysteria2")
  if [ ${#components[@]} -eq 0 ]; then
    colorEcho "${YELLOW}" "未安装代理"
  else
    colorEcho "${GREEN}" "$(IFS=', '; echo "${components[*]}")"
  fi

  printf "CDN 入口: "
  if [ "${cdn}" == "true" ] && [ -n "${cdn_domain}" ]; then
    colorEcho "${GREEN}" "已开启 (${cdn_domain})"
  elif [ "${cdn}" == "true" ]; then
    colorEcho "${YELLOW}" "已开启但未设置 CDN 域名"
  else
    colorEcho "${BLUE}" "未开启"
  fi

  if [ "${sub_enabled}" == "true" ] && [ -n "${domain}" ] && [ -n "${sub_uri}" ]; then
    local sub_domain="${domain}"
    if [ "${cdn}" == "true" ] && [ -n "${cdn_domain}" ]; then
      sub_domain="${cdn_domain}"
    fi
    printf "订阅链接: "
    colorEcho "${GREEN}" "https://${sub_domain}/${sub_uri}"
  fi

  local days
  days="$(cert_days_left)"
  if [ -n "${days}" ]; then
    printf "证书剩余: "
    if [ "${days}" -gt 15 ]; then
      colorEcho "${GREEN}" "${days} 天"
    elif [ "${days}" -gt 0 ]; then
      colorEcho "${YELLOW}" "${days} 天 (建议检查续期)"
    else
      colorEcho "${RED}" "已过期"
    fi
  fi

  if [[ ! $(cat /proc/swaps 2>/dev/null | wc -l) -gt 1 ]]; then
    colorEcho "${YELLOW}" "检测到 Swap 未开启 建议启用"
  fi

  if [ -f /usr/sbin/aliyun-service ]; then
    colorEcho "${RED}" "检测到阿里云盾服务 建议在 VPS 工具中卸载"
  fi
}

# ============================================================
# 第5节 依赖与二进制
# ============================================================
latest_tag() {
  # latest_tag [owner/repo]
  local repo="$1" tag
  tag="$(curl -sL -m 10 "https://${api_proxy}/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)"
  if [ -z "${tag}" ]; then
    tag="$(curl -sL -m 10 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)"
  fi
  printf '%s' "${tag}"
}

set_caddy_systemd() {
  cat > "/etc/systemd/system/caddy.service" <<-EOF
[Unit]
Description=Caddy web server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=simple
User=caddy
Group=caddy
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=${caddy_bin} run --environ --config ${caddy_conf}
ExecReload=${caddy_bin} reload --config ${caddy_conf} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${caddy_cert_root} ${web_root}
Restart=on-failure
RestartPreventExitStatus=1

[Install]
WantedBy=multi-user.target
EOF
}

get_caddy() {
  local latest_version tag_num pkg tmp_dir
  latest_version="$(latest_tag 'caddyserver/caddy')"
  [ -z "${latest_version}" ] && latest_version="v2.8.4"
  tag_num="${latest_version#v}"
  pkg="caddy_${tag_num}_linux_${BIN_ARCH}.tar.gz"

  mkdir -p "$(dirname "${caddy_conf}")" "${caddy_cert_root}" "${web_root}"

  colorEchoFlush "${BLUE}" "获取 caddy ${latest_version}\r"
  tmp_dir="$(mktemp -d)"
  if ! download_release "${tmp_dir}/${pkg}" "caddyserver/caddy/releases/download/${latest_version}/${pkg}"; then
    rm -rf "${tmp_dir}"
    colorEcho "${RED}" "caddy 下载失败，请检查网络后重试"
    return 1
  fi
  tar -xzf "${tmp_dir}/${pkg}" -C "${tmp_dir}" 2>/dev/null
  install -m 0755 "${tmp_dir}/caddy" "${caddy_bin}"
  rm -rf "${tmp_dir}"

  if ! id caddy >/dev/null 2>&1; then
    useradd -r -M -d "${caddy_cert_root}" -s "$(command -v nologin || echo /usr/sbin/nologin)" caddy 2>/dev/null
  fi
  chown -R caddy:caddy "${caddy_cert_root}" 2>/dev/null
  chmod 755 "${web_root}"

  set_caddy_systemd
  systemctl daemon-reload 2>&1 | writeLog >> "${log_path}"
  systemctl enable caddy 2>&1 | writeLog >> "${log_path}"
  state_set '.caddy.installed' 'true'
  [ -z "$(state_get '.caddy.httpsPort')" ] && state_set '.caddy.httpsPort' "${CADDY_HTTPS_PORT}"
  colorEcho "${LGREEN}" "完成: caddy ${latest_version}"
}

# ============================================================
# 第6节 域名与证书
# ============================================================
checkIP() {
  # checkIP [domain]  解析与真实 IP 一致返回 0
  local domain="$1"
  local realIP4 resolvedIP4 realIP6 resolvedIP6

  realIP4="$(curl -sL --ipv4 -m 5 https://v4.ident.me/ 2>/dev/null)"
  resolvedIP4="$(curl -sSL -m 8 "https://cloudflare-dns.com/dns-query?name=${domain}&type=A" \
    -H 'accept: application/dns-json' 2>/dev/null | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null)"

  [ -n "${realIP4}" ] && printf '%s %s\n' "detected IPv4 address:" "${realIP4}" | writeLog >> "${log_path}"
  [ -n "${resolvedIP4}" ] && printf '%s %s\n' "found A record:" "${resolvedIP4}" | writeLog >> "${log_path}"

  if [ -n "${realIP4}" ] && [ "${realIP4}" == "${resolvedIP4}" ]; then
    echo "A record matched." | writeLog >> "${log_path}"
    return 0
  fi

  realIP6="$(curl -sL --ipv6 -m 5 https://v6.ident.me/ 2>/dev/null)"
  resolvedIP6="$(curl -sSL -m 8 "https://cloudflare-dns.com/dns-query?name=${domain}&type=AAAA" \
    -H 'accept: application/dns-json' 2>/dev/null | jq -r '.Answer[]? | select(.type == 28) | .data' 2>/dev/null)"

  [ -n "${realIP6}" ] && printf '%s %s\n' "detected IPv6 address:" "${realIP6}" | writeLog >> "${log_path}"
  [ -n "${resolvedIP6}" ] && printf '%s %s\n' "found AAAA record:" "${resolvedIP6}" | writeLog >> "${log_path}"

  if [ -n "${realIP6}" ] && [ "${realIP6}" == "${resolvedIP6}" ]; then
    echo "AAAA record matched." | writeLog >> "${log_path}"
    return 0
  fi

  echo "neither A record nor AAAA record matched, return 1" | writeLog >> "${log_path}"
  return 1
}

# 结果写入全局变量 ASK_DOMAIN_RESULT
ask_domain() {
  local prompt="${1:-解析到本 VPS 的域名: }"
  local domain forceConfirm
  ASK_DOMAIN_RESULT=""
  while true; do
    read -rp "${prompt}" domain
    [ -z "${domain}" ] && continue
    if checkIP "${domain}"; then
      colorEcho "${LYELLOW}" "域名 ${domain} 解析正确, 即将继续"
      break
    fi
    colorEcho "${RED}" "域名 ${domain} 解析有误 (Y: 强制继续, N: 重新输入, quit: 离开)"
    read -rp "若您确定域名解析正确, 可强制继续 (Y/N/quit) " forceConfirm
    case "${forceConfirm}" in
      [yY] ) break ;;
      [qQ]|[qQ][uU][iI][tT] ) return 1 ;;
    esac
  done
  ASK_DOMAIN_RESULT="${domain}"
  return 0
}

# build_web [force]  部署默认伪装站点模板到 /var/www/html
build_web() {
  local force="${1:-}"

  if [ -f "${web_root}/index.html" ] && [ "${force}" != "force" ]; then
    echo "伪装站点模板已存在，跳过部署"
    return 0
  fi

  mkdir -p "${web_root}"
  cat > "${web_root}/index.html" <<-EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome</title>
<style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0}</style>
</head>
<body><h1>Hello World</h1></body>
</html>
EOF

  printf 'User-agent: *\nDisallow: /\n' > "${web_root}/robots.txt"
  chmod -R a+rX "${web_root}"
  colorEcho "${LGREEN}" "默认伪装站点模板已部署"
  return 0
}

validate_template_archive() {
  local archive="$1" entries
  case "${archive}" in
    *.tar.gz|*.tgz)
      entries="$(tar -tzf "${archive}" 2>/dev/null)" || return 1
      tar -tvzf "${archive}" 2>/dev/null | awk '
        substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { bad = 1 }
        END { exit bad }
      ' || return 1
      ;;
    *.tar)
      entries="$(tar -tf "${archive}" 2>/dev/null)" || return 1
        tar -tvf "${archive}" 2>/dev/null | awk '
          substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { bad = 1 }
          END { exit bad }
        ' || return 1
      ;;
      *.zip)
        entries="$(unzip -Z -1 "${archive}" 2>/dev/null)" || return 1
        unzip -Z -l "${archive}" 2>/dev/null | awk '
          $1 ~ /^l/ { bad = 1 }
          END { exit bad }
        ' || return 1
      ;;
    *)
      colorEcho "${RED}" "不支持的压缩包格式，请使用 .zip、.tar、.tar.gz 或 .tgz"
      return 1
      ;;
  esac

  printf '%s\n' "${entries}" | awk '
    /^\// { bad = 1 }
    {
      count = split($0, parts, "/")
      for (i = 1; i <= count; i++) {
        if (parts[i] == "..") bad = 1
      }
    }
    END { exit bad }
  '
}

update_web() {
  local input archive_name archive_format archive_suffix tmp_dir extract_dir src_dir top_dir
  read -rp "输入模板站压缩包本地路径或 URL: " input
  [ -n "${input}" ] || { colorEcho "${YELLOW}" "未输入压缩包，已取消"; return 0; }

  archive_format="${input%%\?*}"
  archive_format="${archive_format%%\#*}"
  case "${archive_format}" in
    *.tar.gz) archive_suffix=".tar.gz" ;;
    *.tgz) archive_suffix=".tgz" ;;
    *.tar) archive_suffix=".tar" ;;
    *.zip) archive_suffix=".zip" ;;
    *)
      colorEcho "${RED}" "不支持的压缩包格式，请使用 .zip、.tar、.tar.gz 或 .tgz"
      return 1
      ;;
  esac

  mkdir -p "$(dirname "${web_root}")"
  tmp_dir="$(mktemp -d "$(dirname "${web_root}")/.xtwall-template.XXXXXX")" || {
    colorEcho "${RED}" "无法创建模板站临时目录"
    return 1
  }
  extract_dir="${tmp_dir}/extracted"
  mkdir -p "${extract_dir}"

  case "${input}" in
    http://*|https://*)
      archive_name="${tmp_dir}/template${archive_suffix}"
      if ! download_file "${archive_name}" "${input}"; then
        rm -rf "${tmp_dir}"
        colorEcho "${RED}" "模板站压缩包下载失败"
        return 1
      fi
      ;;
    *)
      if [ ! -f "${input}" ]; then
        rm -rf "${tmp_dir}"
        colorEcho "${RED}" "找不到压缩包: ${input}"
        return 1
      fi
      archive_name="${input}"
      ;;
  esac

  if ! validate_template_archive "${archive_name}"; then
    rm -rf "${tmp_dir}"
    colorEcho "${RED}" "压缩包无效或包含不安全路径"
    return 1
  fi

  case "${archive_format}" in
    *.tar.gz|*.tgz) tar -xzf "${archive_name}" -C "${extract_dir}" ;;
    *.tar) tar -xf "${archive_name}" -C "${extract_dir}" ;;
    *.zip) unzip -q "${archive_name}" -d "${extract_dir}" ;;
    *)
      rm -rf "${tmp_dir}"
      colorEcho "${RED}" "不支持的压缩包格式，请使用 .zip、.tar、.tar.gz 或 .tgz"
      return 1
      ;;
  esac
  if [ $? -ne 0 ]; then
    rm -rf "${tmp_dir}"
    colorEcho "${RED}" "模板站压缩包解压失败"
    return 1
  fi

  if [ -f "${extract_dir}/index.html" ]; then
    src_dir="${extract_dir}"
  else
    top_dir="$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    if [ -z "${top_dir}" ] || [ ! -f "${top_dir}/index.html" ] \
       || [ -n "$(find "${extract_dir}" -mindepth 1 -maxdepth 1 ! -type d -print -quit)" ] \
       || [ -n "$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d ! -path "${top_dir}" -print -quit)" ]; then
      rm -rf "${tmp_dir}"
      colorEcho "${RED}" "压缩包中未找到根目录或单一顶层目录下的 index.html"
      return 1
    fi
    src_dir="${top_dir}"
  fi

  mkdir -p "${tmp_dir}/new-site"
  cp -a "${src_dir}/." "${tmp_dir}/new-site/" || {
    rm -rf "${tmp_dir}"
    colorEcho "${RED}" "准备模板站文件失败"
    return 1
  }
  chmod -R a+rX "${tmp_dir}/new-site"

  if [ -e "${web_root}" ] && ! mv "${web_root}" "${tmp_dir}/old-site"; then
    rm -rf "${tmp_dir}"
    colorEcho "${RED}" "无法备份现有伪装站点"
    return 1
  fi
  if ! mv "${tmp_dir}/new-site" "${web_root}"; then
    [ -e "${tmp_dir}/old-site" ] && mv "${tmp_dir}/old-site" "${web_root}"
    rm -rf "${tmp_dir}"
    colorEcho "${RED}" "更新伪装站点模板失败，已尝试恢复旧站点"
    return 1
  fi

  rm -rf "${tmp_dir}"
  colorEcho "${LGREEN}" "伪装站点模板更新完成"
}

caddy_site_block() {
  # caddy_site_block [域名] [vless path] [trojan path]
  local d="$1" vless_path="$2" trojan_path="$3"
  cat <<EOF

# ${d}: 伪装站与 WS 反代，由 Reality dest 回落或 CDN 回源命中
https://${d}:${CADDY_HTTPS_PORT} {
	bind 127.0.0.1
	encode zstd gzip
	tls {
		issuer acme {
			disable_tlsalpn_challenge
		}
	}

	@subapi path /sub*
	handle @subapi {
		reverse_proxy 127.0.0.1:${SUB_API_PORT}
	}

	@vlessws path ${vless_path}
	handle @vlessws {
		reverse_proxy 127.0.0.1:${WS_VLESS_PORT}
	}

	@trojanws path ${trojan_path}
	handle @trojanws {
		reverse_proxy 127.0.0.1:${WS_TROJAN_PORT}
	}

	handle {
		root * ${web_root}
		file_server
	}
}
EOF
}

caddy_http_block() {
  local d="$1"
  cat <<EOF

# 80 端口仅用于 ACME HTTP-01 验证与跳转
http://${d} {
	redir https://{host}{uri} permanent
}
EOF
}

caddy_masquerade_block() {
  cat <<EOF

# 兜底站点：Hysteria2 masquerade 以 127.0.0.1 访问 8443 时命中此处
https://:${CADDY_HTTPS_PORT} {
	bind 127.0.0.1
	tls internal
	root * ${web_root}
	file_server
}
EOF
}

set_caddyfile() {
  # set_caddyfile [yes|no]  no 表示不生成兜底站点（旧版 caddy 不支持时自动降级）
  local domain email vless_path trojan_path cdn_domain with_fallback
  with_fallback="${1:-yes}"
  domain="$(state_get '.domain')"
  email="$(state_get '.acmeEmail')"
  vless_path="$(state_get '.xray.ws.vlessPath')"
  trojan_path="$(state_get '.xray.ws.trojanPath')"
  cdn_domain="$(state_get '.sub.cdnDomain')"

  [ -z "${domain}" ] && { colorEcho "${RED}" "尚未设置域名"; return 1; }
  [ -z "${vless_path}" ] && vless_path="/ws"
  [ -z "${trojan_path}" ] && trojan_path="/tj"
  [ "${cdn_domain}" == "${domain}" ] && cdn_domain=""

  if [ -z "${email}" ]; then
    email="xtwall-$(random_hex 6)@${domain}"
    state_set '.acmeEmail' "$(json_quote "${email}")"
  fi

  mkdir -p "$(dirname "${caddy_conf}")"
  [ -f "${caddy_conf}" ] && cp -a "${caddy_conf}" "${caddy_conf}.bak.$(date +%s)"

  {
    cat <<EOF
{
	admin off
	email ${email}
	auto_https disable_redirects
	storage file_system {
		root ${caddy_cert_root}
	}
	servers {
		protocols h1 h2
	}
}
EOF
    caddy_site_block "${domain}" "${vless_path}" "${trojan_path}"
    if [ -n "${cdn_domain}" ]; then
      caddy_site_block "${cdn_domain}" "${vless_path}" "${trojan_path}"
    fi
    caddy_http_block "${domain}"
    if [ -n "${cdn_domain}" ]; then
      caddy_http_block "${cdn_domain}"
    fi
    if [ "${with_fallback}" == "yes" ]; then
      caddy_masquerade_block
    fi
  } > "${caddy_conf}"

  if ! run_logged "${caddy_bin}" validate --config "${caddy_conf}" --adapter caddyfile; then
    if [ "${with_fallback}" == "yes" ]; then
      colorEcho "${YELLOW}" "兜底站点不被当前 caddy 接受，降级为无兜底站点模式"
      set_caddyfile no
      return $?
    fi
    colorEcho "${RED}" "Caddyfile 校验失败"
    local bak
    bak="$(ls -1t "${caddy_conf}".bak.* 2>/dev/null | head -n 1)"
    [ -n "${bak}" ] && mv -f "${bak}" "${caddy_conf}"
    return 1
  fi
  return 0
}

# 等待 Caddy 完成 ACME 签发，最长 120s
# wait_caddy_cert [域名] [no-state]  no-state 时不覆盖主域证书路径
wait_caddy_cert() {
  local domain="$1" keep_state="${2:-}" i cert
  for i in $(seq 1 60); do
    cert="$(find "${caddy_cert_root}/certificates" -type f -name "${domain}.crt" 2>/dev/null | head -n 1)"
    if [ -n "${cert}" ]; then
      if [ "${keep_state}" != "no-state" ]; then
        state_set '.caddy.certPath' "$(json_quote "${cert}")"
      fi
      return 0
    fi
    sleep 2
  done
  return 1
}

cert_status() {
  printf "\n"
  local domain cdn_domain d label cert_file days
  domain="$(state_get '.domain')"
  cdn_domain="$(state_get '.sub.cdnDomain')"

  if [ -z "${domain}" ]; then
    colorEcho "${YELLOW}" "尚未设置域名"
    printf "\n"
    return 0
  fi

  local -a domains=("${domain}")
  if [ -n "${cdn_domain}" ] && [ "${cdn_domain}" != "${domain}" ]; then
    domains+=("${cdn_domain}")
  fi

  for d in "${domains[@]}"; do
    label="[Caddy]"
    cert_file=""
    if [ "${d}" == "${domain}" ]; then
      cert_file="$(state_get '.caddy.certPath')"
    else
      label="[CDN]"
    fi
    if [ -z "${cert_file}" ] || [ ! -f "${cert_file}" ]; then
      cert_file="$(find "${caddy_cert_root}/certificates" -type f -name "${d}.crt" 2>/dev/null | head -n 1)"
    fi

    printf "%s\t%s\t" "${label}" "${d}" | expand -t 16
    if [ -n "${cert_file}" ] && [ -f "${cert_file}" ]; then
      days="$(cert_days_left "${cert_file}")"
      if [ -n "${days}" ] && [ "${days}" -gt 0 ]; then
        colorEcho "${GREEN}" "正常 (剩余 ${days} 天)"
      else
        colorEcho "${RED}" "异常 (证书已过期)"
      fi
    else
      colorEcho "${RED}" "异常 (未找到证书)"
    fi
  done

  printf "%s\t%s\t" "[服务]" "caddy" | expand -t 16
  if systemctl is-active --quiet caddy; then
    colorEcho "${GREEN}" "运行中"
  else
    colorEcho "${RED}" "未运行"
  fi

  printf "\n"
}

# ============================================================
# 第7节 Xray
# ============================================================
backup_file() {
  local file="$1"
  [ -f "${file}" ] && cp -a "${file}" "${file}.bak.$(date +%s)"
  return 0
}

restore_latest_backup() {
  local file="$1" bak
  bak="$(ls -1t "${file}".bak.* 2>/dev/null | head -n 1)"
  if [ -n "${bak}" ]; then
    mv -f "${bak}" "${file}"
    return 0
  fi
  return 1
}

set_xray_systemd() {
  cat > "/etc/systemd/system/xray.service" <<-EOF
[Unit]
Description=Xray - A unified platform for anti-censorship
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
Environment=XRAY_LOCATION_ASSET=${xray_asset_dir}
ExecStart=${xray_bin} run -confdir ${xray_conf_dir}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
}

get_xray() {
  local latest_version xray_link tmp_dir
  latest_version="$(latest_tag 'XTLS/Xray-core')"
  [ -z "${latest_version}" ] && latest_version="v1.8.24"
  xray_link="XTLS/Xray-core/releases/download/${latest_version}/Xray-linux-${XRAY_MACHINE}.zip"

  mkdir -p "${xray_conf_dir}" "${xray_asset_dir}"

  colorEchoFlush "${BLUE}" "获取 xray-core ${latest_version}\r"
  tmp_dir="$(mktemp -d)"
  if ! download_release "${tmp_dir}/xray-core.zip" "${xray_link}"; then
    rm -rf "${tmp_dir}"
    colorEcho "${RED}" "xray-core 下载失败，请检查网络后重试"
    return 1
  fi
  unzip -q -o "${tmp_dir}/xray-core.zip" -d "${tmp_dir}"
  install -m 0755 "${tmp_dir}/xray" "${xray_bin}"
  [ -f "${tmp_dir}/geoip.dat" ] && install -m 0644 "${tmp_dir}/geoip.dat" "${xray_asset_dir}/geoip.dat"
  [ -f "${tmp_dir}/geosite.dat" ] && install -m 0644 "${tmp_dir}/geosite.dat" "${xray_asset_dir}/geosite.dat"
  rm -rf "${tmp_dir}"

  set_xray_systemd
  systemctl daemon-reload 2>&1 | writeLog >> "${log_path}"
  systemctl enable xray 2>&1 | writeLog >> "${log_path}"
  state_set '.xray.installed' 'true'
  colorEcho "${LGREEN}" "完成: xray-core ${latest_version}"
}

# 生成 Reality 密钥对，结果写入 REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY
reality_keypair() {
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  local out priv pub
  out="$("${xray_bin}" x25519 2>/dev/null)"
  priv="$(printf '%s\n' "${out}" | grep -iE 'private' | head -n 1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r')"
  pub="$(printf '%s\n' "${out}" | grep -iE 'public|password' | head -n 1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r')"
  if [ -z "${pub}" ] && [ -n "${priv}" ]; then
    pub="$("${xray_bin}" x25519 -i "${priv}" 2>/dev/null | grep -iE 'public|password' | head -n 1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r')"
  fi
  if [ -z "${priv}" ] || [ -z "${pub}" ]; then
    return 1
  fi
  REALITY_PRIVATE_KEY="${priv}"
  REALITY_PUBLIC_KEY="${pub}"
  return 0
}

set_xray_static() {
  backup_file "${xray_conf_dir}/03_routing.json"
  cat > "${xray_conf_dir}/03_routing.json" <<-EOF
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

  backup_file "${xray_conf_dir}/06_outbounds.json"
  cat > "${xray_conf_dir}/06_outbounds.json" <<-EOF
{
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ]
}
EOF
}

set_xray_config() {
  local domain uuid vless_path trojan_path trojan_pwd short_id
  domain="$(state_get '.domain')"
  [ -z "${domain}" ] && { colorEcho "${RED}" "尚未设置域名"; return 1; }

  uuid="$(state_get '.xray.uuid')"
  [ -z "${uuid}" ] && uuid="$(random_uuid)"

  vless_path="$(state_get '.xray.ws.vlessPath')"
  trojan_path="$(state_get '.xray.ws.trojanPath')"
  [ -z "${vless_path}" ] && vless_path="/ws"
  [ -z "${trojan_path}" ] && trojan_path="/tj"

  trojan_pwd="$(state_get '.xray.ws.trojanPassword')"
  [ -z "${trojan_pwd}" ] && trojan_pwd="$(random_hex 16)"

  short_id="$(state_get '.xray.reality.shortId')"
  [ -z "${short_id}" ] && short_id="$(random_hex 8)"

  # 已有密钥必须复用，否则换域名 / 重装会把老客户端全部踢下线
  if [ -n "$(state_get '.xray.reality.privateKey')" ] && [ -n "$(state_get '.xray.reality.publicKey')" ]; then
    REALITY_PRIVATE_KEY="$(state_get '.xray.reality.privateKey')"
    REALITY_PUBLIC_KEY="$(state_get '.xray.reality.publicKey')"
  elif ! reality_keypair; then
    colorEcho "${RED}" "生成 Reality 密钥失败，请确认 ${xray_bin} 可执行"
    return 1
  fi

  mkdir -p "${xray_conf_dir}"
  # 兼容旧版本：Shadowsocks 入站已移除
  rm -f "${xray_conf_dir}/12_inbounds_ss_ws.json"

  # 443/TCP: VLESS Reality，非 Reality 握手原样中继给本地 Caddy
  backup_file "${xray_conf_dir}/05_inbounds_reality.json"
  cat > "${xray_conf_dir}/05_inbounds_reality.json" <<-EOF
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "127.0.0.1:${CADDY_HTTPS_PORT}",
          "xver": 0,
          "serverNames": [
            "${domain}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            "${short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      },
      "tag": "reality"
    }
  ]
}
EOF

  # 127.0.0.1:8080 VLESS over WS，由 Caddy /ws 反代
  backup_file "${xray_conf_dir}/10_inbounds_vless_ws.json"
  cat > "${xray_conf_dir}/10_inbounds_vless_ws.json" <<-EOF
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${WS_VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${vless_path}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      },
      "tag": "vless_ws"
    }
  ]
}
EOF

  # 127.0.0.1:8081 Trojan over WS，由 Caddy /tj 反代
  backup_file "${xray_conf_dir}/11_inbounds_trojan_ws.json"
  cat > "${xray_conf_dir}/11_inbounds_trojan_ws.json" <<-EOF
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${WS_TROJAN_PORT},
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${trojan_pwd}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${trojan_path}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      },
      "tag": "trojan_ws"
    }
  ]
}
EOF

  set_xray_static

  state_set '.xray.uuid' "$(json_quote "${uuid}")"
  state_set '.xray.ws.trojanPassword' "$(json_quote "${trojan_pwd}")"
  state_set '.xray.reality.privateKey' "$(json_quote "${REALITY_PRIVATE_KEY}")"
  state_set '.xray.reality.publicKey' "$(json_quote "${REALITY_PUBLIC_KEY}")"
  state_set '.xray.reality.shortId' "$(json_quote "${short_id}")"
  state_set '.xray.reality.serverNames' "[\"${domain}\"]"

  return 0
}

xray_validate() {
  if run_logged "${xray_bin}" run -test -confdir "${xray_conf_dir}"; then
    return 0
  fi
  colorEcho "${RED}" "xray 配置校验失败，正在回滚"
  local f
  for f in "${xray_conf_dir}"/05_inbounds_reality.json \
           "${xray_conf_dir}"/10_inbounds_vless_ws.json \
           "${xray_conf_dir}"/11_inbounds_trojan_ws.json; do
    restore_latest_backup "${f}"
  done
  return 1
}

# ============================================================
# 第8节 Hysteria2
# ============================================================
set_hysteria_systemd() {
  mkdir -p "$(dirname "${hysteria_conf}")"
  cat > "/etc/systemd/system/hysteria.service" <<-EOF
[Unit]
Description=Hysteria2 Server
Documentation=https://v2.hysteria.network/
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${hysteria_bin} server --config ${hysteria_conf}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

get_hysteria() {
  local latest_version bin_name tmp_dir
  latest_version="$(latest_tag 'apernet/hysteria')"
  [ -z "${latest_version}" ] && latest_version="app/v2.6.5"
  bin_name="hysteria-linux-${BIN_ARCH}"

  colorEchoFlush "${BLUE}" "获取 hysteria ${latest_version}\r"
  tmp_dir="$(mktemp -d)"
  if ! download_release "${tmp_dir}/hysteria" "apernet/hysteria/releases/download/${latest_version}/${bin_name}"; then
    rm -rf "${tmp_dir}"
    colorEcho "${RED}" "hysteria 下载失败，请检查网络后重试"
    return 1
  fi
  install -m 0755 "${tmp_dir}/hysteria" "${hysteria_bin}"
  rm -rf "${tmp_dir}"

  set_hysteria_systemd
  systemctl daemon-reload 2>&1 | writeLog >> "${log_path}"
  systemctl enable hysteria 2>&1 | writeLog >> "${log_path}"
  state_set '.hysteria.installed' 'true'
  colorEcho "${LGREEN}" "完成: hysteria ${latest_version}"
}

set_hysteria_config() {
  local domain pwd obfs_pwd masquerade
  domain="$(state_get '.domain')"
  [ -z "${domain}" ] && { colorEcho "${RED}" "尚未设置域名"; return 1; }

  pwd="$(state_get '.hysteria.password')"
  [ -z "${pwd}" ] && pwd="$(random_hex 16)"
  obfs_pwd="$(state_get '.hysteria.obfsPassword')"
  [ -z "${obfs_pwd}" ] && obfs_pwd="$(random_hex 16)"

  mkdir -p "$(dirname "${hysteria_conf}")" "${hysteria_cert_dir}"
  [ -f "${hysteria_conf}" ] && cp -a "${hysteria_conf}" "${hysteria_conf}.bak.$(date +%s)"

  # 8443 有兜底站点时用反向代理伪装成 mikutap，否则退化为静态页面
  if grep -q "^https://:${CADDY_HTTPS_PORT}" "${caddy_conf}" 2>/dev/null; then
    masquerade="masquerade:
  type: proxy
  proxy:
    url: https://127.0.0.1:${CADDY_HTTPS_PORT}
    rewriteHost: true
    insecure: true"
  else
    masquerade="masquerade:
  type: string
  string:
    statusCode: 200
    headers:
      content-type: text/html; charset=utf-8
    body: |
      <!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><title>Welcome</title></head><body><h1>Hello World</h1></body></html>"
  fi

  cat > "${hysteria_conf}" <<-EOF
listen: :${REALITY_PORT}

tls:
  cert: ${hysteria_cert_dir}/fullchain.pem
  key: ${hysteria_cert_dir}/privkey.pem

auth:
  type: password
  password: ${pwd}

obfs:
  type: salamander
  salamander:
    password: ${obfs_pwd}

${masquerade}
EOF
  chmod 600 "${hysteria_conf}"

  state_set '.hysteria.password' "$(json_quote "${pwd}")"
  state_set '.hysteria.obfsPassword' "$(json_quote "${obfs_pwd}")"
  state_set '.hysteria.port' "${REALITY_PORT}"
  return 0
}

# 从 Caddy 证书目录同步证书到 hysteria，指纹变化才重启
cert_sync() {
  local domain src_cert src_key
  domain="$(state_get '.domain')"
  [ -z "${domain}" ] && return 0

  src_cert="$(find "${caddy_cert_root}/certificates" -type f -name "${domain}.crt" 2>/dev/null | head -n 1)"
  src_key="$(find "${caddy_cert_root}/certificates" -type f -name "${domain}.key" 2>/dev/null | head -n 1)"
  if [ -z "${src_cert}" ] || [ -z "${src_key}" ]; then
    return 1
  fi

  mkdir -p "${hysteria_cert_dir}"
  state_set '.caddy.certPath' "$(json_quote "${src_cert}")"

  if cmp -s "${src_cert}" "${hysteria_cert_dir}/fullchain.pem" \
     && cmp -s "${src_key}" "${hysteria_cert_dir}/privkey.pem"; then
    return 0
  fi

  install -m 0644 "${src_cert}" "${hysteria_cert_dir}/fullchain.pem"
  install -m 0600 "${src_key}" "${hysteria_cert_dir}/privkey.pem"
  if systemctl is-active --quiet hysteria; then
    systemctl restart hysteria 2>&1 | writeLog >> "${log_path}"
  fi
  echo "certificates synced for ${domain}" | writeLog >> "${log_path}"
  return 0
}

# ============================================================
# 第9节 分享与订阅
# ============================================================
node_reality() {
  local domain uuid pub sid
  domain="$(state_get '.domain')"
  uuid="$(state_get '.xray.uuid')"
  pub="$(state_get '.xray.reality.publicKey')"
  sid="$(state_get '.xray.reality.shortId')"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s' \
    "${uuid}" "${domain}" "${REALITY_PORT}" "${domain}" "${pub}" "${sid}" "$(urlEncode "${domain} Reality")"
}

# cdn 形态：SNI/Host 用 CDN 域，连接地址优先用 CF 优选节点，否则直连 CDN 域
# 输出 CDN_WS_HOST / CDN_WS_ADDR 供 node_* 复用
cdn_wsvars() {
  local domain
  domain="$(state_get '.domain')"
  CDN_WS_HOST="$(state_get '.sub.cdnDomain')"
  if [ -z "${CDN_WS_HOST}" ] || [ "${CDN_WS_HOST}" == "${domain}" ]; then
    CDN_WS_HOST="${domain}"
    CDN_WS_ADDR="${domain}"
    return 1
  fi
  CDN_WS_ADDR="$(state_get '.sub.cfNode')"
  [ -z "${CDN_WS_ADDR}" ] && CDN_WS_ADDR="${CDN_WS_HOST}"
  return 0
}

# node_vless_ws [direct|cdn]
node_vless_ws() {
  local mode="${1:-direct}" domain uuid path host addr name
  domain="$(state_get '.domain')"
  uuid="$(state_get '.xray.uuid')"
  path="$(state_get '.xray.ws.vlessPath')"
  if [ "${mode}" == "cdn" ] && cdn_wsvars; then
    host="${CDN_WS_HOST}"
    addr="${CDN_WS_ADDR}"
    name="${host} WS-CDN"
  else
    host="${domain}"
    addr="${domain}"
    name="${domain} WS"
  fi
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s' \
    "${uuid}" "${addr}" "${host}" "${host}" "$(urlEncode "${path}")" "$(urlEncode "${name}")"
}

# node_trojan [direct|cdn]
node_trojan() {
  local mode="${1:-direct}" domain pwd path host addr name
  domain="$(state_get '.domain')"
  pwd="$(state_get '.xray.ws.trojanPassword')"
  path="$(state_get '.xray.ws.trojanPath')"
  if [ "${mode}" == "cdn" ] && cdn_wsvars; then
    host="${CDN_WS_HOST}"
    addr="${CDN_WS_ADDR}"
    name="${host} Trojan-CDN"
  else
    host="${domain}"
    addr="${domain}"
    name="${domain} Trojan"
  fi
  printf 'trojan://%s@%s:443?security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
    "${pwd}" "${addr}" "${host}" "${host}" "$(urlEncode "${path}")" "$(urlEncode "${name}")"
}

node_hysteria() {
  local domain pwd obfs
  domain="$(state_get '.domain')"
  pwd="$(state_get '.hysteria.password')"
  obfs="$(state_get '.hysteria.obfsPassword')"
  printf 'hysteria2://%s@%s:%s/?sni=%s&obfs=salamander&obfs-password=%s#%s' \
    "$(urlEncode "${pwd}")" "${domain}" "${REALITY_PORT}" "${domain}" "${obfs}" "$(urlEncode "${domain} Hysteria2")"
}

show_links() {
  local domain cdn
  domain="$(state_get '.domain')"
  if [ -z "${domain}" ]; then
    colorEcho "${RED}" "尚未设置域名，请先安装"
    return 1
  fi
  cdn="$(state_get '.sub.cdn')"

  if [ "$(state_get '.xray.installed')" == "true" ]; then
    colorEcho "${YELLOW}" "===============分 享 链 接 (直连)==============="

    colorEcho "${BLUE}" "VLESS Reality"
    printf "%s\n\n" "$(node_reality)"

    colorEcho "${BLUE}" "VLESS WS"
    printf "%s\n\n" "$(node_vless_ws direct)"

    colorEcho "${BLUE}" "Trojan WS"
    printf "%s\n\n" "$(node_trojan direct)"
  fi

  if [ "$(state_get '.hysteria.installed')" == "true" ]; then
    colorEcho "${BLUE}" "Hysteria2"
    printf "%s\n\n" "$(node_hysteria)"
  fi

  if [ "${cdn}" == "true" ]; then
    colorEcho "${YELLOW}" "===============分 享 链 接 (CDN)==============="
    if cdn_wsvars; then
      colorEcho "${LYELLOW}" "CDN 域名: ${CDN_WS_HOST}"
      colorEcho "${LYELLOW}" "连接地址: ${CDN_WS_ADDR}"
      printf "%s\n\n" "$(node_vless_ws cdn)"
      printf "%s\n\n" "$(node_trojan cdn)"
    else
      colorEcho "${YELLOW}" "尚未设置 CDN 域名，请先在 7) CDN 域名与开关 中配置"
    fi
  fi

  colorEcho "${YELLOW}" "========================================"
}

# 构建节点列表到全局数组 SUB_NODES
sub_build_nodes() {
  SUB_NODES=()
  local cdn
  cdn="$(state_get '.sub.cdn')"

  if [ "$(state_get '.xray.installed')" == "true" ]; then
    local n_reality n_ws n_trojan
    n_reality="$(node_reality)"
    n_ws="$(node_vless_ws direct)"
    n_trojan="$(node_trojan direct)"
    SUB_NODES+=("${n_reality}" "${n_ws}" "${n_trojan}")

    state_set '.sub.nodes.reality' "$(json_quote "${n_reality}")"
    state_set '.sub.nodes.ws' "$(json_quote "${n_ws}")"
    state_set '.sub.nodes.trojan' "$(json_quote "${n_trojan}")"

    if [ "${cdn}" == "true" ] && cdn_wsvars; then
      SUB_NODES+=("$(node_vless_ws cdn)" "$(node_trojan cdn)")
    fi
  fi

  if [ "$(state_get '.hysteria.installed')" == "true" ]; then
    local n_hy
    n_hy="$(node_hysteria)"
    SUB_NODES+=("${n_hy}")
    state_set '.sub.nodes.hysteria' "$(json_quote "${n_hy}")"
  fi

  [ ${#SUB_NODES[@]} -eq 0 ] && return 1
  return 0
}

sub_write_file() {
  local uri="$1"
  mkdir -p "${web_root}"
  printf '%s\n' "${SUB_NODES[@]}" | base64 --wrap=0 > "${web_root}/${uri}"
  chmod 644 "${web_root}/${uri}"
}

gen_sub() {
  if [ "$(state_get '.xray.installed')" != "true" ] && [ "$(state_get '.hysteria.installed')" != "true" ]; then
    colorEcho "${RED}" "尚末安装 Xray 或 Hysteria2"
    return 1
  fi

  if ! sub_build_nodes; then
    colorEcho "${RED}" "没有可用节点"
    return 1
  fi

  local old_uri new_uri
  old_uri="$(state_get '.sub.uri')"
  if [ -n "${old_uri}" ] && [ -f "${web_root}/${old_uri}" ]; then
    rm -f "${web_root}/${old_uri}"
  fi

  new_uri="$(random_hex 16)"
  state_set '.sub.uri' "$(json_quote "${new_uri}")"
  state_set '.sub.enabled' 'true'
  sub_write_file "${new_uri}"

  colorEcho "${LGREEN}" "己生成订阅"
  display_sub
}

update_sub() {
  if [ "$(state_get '.sub.enabled')" != "true" ] || [ -z "$(state_get '.sub.uri')" ]; then
    gen_sub
    return 0
  fi
  if ! sub_build_nodes; then
    colorEcho "${RED}" "没有可用节点"
    return 1
  fi
  sub_write_file "$(state_get '.sub.uri')"
  colorEcho "${LGREEN}" "己更新订阅"
  display_sub
}

display_sub() {
  local domain uri sub_url qr_data cdn_domain
  if [ "$(state_get '.sub.enabled')" != "true" ]; then
    colorEcho "${YELLOW}" "你还没有生成订阅链接, 请先选择\"生成订阅\""
    return 1
  fi
  domain="$(state_get '.domain')"
  cdn_domain="$(state_get '.sub.cdnDomain')"
  # 开启 CDN 且已配置 CDN 域名时，订阅链接只给 CDN 域
  if [ "$(state_get '.sub.cdn')" == "true" ] && [ -n "${cdn_domain}" ]; then
    domain="${cdn_domain}"
  fi
  uri="$(state_get '.sub.uri')"
  sub_url="https://${domain}/${uri}"
  qr_data="$(printf '%s' "sub://${sub_url}" | base64 --wrap=0)"

  printf "%s\n" "${sub_url}"
  printf '%s\n\n' "二维码: https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=sub://${qr_data}"

  if [ "$(state_get '.sub.api.installed')" == "true" ]; then
    local api_prefix
    api_prefix="https://${domain}/sub?url=$(urlEncode "${sub_url}")&target="
    colorEcho "${YELLOW}" "Clash"
    printf "%s\n" "${api_prefix}clash"
    colorEcho "${YELLOW}" "QuantumultX"
    printf "%s\n" "${api_prefix}quanx"
    colorEcho "${YELLOW}" "Loon"
    printf "%s\n\n" "${api_prefix}loon"
  fi
}

# 读取 CDN 域名到 ASK_DOMAIN_RESULT，不做 IP 校验（橙云会解析到 Cloudflare 地址）
ask_cdn_domain() {
  local input
  ASK_DOMAIN_RESULT=""
  while true; do
    read -rp "CDN 域名 (需已在 Cloudflare 开启橙云并回源本机): " input
    if [ -z "${input}" ]; then
      colorEcho "${YELLOW}" "未输入域名，已取消"
      return 1
    fi
    if [ "${input}" == "$(state_get '.domain')" ]; then
      colorEcho "${RED}" "CDN 域名不能与直连域名相同"
      colorEcho "${RED}" "Reality 与 Hysteria2 必须绑定未经 CDN 的直连域名"
      continue
    fi
    ASK_DOMAIN_RESULT="${input}"
    return 0
  done
}

toggle_cdn() {
  local domain cdn_domain current choice confirm
  domain="$(state_get '.domain')"
  if [ -z "${domain}" ]; then
    colorEcho "${RED}" "尚未设置域名，请先安装"
    return 1
  fi
  cdn_domain="$(state_get '.sub.cdnDomain')"
  current="$(state_get '.sub.cdn')"

  echo ""
  colorEcho "${YELLOW}" "直连域: ${domain}  -> Reality / Hysteria2（不经 CDN）"
  if [ -n "${cdn_domain}" ]; then
    if [ "${current}" == "true" ]; then
      colorEcho "${YELLOW}" "CDN  域: ${cdn_domain}  -> VLESS-WS / Trojan-WS / 订阅（已启用）"
    else
      colorEcho "${YELLOW}" "CDN  域: ${cdn_domain}  -> VLESS-WS / Trojan-WS / 订阅（未启用）"
    fi
  else
    colorEcho "${BLUE}" "CDN  域: 未设置"
  fi
  echo ""
  echo "1) 开启 / 更换 CDN 域名"
  echo "2) 关闭 CDN 入口"
  echo "3) 清除 CDN 域名"
  echo "4) 返回"
  echo ""
  read -rp "选择操作 [输入任意值返回]: " choice

  case "${choice}" in
    "1")
      if ! ask_cdn_domain; then
        return 0
      fi
      cdn_domain="${ASK_DOMAIN_RESULT}"
      colorEcho "${YELLOW}" "请确认已把 ${cdn_domain} 解析到 Cloudflare 并开启橙云（回源本机）"
      colorEcho "${YELLOW}" "Reality 与 Hysteria2 仍使用直连域 ${domain}，不受影响"
      read -rp "确认写入并重载 Caddy (Y/N)? " confirm
      case "${confirm}" in
        [yY]|[yY][eE][sS] ) ;;
        * ) return 0 ;;
      esac

      state_set '.sub.cdnDomain' "$(json_quote "${cdn_domain}")"
      state_set '.sub.cdn' 'true'
      if set_caddyfile; then
        systemctl restart caddy 2>&1 | writeLog >> "${log_path}"
        colorEchoFlush "${BLUE}" "等待 ${cdn_domain} 证书签发\r"
        if wait_caddy_cert "${cdn_domain}" no-state; then
          colorEcho "${LGREEN}" "完成: ${cdn_domain} 证书已就绪"
        else
          colorEcho "${YELLOW}" "证书尚未就绪，请确认 Cloudflare 已放行 /.well-known 且 SSL 模式非 Off"
        fi
        colorEcho "${GREEN}" "CDN 入口已开启 (${cdn_domain})"
      else
        colorEcho "${RED}" "Caddyfile 生成失败，CDN 域名未生效"
        return 1
      fi
      ;;

    "2")
      [ "${current}" == "true" ] || { colorEcho "${YELLOW}" "CDN 入口本就未开启"; return 0; }
      state_set '.sub.cdn' 'false'
      colorEcho "${GREEN}" "CDN 入口已关闭，节点恢复为直连域"
      ;;

    "3")
      if [ -z "${cdn_domain}" ]; then
        colorEcho "${YELLOW}" "尚未设置 CDN 域名"
        return 0
      fi
      state_set '.sub.cdnDomain' '""'
      state_set '.sub.cdn' 'false'
      if set_caddyfile; then
        systemctl restart caddy 2>&1 | writeLog >> "${log_path}"
      fi
      colorEcho "${GREEN}" "CDN 域名已清除"
      cdn_domain=""
      ;;

    * ) return 0 ;;
  esac

  if [ "$(state_get '.sub.enabled')" == "true" ]; then
    update_sub >/dev/null
  fi
  show_links
}

edit_cf_node() {
  local cf_node_current cf_node_new
  cf_node_current="$(state_get '.sub.cfNode')"
  printf "%s\n" "CF 节点仅作为 CDN 节点的连接地址，SNI 与 Host 仍为 CDN 域名"
  printf "%s\n" "输入编号使用建议值"
  printf "1. %s\n" "icook.hk"
  printf "2. %s\n" "www.digitalocean.com"
  printf "3. %s\n" "www.garmin.com"
  printf "4. %s\n" "amp.cloudflare.com"
  read -rp "输入新的 CF 节点地址 [留空则使用现有值 ${cf_node_current}]: " cf_node_new
  case "${cf_node_new}" in
    "1") cf_node_new="icook.hk" ;;
    "2") cf_node_new="www.digitalocean.com" ;;
    "3") cf_node_new="www.garmin.com" ;;
    "4") cf_node_new="amp.cloudflare.com" ;;
  esac
  if [ -z "${cf_node_new}" ]; then
    cf_node_new="${cf_node_current}"
  fi
  state_set '.sub.cfNode' "$(json_quote "${cf_node_new}")"
  printf "%s\n" "CF 节点己变更为 ${cf_node_new}"
  if [ "$(state_get '.sub.enabled')" == "true" ]; then
    update_sub >/dev/null
  fi
  show_links
}

get_docker() {
  if [ ! -x "$(command -v docker)" ]; then
    colorEchoFlush "${BLUE}" "安装 docker\r"
    curl -sL https://get.docker.com/ | bash 2>&1 | writeLog >> "${log_path}"
  fi
}

sub_api() {
  if [ "$(state_get '.sub.enabled')" != "true" ]; then
    colorEcho "${RED}" "你还没有生成订阅链接"
    return 1
  fi
  get_docker
  if ! docker ps -q --filter ancestor=tindy2013/subconverter >/dev/null 2>&1; then
    docker rm $(docker stop $(docker ps -q --filter ancestor=tindy2013/subconverter) 2>/dev/null) 2>/dev/null
    docker run -d --restart=always -p 127.0.0.1:${SUB_API_PORT}:25500 tindy2013/subconverter:latest 2>&1 | writeLog >> "${log_path}"
  fi
  state_set '.sub.api.installed' 'true'
  colorEcho "${LGREEN}" "多客户端订阅 API 已启用"
  display_sub
}

sub_menu() {
  local opt
  while true; do
    echo ""
    echo "1) 生成订阅"
    echo "2) 更新订阅"
    echo "3) 显示订阅"
    echo "4) 启用多客户端 API (Clash/QuanX)"
    echo "5) 回主菜单"
    echo ""
    read -rp "选择操作 [输入任意值返回]: " opt
    case "${opt}" in
      "1") gen_sub ;;
      "2") update_sub ;;
      "3") display_sub ;;
      "4") sub_api ;;
      *) return 0 ;;
    esac
  done
}

# ============================================================
# 第10节 运维
# ============================================================
check_ports() {
  local conflict=0 p
  local tcp_ports=("${REALITY_PORT}" 80 "${CADDY_HTTPS_PORT}" "${WS_VLESS_PORT}" "${WS_TROJAN_PORT}")

  for p in "${tcp_ports[@]}"; do
    if port_in_use "${p}" tcp; then
      if [ "${p}" == "${REALITY_PORT}" ] && systemctl is-active --quiet xray; then
        continue
      fi
      if { [ "${p}" == "80" ] || [ "${p}" == "${CADDY_HTTPS_PORT}" ]; } && systemctl is-active --quiet caddy; then
        continue
      fi
      colorEcho "${YELLOW}" "端口 ${p}/tcp 已被占用"
      conflict=1
    fi
  done

  if port_in_use "${REALITY_PORT}" udp && ! systemctl is-active --quiet hysteria; then
    colorEcho "${YELLOW}" "端口 ${REALITY_PORT}/udp 已被占用"
    conflict=1
  fi

  return ${conflict}
}

migrate_from_old() {
  local svc legacy=()
  for svc in nginx trojan-go tls-shunt-proxy mtg v2ray shadowsocks-libev; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      legacy+=("${svc}")
    fi
  done

  if [ ${#legacy[@]} -eq 0 ]; then
    colorEcho "${YELLOW}" "未检测到旧组件，请手动确认端口占用原因"
    return 0
  fi

  colorEcho "${YELLOW}" "检测到旧组件: ${legacy[*]}"
  colorEcho "${YELLOW}" "这些组件会与 xtwall 抢占端口，需要先停止"
  local choice
  read -rp "停止并禁用以上服务 (Y/N)? " choice
  case "${choice}" in
    [yY] )
      for svc in "${legacy[@]}"; do
        systemctl stop "${svc}" 2>/dev/null
        systemctl disable "${svc}" 2>/dev/null
        echo "stopped & disabled: ${svc}" | writeLog >> "${log_path}"
      done
      colorEcho "${GREEN}" "旧组件已停止"
      colorEcho "${YELLOW}" "如需彻底清理残留配置，请运行原项目的卸载脚本"
      ;;
    * ) colorEcho "${YELLOW}" "已跳过，安装可能因端口占用失败" ;;
  esac
}

setup_cron() {
  # 每日同步 Caddy 证书到 Hysteria2
  ( crontab -l 2>/dev/null | grep -v 'xtwall --cert-sync'; \
    echo "30 4 * * * /usr/local/bin/xtwall --cert-sync >/dev/null 2>&1" ) | crontab -
  # geoip/geosite 每日更新
  ( crontab -l 2>/dev/null | grep -v "xray/geoip.dat"; \
    echo "0 7 * * * wget -q https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geoip.dat -O ${xray_asset_dir}/geoip.dat >/dev/null 2>&1" ) | crontab -
  ( crontab -l 2>/dev/null | grep -v "xray/geosite.dat"; \
    echo "0 7 * * * wget -q https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat -O ${xray_asset_dir}/geosite.dat >/dev/null 2>&1" ) | crontab -
  echo "crontab configured" | writeLog >> "${log_path}"
}

install_all() {
  local domain

  colorEcho "${BLUE}" "安装依赖包"
  install_dependencies

  if ! check_ports; then
    migrate_from_old
    check_ports && colorEcho "${YELLOW}" "端口仍被占用，安装可能失败"
  fi

  if ! ask_domain; then
    return 0
  fi
  domain="${ASK_DOMAIN_RESULT}"
  state_set '.domain' "$(json_quote "${domain}")"
  echo "install for domain ${domain}" | writeLog >> "${log_path}"

  colorEchoFlush "${BLUE}" "部署伪装站点\r"
  build_web force

  colorEchoFlush "${BLUE}" "安装 caddy\r"
  get_caddy || return 1

  colorEchoFlush "${BLUE}" "生成 Caddyfile\r"
  set_caddyfile || return 1

  systemctl restart caddy 2>&1 | writeLog >> "${log_path}"

  colorEchoFlush "${BLUE}" "等待证书签发\r"
  if wait_caddy_cert "${domain}"; then
    colorEcho "${LGREEN}" "完成: 证书签发"
  else
    colorEcho "${YELLOW}" "证书尚未就绪，请检查域名解析与 80 端口后执行\"证书巡检\""
  fi

  colorEchoFlush "${BLUE}" "安装 xray-core\r"
  get_xray || return 1

  colorEchoFlush "${BLUE}" "生成 xray 配置\r"
  set_xray_config || return 1
  xray_validate || return 1
  systemctl restart xray 2>&1 | writeLog >> "${log_path}"

  colorEchoFlush "${BLUE}" "安装 hysteria2\r"
  get_hysteria || return 1
  cert_sync || colorEcho "${YELLOW}" "证书同步失败，Hysteria2 可能无法启动"
  set_hysteria_config || return 1
  systemctl restart hysteria 2>&1 | writeLog >> "${log_path}"

  setup_cron

  systemctl reset-failed 2>/dev/null

  colorEcho "${LGREEN}" "安装完成!"
  show_links
  gen_sub
}

change_domain() {
  if [ "$(state_get '.caddy.installed')" != "true" ]; then
    colorEcho "${YELLOW}" "请先安装 xtwall"
    return 1
  fi

  local old_domain domain
  old_domain="$(state_get '.domain')"
  if ! ask_domain "解析到本 VPS 的新域名: "; then
    return 0
  fi
  domain="${ASK_DOMAIN_RESULT}"
  if [ "${domain}" == "${old_domain}" ]; then
    colorEcho "${YELLOW}" "域名未变化，无需操作"
    return 0
  fi

  state_set '.domain' "$(json_quote "${domain}")"

  colorEchoFlush "${BLUE}" "重写 Caddyfile\r"
  set_caddyfile || { state_set '.domain' "$(json_quote "${old_domain}")"; return 1; }
  systemctl restart caddy 2>&1 | writeLog >> "${log_path}"

  colorEchoFlush "${BLUE}" "等待新证书签发\r"
  wait_caddy_cert "${domain}" || colorEcho "${YELLOW}" "证书尚未就绪，请稍后执行\"证书巡检\""

  colorEchoFlush "${BLUE}" "同步 xray 配置\r"
  set_xray_config || return 1
  xray_validate || return 1
  systemctl restart xray 2>&1 | writeLog >> "${log_path}"

  colorEchoFlush "${BLUE}" "同步 Hysteria2\r"
  cert_sync
  set_hysteria_config || return 1
  systemctl restart hysteria 2>&1 | writeLog >> "${log_path}"

  if [ "$(state_get '.sub.enabled')" == "true" ]; then
    update_sub >/dev/null
  fi

  colorEcho "${LGREEN}" "域名已切换为 ${domain}"
  show_links
}

health_check() {
  printf "\n"
  local svc p days

  for svc in caddy xray hysteria; do
    printf "%s\t" "[${svc}]" | expand -t 16
    if systemctl is-active --quiet "${svc}"; then
      colorEcho "${GREEN}" "运行中"
    else
      colorEcho "${RED}" "未运行"
    fi
  done

  for p in "${REALITY_PORT}" 80 "${CADDY_HTTPS_PORT}" "${WS_VLESS_PORT}" "${WS_TROJAN_PORT}"; do
    printf "%s\t" "tcp/${p}" | expand -t 16
    if port_in_use "${p}" tcp; then
      colorEcho "${GREEN}" "监听中"
    else
      colorEcho "${RED}" "未监听"
    fi
  done

  printf "%s\t" "udp/${REALITY_PORT}" | expand -t 16
  if port_in_use "${REALITY_PORT}" udp; then
    colorEcho "${GREEN}" "监听中"
  else
    colorEcho "${RED}" "未监听"
  fi

  printf "%s\t" "[xray -test]" | expand -t 16
  if [ -x "${xray_bin}" ] && "${xray_bin}" run -test -confdir "${xray_conf_dir}" >/dev/null 2>&1; then
    colorEcho "${GREEN}" "通过"
  else
    colorEcho "${RED}" "失败"
  fi

  printf "%s\t" "[caddy validate]" | expand -t 16
  if [ -x "${caddy_bin}" ] && "${caddy_bin}" validate --config "${caddy_conf}" --adapter caddyfile >/dev/null 2>&1; then
    colorEcho "${GREEN}" "通过"
  else
    colorEcho "${RED}" "失败"
  fi

  days="$(cert_days_left)"
  printf "%s\t" "[证书]" | expand -t 16
  if [ -n "${days}" ] && [ "${days}" -gt 0 ]; then
    colorEcho "${GREEN}" "剩余 ${days} 天"
  else
    colorEcho "${RED}" "缺失或已过期"
  fi

  printf "\n"
}

vps_tools() {
  local t="${config_dir}/tools/vps_tools.sh"
  if [ ! -f "${t}" ]; then
    mkdir -p "${config_dir}/tools"
    if ! fetch_repo "tools/vps_tools.sh" "${t}"; then
      colorEcho "${RED}" "VPS 工具下载失败"
      return 1
    fi
  fi
  chmod +x "${t}"
  bash "${t}"
}

rm_xtwall() {
  local t="${config_dir}/tools/rm_xtwall.sh"
  if [ ! -f "${t}" ]; then
    mkdir -p "${config_dir}/tools"
    if ! fetch_repo "tools/rm_xtwall.sh" "${t}"; then
      colorEcho "${RED}" "卸载脚本下载失败"
      return 1
    fi
  fi
  chmod +x "${t}"
  bash "${t}"
  exit 0
}

# ============================================================
# 第11节 入口
# ============================================================
show_menu() {
  echo ""
  echo "----------状态----------"
  echo "1) 状态总览"
  echo "2) 证书巡检"
  echo "----------安装----------"
  echo "0) 一键安装 / 重新部署"
  echo "----------域名与证书----------"
  echo "3) 更换域名 (全链路同步)"
  echo "4) 恢复默认伪装站点模板"
  echo "----------分享与订阅----------"
  echo "5) 显示分享链接"
  echo "6) 管理订阅"
  echo "7) CDN 域名与开关"
  echo "8) 自定义 Cloudflare 节点"
  echo "----------更新----------"
  echo "9) 更新 xray-core"
  echo "10) 更新伪装站点模板"
  echo "11) 更新 hysteria"
  echo "----------运维----------"
  echo "12) 健康检查"
  echo "13) VPS 工具"
  echo "14) 卸载 xtwall"
  echo "15) 退出"
  echo ""
}

menu() {
  colorEcho "${YELLOW}" "xtwall - Reality + Hysteria2 automated script v${VERSION}"
  echo ""
  check_status

  COLUMNS=woof

  while true; do
    show_menu
    read -rp "选择操作 [输入任意值退出]: " opt
    case "${opt}" in
      "0") install_all && continue_prompt ;;
      "1") check_status && continue_prompt ;;
      "2") cert_status && continue_prompt ;;
      "3") change_domain && continue_prompt ;;
      "4") build_web force && continue_prompt ;;
      "5") show_links && continue_prompt ;;
      "6") sub_menu && continue_prompt ;;
      "7") toggle_cdn && continue_prompt ;;
      "8") edit_cf_node && continue_prompt ;;
      "9") get_xray && continue_prompt ;;
      "10") update_web && continue_prompt ;;
      "11") get_hysteria && continue_prompt ;;
      "12") health_check && continue_prompt ;;
      "13") vps_tools ;;
      "14") rm_xtwall ;;
      "15") exit 0 ;;
      *) exit 0 ;;
    esac
  done
}

# ============================================================
# 入口
# ============================================================
main() {
  require_root
  identify_the_operating_system_and_architecture
  state_init

  case "${1}" in
    --install)
      install_all
      menu
      ;;
    --cert-sync) cert_sync ;;
    --status)
      check_status
      exit 0
      ;;
    *)
      menu
      ;;
  esac
}

main "$@"
