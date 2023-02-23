#!/bin/bash
# 该脚本将创建一个名为vmbr0的虚拟网桥，并将其记录到PVE配置中。它会自动获取本地IPV4地址、子网掩码和网关，并将其添加到vmbr0配置中。

# 设置虚拟网桥名称
BRIDGE_NAME="vmbr0"

# 获取本地IPv4地址和子网掩码
IP_ADDR=$(ip route get 8.8.8.8 | head -1 | awk '{print $7}')
SUBNET_MASK=$(ip route get 8.8.8.8 | head -1 | awk '{print $1}' | awk -F"/" '{print $2}')

# 计算网络地址
IFS='.' read -ra IP_ARR <<< "$IP_ADDR"
IFS='.' read -ra MASK_ARR <<< "$SUBNET_MASK"
NET_ADDR=""
for ((i=0; i<4; i++)); do
  NET_ADDR="$NET_ADDR$(( ${IP_ARR[$i]} & ${MASK_ARR[$i]} ))."
done
NET_ADDR=${NET_ADDR::-1}

# 获取网关地址
GATEWAY=$(ip route | awk '/default/ {print $3}')

# 创建虚拟网桥并将其记录到PVE配置中
pvesh set /nodes/localhost/network/$BRIDGE_NAME \
  bridge_ports=none \
  bridge_vlan_aware=1 \
  vlan_ids=100 \
  addresses="$IP_ADDR/$SUBNET_MASK" \
  gateway="$GATEWAY"
