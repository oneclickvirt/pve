#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.05.29

# ./buildvm.sh VMID 用户名 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘
# ./buildvm.sh 102 test1 1234567 1 512 5 40001 40002 40003 50000 50025 debian11 local

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
system="${12:-debian10}"
storage="${13:-local}"
# in="${12:-300}"
# out="${13:-300}"
rm -rf "vm$name"

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
if [[ -z "$utf8_locale" ]]; then
  _yellow "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
  _green "Locale set to $utf8_locale"
fi

check_cdn() {
  local o_url=$1
  for cdn_url in "${cdn_urls[@]}"; do
    if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" > /dev/null 2>&1; then
      export cdn_success_url="$cdn_url"
      return
    fi
    sleep 0.5
  done
  export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, no use CDN"
    fi
}

cdn_urls=("https://cdn.spiritlhl.workers.dev/" "https://cdn3.spiritlhl.net/" "https://cdn1.spiritlhl.net/" "https://ghproxy.com/" "https://cdn2.spiritlhl.net/")
check_cdn_file
if [ ! -d "qcow" ]; then
  mkdir qcow
fi
# "centos7" "alpinelinux_v3_15" "alpinelinux_v3_17" "rockylinux8" "QuTScloud_5.0.1" 
systems=("debian10" "debian11" "debian9" "ubuntu18" "ubuntu20" "ubuntu22" "archlinux" "centos9-stream" "centos8-stream" "almalinux8" "almalinux9" "fedora33" "fedora34" "opensuse-leap-15")
for sys in ${systems[@]}; do
  if [[ "$system" == "$sys" ]]; then
    file_path="/root/qcow/${system}.qcow2"
    break
  fi
done
if [[ -z "$file_path" ]]; then
  # centos9-stream centos8-stream centos7 almalinux8 almalinux9
  echo "无法安装对应系统，请查看 https://github.com/spiritLHLS/Images/ 支持的系统镜像 "
  exit 1
fi
# v1.0 基础安装包预安装
# v1.1 增加agent安装包预安装，方便在宿主机上看到虚拟机的进程
url="${cdn_success_url}https://github.com/spiritLHLS/Images/releases/download/v1.0/${system}.qcow2"
if [ ! -f "$file_path" ]; then
  curl -L -o "$file_path" "$url"
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

qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores $core --sockets 1 --cpu host --net0 virtio,bridge=vmbr1,firewall=0
qm importdisk $vm_num /root/qcow/${system}.qcow2 local
qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:${vm_num}/vm-${vm_num}-disk-0.raw
qm set $vm_num --bootdisk scsi0
qm set $vm_num --boot order=scsi0
qm set $vm_num --memory $memory
# --swap 256
qm set $vm_num --ide2 local:cloudinit
qm set $vm_num --nameserver 8.8.8.8
qm set $vm_num --searchdomain 8.8.4.4
user_ip="172.16.1.${num}"
qm set $vm_num --ipconfig0 ip=${user_ip}/24,gw=172.16.1.1
qm set $vm_num --cipassword $password --ciuser $user
# qm set $vm_num --agent 1
qm resize $vm_num scsi0 ${disk}G
qm start $vm_num

iptables -t nat -A PREROUTING -p tcp --dport ${sshn} -j DNAT --to-destination ${user_ip}:22
iptables -t nat -A PREROUTING -p tcp -m tcp --dport ${web1_port} -j DNAT --to-destination ${user_ip}:80
iptables -t nat -A PREROUTING -p tcp -m tcp --dport ${web2_port} -j DNAT --to-destination ${user_ip}:443
iptables -t nat -A PREROUTING -p tcp -m tcp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
iptables -t nat -A PREROUTING -p udp -m udp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
if [ ! -f "/etc/iptables/rules.v4" ]; then
    touch /etc/iptables/rules.v4
fi
iptables-save > /etc/iptables/rules.v4
service netfilter-persistent restart
echo "$vm_num $user $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system $storage" >> "vm${vm_num}"
# 虚拟机的相关信息将会存储到对应的虚拟机的NOTE中，可在WEB端查看
data=$(echo " VMID 用户名 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘")
values=$(cat "vm${vm_num}")
IFS=' ' read -ra data_array <<< "$data"
IFS=' ' read -ra values_array <<< "$values"
length=${#data_array[@]}
for ((i=0; i<$length; i++))
do
  echo "${data_array[$i]} ${values_array[$i]}"
  echo ""
done > "/tmp/temp${vm_num}.txt"
sed -i 's/^/# /' "/tmp/temp${vm_num}.txt"
cat "/etc/pve/qemu-server/${vm_num}.conf" >> "/tmp/temp${vm_num}.txt"
cp "/tmp/temp${vm_num}.txt" "/etc/pve/qemu-server/${vm_num}.conf"
rm -rf "/tmp/temp${vm_num}.txt"
cat "vm${vm_num}"
