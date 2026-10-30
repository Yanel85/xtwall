#!/bin/bash
# 设置 1G Swap（幂等）
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

if [[ $(cat /proc/swaps 2>/dev/null | wc -l) -gt 1 ]]; then
  free -h
  colorEcho ${BLUE} "己有 Swap 无需设置"
  exit 0
fi

if ${sudoCmd} fallocate -l 1G /swapfile 2>/dev/null; then
  :
else
  ${sudoCmd} dd if=/dev/zero of=/swapfile bs=1024 count=1048576
fi

${sudoCmd} chmod 600 /swapfile
${sudoCmd} mkswap /swapfile
${sudoCmd} swapon /swapfile

if ! grep -q '^/swapfile' /etc/fstab; then
  echo "/swapfile swap swap defaults 0 0" | ${sudoCmd} tee -a /etc/fstab >/dev/null
fi

${sudoCmd} sysctl -w "vm.swappiness=10" >/dev/null
if ! grep -q '^vm.swappiness' /etc/sysctl.conf; then
  echo "vm.swappiness=10" | ${sudoCmd} tee -a /etc/sysctl.conf >/dev/null
fi

free -h
colorEcho ${GREEN} "设置 Swap 成功"
