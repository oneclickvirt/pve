#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.05.29

# ./buildct.sh CTID 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘
# ./buildct.sh 102 1234567 1 512 5 20001 20002 20003 30000 30025 debian11 local

# 用颜色输出信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
  echo "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
  echo "Locale set to $utf8_locale"
fi

cd /root >/dev/null 2>&1
CTID="${1:-102}"
password="${2:-123456}"
core="${3:-1}"
memory="${4:-512}"
disk="${5:-5}"
sshn="${6:-20001}"
web1_port="${7:-20002}"
web2_port="${8:-20003}"
port_first="${9:-29975}"
port_last="${10:-30000}"
system_ori="${11:-debian11}"
storage="${12:-local}"
rm -rf "ct$name"
en_system=$(echo "$system_ori" | sed 's/[0-9]*//g')
num_system=$(echo "$system_ori" | sed 's/[a-zA-Z]*//g')
system="$en_system-$num_system"
system_name=$(pveam available --section system | grep "$system" | awk '{print $2}' | head -n1)
if ! pveam available --section system | grep "$system" > /dev/null; then
  _red "No such system"
  exit
else
  _green "Use $system_name"
fi
pveam download local $system_name

check_cdn() {
  local o_url=$1
  for cdn_url in "${cdn_urls[@]}"; do
    if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" > /dev/null 2>&1; then
      export cdn_success_url="$cdn_url"
      return
    fi
    sleep 0.5
  done
  export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, no use CDN"
    fi
}

cdn_urls=("https://cdn.spiritlhl.workers.dev/" "https://cdn3.spiritlhl.net/" "https://cdn1.spiritlhl.net/" "https://ghproxy.com/" "https://cdn2.spiritlhl.net/")
check_cdn_file

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
pct create $CTID ${storage}:vztmpl/$system_name -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs local:${disk} -onboot 1 -password $password -features nesting=1
pct start $CTID
pct set $CTID --hostname $CTID
pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1 
pct set $CTID --nameserver 8.8.8.8 --nameserver 8.8.4.4
sleep 3
pct exec $CTID -- apt-get update -y
pct exec $CTID -- dpkg --configure -a
pct exec $CTID -- apt-get update
pct exec $CTID -- apt-get install dos2unix curl -y
pct exec $CTID -- curl -L ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/ssh.sh -o ssh.sh
pct exec $CTID -- chmod 777 ssh.sh
pct exec $CTID -- dos2unix ssh.sh
pct exec $CTID -- bash ssh.sh
# pct exec $CTID -- curl -L ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/lxc/main/config.sh -o config.sh
# pct exec $CTID -- chmod +x config.sh
# pct exec $CTID -- bash config.sh

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
echo "$CTID $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system_ori $storage" >> "ct${CTID}"
# 容器的相关信息将会存储到对应的容器的NOTE中，可在WEB端查看
data=$(echo " CTID root密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘")
values=$(cat "ct${CTID}")
IFS=' ' read -ra data_array <<< "$data"
IFS=' ' read -ra values_array <<< "$values"
length=${#data_array[@]}
for ((i=0; i<$length; i++))
do
  echo "${data_array[$i]} ${values_array[$i]}"
  echo ""
done > "/tmp/temp${CTID}.txt"
sed -i 's/^/# /' "/tmp/temp${CTID}.txt"
cat "/etc/pve/lxc/${CTID}.conf" >> "/tmp/temp${CTID}.txt"
cp "/tmp/temp${CTID}.txt" "/etc/pve/lxc/${CTID}.conf"
rm -rf "/tmp/temp${CTID}.txt"
cat "ct${CTID}"
