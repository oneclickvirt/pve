#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 创建网桥
echo "Creating bridge vmbr1..."
cat <<EOF >> /etc/network/interfaces.d/vmbr1.cfg
auto vmbr1
iface vmbr1 inet static
    address 192.168.1.1
    netmask 255.255.255.0
    bridge_ports enp0s8
    bridge_stp off
    bridge_fd 0
EOF
if grep -q "iface vmbr1" /etc/network/interfaces; then
    echo "Bridge vmbr1 is already in Proxmox VE configuration."
else
    # Add bridge configuration to Proxmox VE configuration
    echo "Adding bridge vmbr1 to Proxmox VE configuration..."
    cat <<EOF >> /etc/network/interfaces
# Proxmox VE bridge vmbr1
iface vmbr1 inet manual
    bridge-ports enp0s8
    bridge-stp off
    bridge-fd 0
EOF
fi
systemctl restart networking.service
echo "Bridge vmbr1 created!"


# 创建资源池
echo "Creating resource pool mypool..."
pvesh create /pools --poolid mypool
echo "Resource pool mypool created!"
