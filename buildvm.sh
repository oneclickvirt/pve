#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.04.09

# ./buildvm.sh VMID 用户名 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统
# ./buildvm.sh 102 test1 1234567 1 512 5 40001 40002 40003 50000 50025 ubuntu20

cd /root >/dev/null 2>&1
# 创建容器
vm_num="${1:-102}"
user="${2:-test}"
password="${3:-123456}"
core="${4:-1}"
memory="${5:-512}"
disk="${6:-5}"
sshn="${7:-40001}"
web1_port="${8:-40002}"
web2_port="${9:-40003}"
port_first="${10:-49975}"
port_last="${11:-50000}"
# in="${12:-300}"
# out="${13:-300}"
system="${14:-debian10}"
rm -rf "vm$name"

if [ ! -d "qcow" ]; then
  mkdir qcow
fi
systems=("centos7" "debian10" "debian11" "debian9" "ubuntu18" "ubuntu20" "ubuntu22" "centos9-stream" "centos8-stream")
for sys in ${systems[@]}; do
  if [[ "$system" == "$sys" ]]; then
    file_path="/root/qcow/${system}.qcow2"
    break
  fi
done
if [[ -z "$file_path" ]]; then
  red "无法安装对应系统，仅支持 debian9 debian10 debian11 ubuntu18 ubuntu20 ubuntu22 centos9-stream centos8-stream centos7"
  exit 1
fi
url="https://github.com/spiritLHLS/Images/releases/download/v1.0/${system}.qcow2"
if [ ! -f "$file_path" ]; then
  curl -L -o "$file_path" "$url"
fi

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

if ! command -v iptables &> /dev/null; then
    green "iptables 未安装，正在安装..."
    apt-get install -y iptables
fi

first_digit=${vm_num:0:1}
second_digit=${vm_num:1:1}
third_digit=${vm_num:2:1}
if [ $first_digit -le 2 ]; then
  if [ $second_digit -eq 0 ]; then
    num=$third_digit
  else
    num=$second_digit$third_digit
  fi
else
  num=$((first_digit - 2))$second_digit$third_digit
fi

qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores $core --sockets 1 --net0 virtio,bridge=vmbr1
qm importdisk $vm_num /root/qcow/${system}.qcow2 local
qm set $vm_num --scsihw virtio-scsi-pci --scsi0 local:${vm_num}/vm-${vm_num}-disk-0.raw
qm set $vm_num --bootdisk scsi0
qm set $vm_num --boot order=scsi0
qm set $vm_num --memory $memory
qm set $vm_num --ide2 local:cloudinit
qm set $vm_num --nameserver 8.8.8.8
qm set $vm_num --searchdomain 8.8.4.4
user_ip="172.16.1.${num}"
qm set $vm_num --ipconfig0 ip=${user_ip}/24,gw=172.16.1.1
qm set $vm_num --cipassword $password --ciuser $user
qm resize $vm_num scsi0 ${disk}G
qm start $vm_num

if systemctl enable iptables > /dev/null 2>&1; then
  iptables -t nat -A POSTROUTING -o eth0 -j SNAT --to ${IPV4}
  iptables -t nat -A PREROUTING -i eth0 -p tcp -m tcp --dport ${sshn} -j DNAT --to-destination ${user_ip}:22
  iptables -t nat -A PREROUTING -i eth0 -p tcp -m tcp --dport ${web1_port} -j DNAT --to-destination ${user_ip}:80
  iptables -t nat -A PREROUTING -i eth0 -p tcp -m tcp --dport ${web2_port} -j DNAT --to-destination ${user_ip}:443
  iptables -t nat -A PREROUTING -i eth0 -p tcp -m tcp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
  iptables -t nat -A PREROUTING -i eth0 -p udp -m udp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
  service iptables save
  service iptables restart
else
  if ! systemctl is-active --quiet nftables; then
      systemctl start nftables
  fi
  if ! command -v nft >/dev/null 2>&1; then
      apt-get install nftables
  fi
  if ! nft list tables | grep -q nat; then
      nft add table nat
  fi
  if ! nft list table nat | grep -q postrouting; then
      nft add chain nat postrouting { type nat hook postrouting priority 0 \; }
      nft add rule nat postrouting oif eth0 snat to ${IPV4}
  fi
  if ! nft list table nat | grep -q prerouting; then
      nft add chain nat prerouting { type nat hook prerouting priority 0 \; }
  fi
  nft add rule nat prerouting iif eth0 tcp dport ${sshn} dnat to ${user_ip}:22
  nft add rule nat prerouting iif eth0 tcp dport ${web1_port} dnat to ${user_ip}:80
  nft add rule nat prerouting iif eth0 tcp dport ${web2_port} dnat to ${user_ip}:443
  nft add rule nat prerouting iif eth0 tcp dport ${port_first}-${port_last} dnat to ${user_ip}:${port_first}-${port_last}
  nft add rule nat prerouting iif eth0 udp dport ${port_first}-${port_last} dnat to ${user_ip}:${port_first}-${port_last}
  nft list ruleset > /etc/nftables.conf
  systemctl restart nftables.service
fi

echo "$vm_num $user $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system" >> "vm${vm_num}"
cat "vm${vm_num}"
