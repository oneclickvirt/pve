#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 创建网桥
interfaces=($(ls /sys/class/net))
for interface in ${interfaces[@]}; do
    if [[ $interface != "lo" ]] && [[ $interface != "vmbr"* ]]; then
        bridge_ports="$interface"
        break
    fi
done
if [[ -z $bridge_ports ]]; then
    echo "Error: No available network interface found."
    exit 1
fi
echo "Creating bridge vmbr1..."
cat <<EOF >> /etc/network/interfaces.d/vmbr1.cfg
auto vmbr1
iface vmbr1 inet static
    address 192.168.1.1
    netmask 255.255.255.0
    bridge_ports $bridge_ports
    bridge_stp off
    bridge_fd 0

iface vmbr1 inet6 static
    address $(ip -6 addr show dev $bridge_ports | grep inet6 | awk '{ print $2 }' | cut -d'/' -f1)
    netmask $(ip -6 addr show dev $bridge_ports | grep inet6 | awk '{ print $4 }' | cut -d'/' -f1)
EOF
if grep -q "iface vmbr1" /etc/network/interfaces; then
    echo "Bridge vmbr1 is already in Proxmox VE configuration."
else
    # Add bridge configuration to Proxmox VE configuration
    echo "Adding bridge vmbr1 to Proxmox VE configuration..."
    cat <<EOF >> /etc/network/interfaces
# Proxmox VE bridge vmbr1
iface vmbr1 inet manual
    bridge-ports $bridge_ports
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

# 检测AppArmor模块
if ! dpkg -s apparmor > /dev/null 2>&1; then
    echo "Installing AppArmor..."
    apt-get update
    apt-get install -y apparmor
fi
if ! systemctl is-active --quiet apparmor.service; then
    echo "Starting AppArmor service..."
    systemctl enable apparmor.service
    systemctl start apparmor.service
fi
if ! lsmod | grep -q apparmor; then
    echo "Loading AppArmor kernel module..."
    modprobe apparmor
fi
if ! lsmod | grep -q apparmor; then
    echo "AppArmor not loaded, a system reboot may be required."
fi
echo "AppArmor has been configured."
