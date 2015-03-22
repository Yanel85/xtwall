#!/bin/bash

if [ $(id -u) != "0" ]; then
    printf "Error: You must be root to run this tool!\n"
    exit 1
fi
clear
printf "
####################################################
#                                                  #
# This is a Shell-Based tool of pptp installation  #
# Version: 0.1                                     #
# Author: Bruce Ku                                 #
# For Debian/Ubuntu 32bit and 64bit                #
#                                                  #
####################################################
"
vpsip=`ifconfig  | grep 'inet addr:'| grep -v '127.0.0.1' | cut -d: -f2 | awk 'NR==1 { print $1}'`
apt-get update
apt-get --purge remove pptpd ppp
rm -rf /etc/pptpd.conf
rm -rf /etc/ppp
apt-get install -y ppp
apt-get install -y pptpd
apt-get install -y iptables logrotate tar cpio perl
rm -r /dev/ppp
mknod /dev/ppp c 108 0
echo 1 > /proc/sys/net/ipv4/ip_forward 
echo "mknod /dev/ppp c 108 0" >> /etc/rc.local
echo "echo 1 > /proc/sys/net/ipv4/ip_forward" >> /etc/rc.local
echo "localip 172.16.36.1" >> /etc/pptpd.conf
echo "remoteip 172.16.36.2-254" >> /etc/pptpd.conf
echo "ms-dns 8.8.8.8" >> /etc/ppp/options
echo "ms-dns 8.8.4.4" >> /etc/ppp/options
echo "vpn pptpd 123456 *" >> /etc/ppp/chap-secrets
iptables -t nat -A POSTROUTING -s 172.16.36.0/24 -j SNAT --to-source `ifconfig  | grep 'inet addr:'| grep -v '127.0.0.1' | cut -d: -f2 | awk 'NR==1 { print $1}'`
iptables -A FORWARD -p tcp --syn -s 172.16.36.0/24 -j TCPMSS --set-mss 1356
iptables -t nat -A POSTROUTING -s 172.16.36.0/24 -j SNAT --to-source "$vpsip"
iptables-save > /etc/iptables-rules
printf "
####################################################
add my Yu
####################################################
"
echo "pre-up iptables-restore < /etc/iptables-rules" >> /etc/network/interfaces
printf "
####################################################
add my Yu
####################################################
"
/etc/init.d/pptpd restart
printf "
####################################################
#                                                  #
# This is a Shell-Based tool of pptp installation  #
# Version: 0.1                                     #
# Author: Bruce Ku                                 #
# For Debian/Ubuntu 32bit and 64bit                #
#                                                  #
####################################################
ServerIP:$vpsip
username:vpn
password:123456

"