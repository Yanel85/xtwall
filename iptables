#!/bin/sh
/etc/init.d/iptables restart 
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

