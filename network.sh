#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 查询信息
interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
ip=$(curl -s ipv4.ip.sb)/24
gateway=$(ip route | awk '/default/ {print $3}')

# 录入网关
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

# 重启配置
service networking restart
systemctl restart networking.service

# 配置DHCP
