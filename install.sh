#!/bin/bash
# xtwall installer
# 仅负责下载脚本与初始化状态文件，其余逻辑全部在 src/xtwall.sh 内
export LC_ALL=C
export LANG=en_US
export LANGUAGE=en_US.UTF-8

branch="main"
VERSION="1.0.0"
REPO="Yanel85/xtwall"

jsdelivr="cdn.jsdelivr.net/gh"
gh_proxy="${XTWALL_GH_PROXY:-gh-proxy.phlin.workers.dev}"

if [[ $(/usr/bin/id -u) -ne 0 ]]; then
  echo "您不是 root 用户！请先输入 sudo -i 切换至 root 用户再运行本脚本"
  exit 1
fi

# 包管理器
if [[ "$(command -v apt)" ]]; then
  PM_UPDATE='apt update'
  PM_INSTALL='apt install'
elif [[ "$(command -v dnf)" ]]; then
  PM_UPDATE='dnf makecache'
  PM_INSTALL='dnf install'
elif [[ "$(command -v yum)" ]]; then
  PM_UPDATE='yum makecache'
  PM_INSTALL='yum install'
elif [[ "$(command -v zypper)" ]]; then
  PM_UPDATE='zypper refresh'
  PM_INSTALL='zypper install'
elif [[ "$(command -v pacman)" ]]; then
  PM_UPDATE='pacman -Sy'
  PM_INSTALL='pacman -S --noconfirm'
else
  echo "error: 当前系统的包管理器不受支持"
  exit 1
fi

echo "安装依赖: curl wget unzip jq lsof coreutils openssl tar"
${PM_UPDATE} -y >/dev/null 2>&1 || true
${PM_INSTALL} curl wget unzip jq lsof coreutils openssl tar -y >/dev/null 2>&1 || true

for cmd in curl jq unzip tar; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: 依赖 ${cmd} 安装失败，请手动安装后重试"
    exit 1
  fi
done

fetch_repo() {
  # fetch_repo [repo 内相对路径] [目标文件]
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

mkdir -p /usr/local/etc/xtwall/tools /var/www/html

echo "初始化状态文件 /usr/local/etc/xtwall/config.json"
if [ ! -f /usr/local/etc/xtwall/config.json ]; then
  if ! fetch_repo "config/xtwall.json" "/usr/local/etc/xtwall/config.json"; then
    echo "警告: 状态文件下载失败，首次运行时将由 xtwall 自动生成默认配置"
  fi
fi

echo "下载主脚本 /usr/local/bin/xtwall"
if ! fetch_repo "src/xtwall.sh" "/usr/local/bin/xtwall"; then
  echo "error: 主脚本下载失败，请检查网络或仓库地址 ${REPO}"
  exit 1
fi
chmod +x /usr/local/bin/xtwall

echo "下载配套工具"
for t in rm_xtwall.sh set_swap.sh vps_tools.sh WARP.sh; do
  if fetch_repo "tools/${t}" "/usr/local/etc/xtwall/tools/${t}"; then
    chmod +x "/usr/local/etc/xtwall/tools/${t}"
  fi
done

if [ -f /usr/local/etc/xtwall/config.json ]; then
  jq -r ".version = \"${VERSION}\"" /usr/local/etc/xtwall/config.json > /tmp/xtwall.json.$$ \
    && mv -f /tmp/xtwall.json.$$ /usr/local/etc/xtwall/config.json
fi

echo "安装完成，正在启动 xtwall"
exec /usr/local/bin/xtwall --install
