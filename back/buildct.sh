#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.04.22

# ./buildct.sh CTID 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统
# ./buildct.sh 102 1234567 1 512 5 40001 40002 40003 50000 50025 debian11

# 用颜色输出信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

cd /root >/dev/null 2>&1
CTID="${1:-102}"
password="${2:-123456}"
core="${3:-1}"
memory="${4:-512}"
disk="${5:-5}"
sshn="${6:-40001}"
web1_port="${7:-40002}"
web2_port="${8:-40003}"
port_first="${9:-49975}"
port_last="${10:-50000}"
system="${12:-debian11}"
rm -rf "ct$name"
en_system=$(echo "$system" | sed 's/[0-9]*//g')
num_system=$(echo "$system" | sed 's/[a-zA-Z]*//g')
system="$en_system-$num_system"
system_name=$(pveam available --section system | grep "$system" | awk '{print $2}' | head -n1)
if ! pveam available --section system | grep "$system" > /dev/null; then
  _red "No such system"
  exit
else
  _green "Use $system_name"
fi
pveam download local $system_name

first_digit=${CTID:0:1}
second_digit=${CTID:1:1}
third_digit=${CTID:2:1}
if [ $first_digit -le 2 ]; then
  if [ $second_digit -eq 0 ]; then
    num=$third_digit
  else
    num=$second_digit$third_digit
  fi
else
  num=$((first_digit - 2))$second_digit$third_digit
fi
user_ip="172.16.1.${num}"
pct create $CTID local:vztmpl/$system_name -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs local:${disk} --onboot 1 -password $password
pct start $CTID
pct set $CTID --hostname $CTID
pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1 
pct set $CTID --nameserver 8.8.8.8 --nameserver 8.8.4.4
sleep 3
pct exec $CTID -- apt-get update -y
pct exec $CTID -- dpkg --configure -a
pct exec $CTID -- apt-get update
pct exec $CTID -- apt-get install dos2unix curl -y
pct exec $CTID -- curl -L https://raw.githubusercontent.com/spiritLHLS/lxc/main/ssh.sh -o ssh.sh
pct exec $CTID -- chmod 777 ssh.sh
pct exec $CTID -- dos2unix ssh.sh
pct exec $CTID -- ./ssh.sh $password
pct exec $CTID -- curl -L https://raw.githubusercontent.com/spiritLHLS/lxc/main/config.sh -o config.sh
pct exec $CTID -- chmod +x config.sh
pct exec $CTID -- bash config.sh
pct exec $CTID -- history -c

iptables -t nat -A PREROUTING -p tcp --dport ${sshn} -j DNAT --to-destination ${user_ip}:22
iptables -t nat -A PREROUTING -p tcp -m tcp --dport ${web1_port} -j DNAT --to-destination ${user_ip}:80
iptables -t nat -A PREROUTING -p tcp -m tcp --dport ${web2_port} -j DNAT --to-destination ${user_ip}:443
iptables -t nat -A PREROUTING -p tcp -m tcp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
iptables -t nat -A PREROUTING -p udp -m udp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
if [ ! -f "/etc/iptables/rules.v4" ]; then
    touch /etc/iptables/rules.v4
fi
iptables-save > /etc/iptables/rules.v4
service netfilter-persistent restart
echo "$CTID $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system" >> "ct${CTID}"
cat "ct${CTID}"
