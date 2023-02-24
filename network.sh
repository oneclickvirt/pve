#!/bin/bash
#from https://github.com/spiritLHLS/pve

interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
ip=$(curl -s ipv4.ip.sb)/24
gateway=$(ip route | awk '/default/ {print $3}')
if grep -q "vmbr0" /etc/network/interfaces; then
    echo "vmbr0 already exists in /etc/network/interfaces"
else
    # Add the vmbr0 configuration block
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
    echo "vmbr1 already exists in /etc/network/interfaces"
else
    # Add the vmbr1 configuration block
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

service networking restart
systemctl restart networking.service
