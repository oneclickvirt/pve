#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

API_NET=("ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
for p in "${API_NET[@]}"; do
  response=$(curl -s4m8 "$p")
  sleep 1
  if [ $? -eq 0 ] && ! echo "$response" | grep -q "error"; then
    IP_API="$p"
    break
  fi
done
IPV4=$(curl -s4m8 "$IP_API")

# 查询信息
interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
ip=${IPV4}/24
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

# 检查/etc/network/interfaces是否有source /etc/network/interfaces.d/*行
if grep -q "source /etc/network/interfaces.d/*" /etc/network/interfaces; then
  # 检查/etc/network/interfaces.d/文件夹下是否有50-cloud-init文件
  if [ -f /etc/network/interfaces.d/50-cloud-init ]; then
    # 检查50-cloud-init文件中是否有iface eth0 inet dhcp行
    if grep -q "iface eth0 inet dhcp" /etc/network/interfaces.d/50-cloud-init; then
      # 获取ipv4、subnet、gateway信息
      gateway=$(ip route | awk '/default/ {print $3}')
      eth0info=$(ip -o -4 addr show dev eth0 | awk '{print $4}')
      ipv4=$(echo $eth0info | cut -d'/' -f1)
      subnet=$(echo $eth0info | cut -d'/' -f2)
      subnet=$(ipcalc -n "$ipv4/$subnet" | grep -oP 'Netmask:\s+\K.*' | awk '{print $1}')
      chattr -i /etc/network/interfaces.d/50-cloud-init
      sed -i "/iface eth0 inet dhcp/c\
        iface eth0 inet static\n\
        address $ipv4\n\
        netmask $subnet\n\
        gateway $gateway\n\
        dns-nameservers 8.8.8.8 8.8.4.4" /etc/network/interfaces.d/50-cloud-init
      chattr +i /etc/network/interfaces.d/50-cloud-init
    fi
  fi
fi

# 重启配置
service networking restart
systemctl restart networking.service
