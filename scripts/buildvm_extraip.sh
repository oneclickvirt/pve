#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.06.04

# ./buildvm_extraip.sh VMID 用户名 密码 CPU核数 内存 硬盘 系统 存储盘
# ./buildvm_extraip.sh 152 test1 1234567 1 512 5 debian11 local

cd /root >/dev/null 2>&1
# 创建容器
vm_num="${1:-152}"
user="${2:-test}"
password="${3:-123456}"
core="${4:-1}"
memory="${5:-512}"
disk="${6:-5}"
system="${7:-debian10}"
storage="${8:-local}"
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
url="${cdn_success_url}https://github.com/spiritLHLS/Images/releases/download/v1.1/${system}.qcow2"
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

# 查询信息
if ! command -v lshw > /dev/null 2>&1; then
      apt-get install -y lshw
fi
if ! command -v ping > /dev/null 2>&1; then
      apt-get install -y iputils-ping
      apt-get install -y ping
fi
interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
user_main_ip_range=$(grep -A 1 "iface ${interface}" /etc/network/interfaces | grep "address" | awk '{print $2}')
# 宿主机IP
user_main_ip=$(echo "$user_main_ip_range" | cut -d'/' -f1)
user_ip_range=$(echo "$user_main_ip_range" | cut -d'/' -f2)
ip_range=$((32 - user_ip_range))
# 子网长度-1
range=$((2 ** ip_range - 2))
IFS='.' read -r -a octets <<< "$user_main_ip"
ip_list=()
for ((i=0; i<=$range; i++)); do
  octet=$((i % 256))
  ip="${octets[0]}.${octets[1]}.${octets[2]}.$((octets[3] + octet))"
  ip_list+=("$ip")
done
# 宿主机的IP列表
for ip in "${ip_list[@]}"; do
  echo "$ip"
done
for ip in "${ip_list[@]}"; do
  if ! ping -c 1 "$ip" >/dev/null; then
    # 未使用的IP之一
    user_ip="$ip"
    break
  fi
done
# 宿主机的网关
gateway=$(grep -E "iface $interface" -A 2 "/etc/network/interfaces" | grep "gateway" | awk '{print $2}')
echo "ip=${user_ip}/${ip_range},gw=${gateway}"

# qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores $core --sockets 1 --cpu host --net0 virtio,bridge=vmbr0,firewall=0
# qm importdisk $vm_num /root/qcow/${system}.qcow2 ${storage}
# qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:${vm_num}/vm-${vm_num}-disk-0.raw
# qm set $vm_num --bootdisk scsi0
# qm set $vm_num --boot order=scsi0
# qm set $vm_num --memory $memory
# # --swap 256
# qm set $vm_num --ide2 ${storage}:cloudinit
# qm set $vm_num --nameserver 8.8.8.8
# qm set $vm_num --searchdomain 8.8.4.4
# qm set $vm_num --ipconfig0 ip=${user_ip}/${ip_range},gw=${gateway}
# qm set $vm_num --cipassword $password --ciuser $user
# # qm set $vm_num --agent 1
# qm resize $vm_num scsi0 ${disk}G
# qm start $vm_num

# echo "$vm_num $user $password $core $memory $disk $system $storage $user_ip" >> "vm${vm_num}"
# # 虚拟机的相关信息将会存储到对应的虚拟机的NOTE中，可在WEB端查看
# data=$(echo " VMID 用户名 密码 CPU核数 内存 硬盘 系统 存储盘 外网独立IP")
# values=$(cat "vm${vm_num}")
# IFS=' ' read -ra data_array <<< "$data"
# IFS=' ' read -ra values_array <<< "$values"
# length=${#data_array[@]}
# for ((i=0; i<$length; i++))
# do
#   echo "${data_array[$i]} ${values_array[$i]}"
#   echo ""
# done > "/tmp/temp${vm_num}.txt"
# sed -i 's/^/# /' "/tmp/temp${vm_num}.txt"
# cat "/etc/pve/qemu-server/${vm_num}.conf" >> "/tmp/temp${vm_num}.txt"
# cp "/tmp/temp${vm_num}.txt" "/etc/pve/qemu-server/${vm_num}.conf"
# rm -rf "/tmp/temp${vm_num}.txt"
# cat "vm${vm_num}"
