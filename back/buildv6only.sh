#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.04.13

# ./buildv6only.sh VMID 用户名 密码 CPU核数 内存 硬盘 系统
# ./buildv6only.sh 103 test2 1234567 1 512 5 debian11

cd /root >/dev/null 2>&1
# 创建容器
vm_num="${1:-103}"
user="${2:-test2}"
password="${3:-1234567}"
core="${4:-1}"
memory="${5:-512}"
disk="${6:-5}"
system="${7:-debian11}"
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

SUBNET_PREFIX=$(curl ipv6.ip.sb)
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

qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores $core --sockets 1 --cpu host --net0 virtio,bridge=vmbr0,firewall=0
qm importdisk $vm_num /root/qcow/${system}.qcow2 local
qm set $vm_num --scsihw virtio-scsi-pci --scsi0 local:${vm_num}/vm-${vm_num}-disk-0.raw
qm set $vm_num --bootdisk scsi0
qm set $vm_num --boot order=scsi0
qm set $vm_num --memory $memory
# --swap 256
qm set $vm_num --ide2 local:cloudinit
qm set $vm_num --nameserver 2602:fc23:18::7
qm set $vm_num --searchdomain dns.google
user_ip="${SUBNET_PREFIX}.${num}"
qm set $vm_num --ipconfig0 ip=${user_ip}/64,gw=${SUBNET_PREFIX}.1
qm set $vm_num --cipassword $password --ciuser $user
qm resize $vm_num scsi0 ${disk}G
qm start $vm_num
echo "$vm_num $user $password $core $memory $disk $system" >> "vm${vm_num}"
cat "vm${vm_num}"
