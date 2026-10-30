#!/bin/bash
# WARP 管理：封装上游 fscarmen/warp-sh，不内置其 3000+ 行脚本，始终取最新版
export LC_ALL=C
export LANG=C
export LANGUAGE=en_US.UTF-8

if [[ $(/usr/bin/id -u) -ne 0 ]]; then
  echo "您不是 root 用户！请先输入 sudo -i 切换至 root 用户再运行本脚本"
  exit 1
fi

RED="31m"
GREEN="32m"
YELLOW="33m"
BLUE="36m"

colorEcho() {
  echo -e "\033[${1}${@:2}\033[0m" 1>&2
}

gh_proxy="${XTWALL_GH_PROXY:-gh-proxy.phlin.workers.dev}"
warp_script="/usr/bin/warp"

warp_download() {
  local dest="$1" tmp="${1}.part.$$" url
  for url in \
    "https://raw.githubusercontent.com/fscarmen/warp-sh/main/warp.sh" \
    "https://${gh_proxy}/github.com/fscarmen/warp-sh/raw/main/warp.sh"; do
    if wget -q -O "${tmp}" "${url}" 2>/dev/null && [ -s "${tmp}" ]; then
      mv -f "${tmp}" "${dest}"
      return 0
    fi
  done
  rm -f "${tmp}"
  return 1
}

ensure_warp() {
  if [ -x "${warp_script}" ]; then
    return 0
  fi
  colorEcho ${BLUE} "下载 WARP 脚本到 ${warp_script}..."
  if ! warp_download "${warp_script}"; then
    colorEcho ${RED} "WARP 脚本下载失败，请检查网络后重试"
    return 1
  fi
  chmod +x "${warp_script}"
  colorEcho ${GREEN} "WARP 脚本就绪"
}

run_warp() {
  ensure_warp || return 1
  bash "${warp_script}" "$@"
}

while true; do
  echo ""
  echo "----------WARP 管理----------"
  echo "1) 安装 WARP (IPv4 / IPv6 / 双栈)"
  echo "2) 查看 WARP 状态"
  echo "3) WARP 临时开关"
  echo "4) WARP Client 开关"
  echo "5) 更新 WARP 脚本至最新版"
  echo "6) 卸载 WARP"
  echo "7) 返回"
  echo ""
  read -rp "选择操作 [输入任意值返回]: " opt
  case "${opt}" in
    "1") run_warp ;;
    "2") run_warp n ;;
    "3") run_warp o ;;
    "4") run_warp r ;;
    "5") rm -f "${warp_script}"; ensure_warp && run_warp v ;;
    "6") run_warp u ;;
    *) exit 0 ;;
  esac
done
