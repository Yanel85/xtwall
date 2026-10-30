#!/bin/bash
# xtwall VPS 工具集
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

if [[ "$(command -v apt)" ]]; then
  systemPackage="apt-get"
elif [[ "$(command -v dnf)" ]]; then
  systemPackage="dnf"
elif [[ "$(command -v yum)" ]]; then
  systemPackage="yum"
else
  systemPackage=""
fi

script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
set_swap_script="${script_dir}/set_swap.sh"

continue_prompt() {
  local choice
  read -rp "继续其他操作 (yes/no)? " choice
  case "${choice}" in
    [yY]|[yY][eE][sS] ) return 0 ;;
    * ) exit 0;;
  esac
}

netSpeed() {
  [ -n "${systemPackage}" ] && ${sudoCmd} ${systemPackage} install curl -y -qq
  wget -q -N https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh -O /tmp/tcp.sh \
    && chmod +x /tmp/tcp.sh && ${sudoCmd} /tmp/tcp.sh
}

setSwap() {
  if [ -f "${set_swap_script}" ]; then
    ${sudoCmd} bash "${set_swap_script}"
  else
    ${sudoCmd} curl -sL "https://raw.githubusercontent.com/Yanel85/xtwall/main/tools/set_swap.sh" | ${sudoCmd} bash
  fi
}

rmAliyundun() {
  if [ ! -f /usr/sbin/aliyun-service ]; then
    colorEcho ${YELLOW} "未检测到阿里云相关服务"
    return 0
  fi

  ${sudoCmd} curl -sL http://update.aegis.aliyun.com/download/uninstall.sh | ${sudoCmd} bash
  ${sudoCmd} curl -sL http://update.aegis.aliyun.com/download/quartz_uninstall.sh | ${sudoCmd} bash

  colorEcho ${BLUE} "删除阿里云盾文件残留..."
  ${sudoCmd} pkill aliyun-service 2>/dev/null
  ${sudoCmd} rm -rf /etc/init.d/agentwatch /usr/sbin/aliyun-service
  ${sudoCmd} rm -rf /usr/local/aegis*

  colorEcho ${BLUE} "卸载云监控 Java 版本插件..."
  [ -x /usr/local/cloudmonitor/wrapper/bin/cloudmonitor.sh ] \
    && ${sudoCmd} /usr/local/cloudmonitor/wrapper/bin/cloudmonitor.sh stop \
    && ${sudoCmd} /usr/local/cloudmonitor/wrapper/bin/cloudmonitor.sh remove
  ${sudoCmd} rm -rf /usr/local/cloudmonitor

  colorEcho ${GREEN} "阿里云盾己卸载"
}

LemonBench() {
  [ -n "${systemPackage}" ] && ${sudoCmd} ${systemPackage} install curl -y -qq
  curl -sL https://raw.githubusercontent.com/LemonBench/LemonBench/master/LemonBench.sh | bash -s -- --mode fast
}

Oldking() {
  [ -n "${systemPackage}" ] && ${sudoCmd} ${systemPackage} install wget -y -qq
  wget -qO- https://git.io/Jvh0J | ${sudoCmd} bash
}

warpMenu() {
  local w="${script_dir}/WARP.sh"
  if [ ! -f "${w}" ]; then
    [ -n "${systemPackage}" ] && ${sudoCmd} ${systemPackage} install wget -y -qq
    ${sudoCmd} wget -q "https://raw.githubusercontent.com/Yanel85/xtwall/main/tools/WARP.sh" -O "${w}"
  fi
  if [ -f "${w}" ]; then
    ${sudoCmd} chmod +x "${w}"
    ${sudoCmd} bash "${w}"
  else
    colorEcho ${RED} "WARP 脚本下载失败，请检查网络后重试"
  fi
  return 0
}

colorEcho ${YELLOW} "xtwall VPS Toolkit"

PS3="选择操作[输入任意值退出]: "
COLUMNS=39
options=("安装加速" "设置 Swap" "WARP 管理" "卸载阿里云盾" "性能测试 (LemonBench)" "性能测试 (Oldking)" "返回")

select opt in "${options[@]}"; do
  case "${opt}" in
    "安装加速") netSpeed && continue_prompt ;;
    "设置 Swap") setSwap && continue_prompt ;;
    "WARP 管理") warpMenu && continue_prompt ;;
    "卸载阿里云盾") rmAliyundun && continue_prompt ;;
    "性能测试 (LemonBench)") LemonBench && continue_prompt ;;
    "性能测试 (Oldking)") Oldking && continue_prompt ;;
    "返回") exit 0 ;;
    *) exit 0 ;;
  esac
done
