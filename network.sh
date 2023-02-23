#!/bin/bash
# 该脚本将创建一个名为vmbr0的虚拟网桥，并将其记录到配置文件中。它会自动获取本地IPV4地址、子网掩码和网关，并将其添加到vmbr0配置中。

# 设置虚拟网桥名称
BRIDGE_NAME="vmbr0"

# 获取本地IPv4地址和子网掩码
IP_ADDR=$(ip route get 8.8.8.8 | head -1 | awk '{print $7}')
SUBNET_MASK="255.255.255.0"
# 获取网关地址
GATEWAY=$(ip route | awk '/default/ {print $3}')

# 创建虚拟网桥
cat << EOF > /etc/network/interfaces.d/$BRIDGE_NAME.conf
# This file is generated by create_vmbr0.sh script
auto $BRIDGE_NAME
iface $BRIDGE_NAME inet static
    address $IP_ADDR
    netmask $SUBNET_MASK
    gateway $GATEWAY
    bridge_ports none
    bridge_vlan_aware 1
    vlan_ids 100
EOF

# 重启网络服务以应用更改
systemctl restart networking.service
