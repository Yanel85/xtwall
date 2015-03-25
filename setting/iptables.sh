#!/bin/bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# Check if user is root
if [ $(id -u) != "0" ]; then
    printf "Error: You must be root to run this script!\n"
    exit 1
fi

clear


function_i()
{
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
}

function_r()
{
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
}

function_d()
{
echo -e "\n"
read -p "Input shadowsocks port:" p
for port in $p;do
iptables -$o OUTPUT -p tcp --sport $port -j DROP
iptables -$o OUTPUT -p tcp --sport $port -m quota --quota 1048576 -j ACCEPT  
echo "ADD PORT $port"
done
iptables -n -v -L -t filter
}

echo "========================================================================="
echo "limit data with iptables"
echo "========================================================================="
echo -e "\n"
echo "I. insert iptables"
echo "R. reples iptables"
echo "D. delete iptables"
read -p "Input your iptables option [I/R/D] Cpital" -n 1 o
echo -e "\n"

case "$o" in
[I] ) (function_i);;
[R] ) (function_r);;
[D] ) (function_d);;
*) echo "nothing,exit";;
esac

