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
printf "Usage: /root/ss {start|stop|restart|status|iptables|edit}\n"
printf "=========================================================================\n"



function_start()
{
    printf "Starting shadowsocks...\n"
    /etc/init.d/shadowsocks start

}

function_stop()
{
    printf "Stoping shadowsocks...\n"
     /etc/init.d/shadowsocks  stop

}

function_restart()
{
    printf "Stoping shadowsocks...\n"
     /etc/init.d/shadowsocks start
     /etc/init.d/shadowsocks stop

}

function_iptable()
{
	sudo iptables -n -v -L -t filter
}

function_status()
{
       /etc/init.d/shadowsocks status
}

function_edit()
{
    vi /etc/shadowsocks.json

}


echo "which do you want to?input the number."
echo "1. start"
echo "2. stop"
echo "3. restart"
echo "4. status"
echo "5. edit ss json file"
echo "6. iptables data traffic status"
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
