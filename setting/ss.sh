#!/bin/bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# Check if user is root
if [ $(id -u) != "0" ]; then
    printf "Error: You must be root to run this script!\n"
    exit 1
fi

printf "=========================================================================\n"
printf "Manager for shadowsocks"
printf "=========================================================================\n"
printf "Usage: /root/shadowsocks {start|stop|restart|status}\n"
printf "=========================================================================\n"



function_start()
{
    printf "Starting shadowsocks...\n"
    ssserver -c /etc/shadowsocks.json -d start
}

function_stop()
{
    printf "Stoping shadowsocks...\n"
    ssserver -c /etc/shadowsocks.json -d stop

}

function_restart()
{
    printf "Stoping shadowsocks...\n"
    ssserver -c /etc/shadowsocks.json -d stop
    ssserver -c /etc/shadowsocks.json -d start

}

function_iptable()
{
sudo iptables -n -v -L -t filter
}
function_status()
{
    vi /etc/ppp/chap-secrets
	service iptables restart
	service pptpd start
}

function_edit()
{
    vi /etc/shadowsocks.json

}


echo "which do you want to?input the number."
echo "1. start"
echo "2. stop"
echo "3. restart"
echo "4. vpn"
echo "5. editconf"
echo "6. data traffic"
read num

case "$num" in
[1] ) (function_start);;
[2] ) (function_stop);;
[3] ) (function_restart);;
[4] ) (function_status);;
[5] ) (function_edit);;
[6] ) (function_iptable);;
*) echo "nothing,exit";;
esac
