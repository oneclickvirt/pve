#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 创建资源池
_green "正在创建资源池 mypool..."
pvesh create /pools --poolid mypool
_green "资源池 mypool 已创建！"

# 创建网桥
#!/bin/bash

# 选择桥接接口的标准
bridge_interface_pattern="eth*"
interfaces=($(ls /sys/class/net))
for interface in ${interfaces[@]}; do
    if [[ $interface != "lo" ]] && [[ $interface =~ $bridge_interface_pattern ]]; then
        bridge_ports="$interface"
        break
    fi
done
if [[ -z $bridge_ports ]]; then
    echo "错误：找不到可用网络接口"
    exit 1
fi
ipv4_address="192.168.1.1"
ipv4_netmask="255.255.255.0"
ipv6_address=$(ip -6 addr show dev $bridge_ports | awk '/inet6/{print $2;exit}' | cut -d'/' -f1)
ipv6_netmask=$(ip -6 addr show dev $bridge_ports | awk '/inet6/{print $4;exit}' | cut -d'/' -f1)
cat <<EOF > /etc/network/interfaces.d/vmbr1.cfg
auto vmbr1
iface vmbr1 inet static
    address $ipv4_address
    netmask $ipv4_netmask
    bridge_ports $bridge_ports
    bridge_stp off
    bridge_fd 0
iface vmbr1 inet6 static
    address $ipv6_address
    netmask $ipv6_netmask
EOF
if grep -q "iface vmbr1" /etc/network/interfaces; then
    echo "网桥 vmbr1 已经在 Proxmox VE 配置中"
else
    # 添加到配置文件
    cat <<EOF >> /etc/network/interfaces
# Proxmox VE bridge vmbr1
iface vmbr1 inet manual
    bridge-ports $bridge_ports
    bridge-stp off
    bridge-fd 0
EOF
fi
systemctl restart networking.service
echo "网桥 vmbr1 已创建！"

# 检测AppArmor模块
if ! dpkg -s apparmor > /dev/null 2>&1; then
    _green "正在安装 AppArmor..."
    apt-get update
    apt-get install -y apparmor
fi
if ! systemctl is-active --quiet apparmor.service; then
    _green "启动 AppArmor 服务..."
    systemctl enable apparmor.service
    systemctl start apparmor.service
fi
if ! lsmod | grep -q apparmor; then
    _green "正在加载 AppArmor 内核模块..."
    modprobe apparmor
fi
if ! lsmod | grep -q apparmor; then
    _yellow "AppArmor 仍未加载，可能需要重新启动系统加载，但你可以在面板尝试创建并启动CT"
fi
