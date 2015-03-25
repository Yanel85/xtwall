#!/bin/bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# Check if user is root
if [ $(id -u) != "0" ]; then
    printf "Error: You must be root to run this script!\n"
    exit 1
fi

clear

echo "========================================================================="
echo "limit data with iptables"
echo "========================================================================="
echo -e "\n"
read -p "Input your iptables option [I/R/D]" -n 1 o
echo -e "\n"
read -p "Input your data limit [M]" d
echo -e "\n"
read -p "Input shadowsocks port:" p
d=$[$d*1048576]
for port in $p;do
iptables -$o OUTPUT -p tcp --sport $port -j DROP
iptables -$o OUTPUT -p tcp --sport $port -m quota --quota $d -j ACCEPT  
echo "ADD PORT $port"
done
iptables -n -v -L -t filter



