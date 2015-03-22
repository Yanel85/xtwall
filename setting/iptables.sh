#!/bin/sh
# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script, use sudo sh $0"
    exit 1
fi
clear
echo "========================================================================="
echo "limit data bytes with iptables"
echo "========================================================================="
echo "enter your data limit ?G"
read d
echo "enter your port:"
read p
d=$[$d*1073741824]
for port in $p;do
iptables -A OUTPUT -p tcp --sport $port -m quota --quota $d -j ACCEPT  
iptables -A OUTPUT -p tcp --sport $port -j DROP
echo "ADD PORT $port"
done
iptables -n -v -L -t filter

