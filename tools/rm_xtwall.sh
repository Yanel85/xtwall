#!/bin/bash
# xtwall 卸载脚本：覆盖 xray / caddy / hysteria 与全部残留
export LC_ALL=C
export LANG=C
export LANGUAGE=en_US.UTF-8

if [[ $(/usr/bin/id -u) -ne 0 ]]; then
  sudoCmd="sudo"
else
  sudoCmd=""
fi

RED="31m"
GREEN="32m"
YELLOW="33m"
BLUE="36m"

colorEcho() {
  echo -e "\033[${1}${@:2}\033[0m" 1>&2
}

uninstall() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    ${sudoCmd} rm -rf "$1"
    printf "Removed: %s\n" "$1"
  fi
}

stop_service() {
  local svc="$1"
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
    colorEcho ${BLUE} "Stopping ${svc} service."
    ${sudoCmd} systemctl stop "${svc}" 2>/dev/null
    ${sudoCmd} systemctl disable "${svc}" 2>/dev/null
    uninstall "/etc/systemd/system/${svc}.service"
  fi
}

# ---------- xray ----------
if [ -f "/usr/local/bin/xray" ]; then
  stop_service xray
  colorEcho ${BLUE} "Removing xray binaries."
  uninstall "/usr/local/bin/xray"
  colorEcho ${BLUE} "Removing xray files."
  uninstall "/usr/local/etc/xray"
  uninstall "/usr/local/share/xray"
  uninstall "/var/log/xray"
  colorEcho ${BLUE} "Removing xray crontab."
  ${sudoCmd} crontab -l 2>/dev/null | grep -v 'xray/geoip.dat' | ${sudoCmd} crontab - 2>/dev/null
  ${sudoCmd} crontab -l 2>/dev/null | grep -v 'xray/geosite.dat' | ${sudoCmd} crontab - 2>/dev/null
  colorEcho ${GREEN} "Removed xray successfully."
fi

# ---------- caddy ----------
if [ -f "/usr/local/bin/caddy" ]; then
  stop_service caddy
  colorEcho ${BLUE} "Removing caddy files."
  uninstall "/usr/local/bin/caddy"
  uninstall "/etc/caddy"
  colorEcho ${BLUE} "Removing caddy user."
  ${sudoCmd} deluser caddy >/dev/null 2>&1
  ${sudoCmd} delgroup caddy >/dev/null 2>&1
  colorEcho ${GREEN} "Removed caddy successfully."
fi

# ---------- hysteria ----------
if [ -f "/usr/local/bin/hysteria" ]; then
  stop_service hysteria
  colorEcho ${BLUE} "Removing hysteria files."
  uninstall "/usr/local/bin/hysteria"
  uninstall "/etc/hysteria"
  colorEcho ${GREEN} "Removed hysteria successfully."
fi

# ---------- 订阅转换容器与镜像 ----------
if command -v docker >/dev/null 2>&1; then
  colorEcho ${BLUE} "Removing subconverter container and image."
  sub_ids="$(${sudoCmd} docker ps -aq --filter ancestor=tindy2013/subconverter 2>/dev/null)"
  [ -n "${sub_ids}" ] && ${sudoCmd} docker rm -f ${sub_ids} >/dev/null 2>&1
  sub_ids="$(${sudoCmd} docker ps -aq --filter name=xtwall-subconverter 2>/dev/null)"
  [ -n "${sub_ids}" ] && ${sudoCmd} docker rm -f ${sub_ids} >/dev/null 2>&1
  if ${sudoCmd} docker image inspect tindy2013/subconverter:latest >/dev/null 2>&1; then
    ${sudoCmd} docker rmi -f tindy2013/subconverter:latest >/dev/null 2>&1
  fi
fi

# ---------- 订阅产物与伪装站点 ----------
colorEcho ${BLUE} "Removing subscription files."
for f in /var/www/html/*; do
  [ -f "$f" ] || continue
  case "$f" in
    */index.html|*/robots.txt) continue ;;
  esac
  uninstall "$f"
done

read -rp "是否同时删除伪装站点 (/var/www/html) (yes/no)? " rmWeb
case "${rmWeb}" in
  [yY]|[yY][eE][sS] ) uninstall "/var/www/html" ;;
  * ) colorEcho ${YELLOW} "已保留 /var/www/html" ;;
esac

# ---------- crontab ----------
colorEcho ${BLUE} "Removing xtwall crontab."
${sudoCmd} crontab -l 2>/dev/null | grep -v 'xtwall --cert-sync' | ${sudoCmd} crontab - 2>/dev/null

# ---------- 脚本与状态 ----------
colorEcho ${BLUE} "Removing xtwall executable and configuration files."
uninstall "/usr/local/etc/xtwall"
uninstall "/usr/local/bin/xtwall"
uninstall "/var/log/xtwall.log"

${sudoCmd} systemctl daemon-reload
${sudoCmd} systemctl reset-failed

colorEcho ${BLUE} "卸载完成"
