#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.04.22

# ./buildct.sh CTID 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统
# ./buildct.sh 102 1234567 1 512 5 40001 40002 40003 50000 50025 debian11

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
system="debian-11-standard_11.6-1_amd64.tar.zst"

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
pct create $CTID local:vztmpl/$system --cores $core --cpuunits 1024 --memory $memory --swap 128 --rootfs local:${disk} --onboot 1 -password $password
pct start $CTID
pct set $CTID --hostname $CTID
pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1 
pct set $CTID --nameserver 8.8.8.8 --nameserver 8.8.4.4

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
