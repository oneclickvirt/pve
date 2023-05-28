#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
  echo "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
  echo "Locale set to $utf8_locale"
fi

# API_NET=("ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
# for p in "${API_NET[@]}"; do
#   response=$(curl -s4m8 "$p")
#   sleep 1
#   if [ $? -eq 0 ] && ! echo "$response" | grep -q "error"; then
#     IP_API="$p"
#     break
#   fi
# done
# IPV4=$(curl -s4m8 "$IP_API")
IPV4=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)

# 查询信息
interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
if [ -z "$interface" ]; then
  interface="eth0"
fi
in_ip=$(ifconfig ${interface} | grep "inet " | awk '{print $2}')
if [ -z "$in_ip" ]; then
  ip=${IPV4}/24
else
  ip=${in_ip}/24
fi
gateway=$(ip route | awk '/default/ {print $3}')

# 录入网关
cp /etc/network/interfaces /etc/network/interfaces.bak
if grep -q "vmbr0" /etc/network/interfaces; then
    echo "vmbr0 已存在在 /etc/network/interfaces"
else
cat << EOF | sudo tee -a /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    address $ip
    gateway $gateway
    bridge_ports $interface
    bridge_stp off
    bridge_fd 0
EOF
fi
if grep -q "vmbr1" /etc/network/interfaces; then
    echo "vmbr1 已存在在 /etc/network/interfaces"
else
cat << EOF | sudo tee -a /etc/network/interfaces
auto vmbr1
iface vmbr1 inet static
    address 172.16.1.1
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up echo 1 > /proc/sys/net/ipv4/conf/vmbr1/proxy_arp
    post-up iptables -t nat -A POSTROUTING -s '172.16.1.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '172.16.1.0/24' -o vmbr0 -j MASQUERADE
EOF
fi

# 加载iptables并设置回源且允许NAT端口转发
apt-get install -y iptables iptables-persistent
iptables -t nat -A POSTROUTING -j MASQUERADE
sysctl net.ipv4.ip_forward=1
sysctl_path=$(which sysctl)
if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  if grep -q "^#net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  fi
else
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
${sysctl_path} -p

# 重启配置
service networking restart
systemctl restart networking.service
