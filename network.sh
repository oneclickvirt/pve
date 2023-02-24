#!/bin/bash
#from https://github.com/spiritLHLS/pve

interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
ip=$(ip addr show $interface | awk '/inet /{print $2}' | head -1)
netmask=$(ifconfig $interface | awk '/netmask/{print $4}' | head -1)
gateway=$(ip route | awk '/default/ {print $3}')
cat << EOF | sudo tee /etc/network/interfaces.d/vmbr0.conf
auto vmbr0
iface vmbr0 inet static
    address $ip
    netmask $netmask
    gateway $gateway
    bridge_ports $interface
    bridge_stp off
    bridge_fd 0
EOF

cat << EOF | sudo tee /etc/network/interfaces.d/vmbr1.conf
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
    post-down iptables -t nat -D POSTROUTING -s '172.16.1.0/24’ -o vmbr0 -j MASQUERADE
EOF

service networking restart
systemctl restart networking.service
