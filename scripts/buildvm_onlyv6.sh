#!/bin/bash
# from 
# https://github.com/spiritLHLS/pve
# 2023.08.04
# 自动选择要绑定的IPV6地址
# ./buildvm_onlyv6.sh VMID 用户名 密码 CPU核数 内存 硬盘 系统 存储盘
# ./buildvm_onlyv6.sh 152 test1 1234567 1 512 5 debian11 local

cd /root >/dev/null 2>&1
# 创建NAT的虚拟机
vm_num="${1:-102}"
user="${2:-test}"
password="${3:-123456}"
core="${4:-1}"
memory="${5:-512}"
disk="${6:-5}"
system="${7:-ubuntu22}"
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

get_system_arch() {
    local sysarch="$(uname -m)"
    if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
        local sysarch="$(arch)"
    fi
    # 根据架构信息设置系统位数并下载文件,其余 * 包括了 x86_64
    case "${sysarch}" in
        "i386" | "i686" | "x86_64")
            system_arch="x86"
            ;;
        "armv7l" | "armv8" | "armv8l" | "aarch64")
            system_arch="arch"
            ;;
        *)
            system_arch=""
            ;;
    esac
}

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
if [ ! -d "qcow" ]; then
    mkdir qcow
fi
get_system_arch
if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
   _red "This script can only run on machines under x86_64 or arm architecture."
   exit 1
fi
if [ "$system_arch" = "x86" ]; then
    file_path=""
    systems=(
        "debian10" 
        "debian11"
        "debian12"
        "ubuntu18"
        "ubuntu20"
        "ubuntu22"
        "centos7"
        "archlinux"
        "almalinux8"
        "fedora33"
        "fedora34"
        "opensuse-leap-15"
        "alpinelinux_edge"
        "alpinelinux_stable"
        "rockylinux8"
        "centos8-stream"
        )
    for sys in ${systems[@]}; do
        if [[ "$system" == "$sys" ]]; then
            file_path="/root/qcow/${system}.qcow2"
            break
        fi
    done
    if [[ -z "$file_path" ]]; then
        _red "Unable to install corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
        _red "无法安装对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
        exit 1
    fi
    if [ ! -f "$file_path" ]; then
        check_cdn_file
        ver=""
        v20=("fedora34" "almalinux8" "debian11" "debian12" "ubuntu18" "ubuntu20" "ubuntu22" "centos7" "alpinelinux_edge" "alpinelinux_stable" "rockylinux8")
        v11=("ubuntu18" "ubuntu20" "ubuntu22" "debian10" "debian11")
        v10=("almalinux8" "archlinux" "fedora33" "opensuse-leap-15" "ubuntu18" "ubuntu20" "ubuntu22" "debian10" "debian11")
        ver_list=(v20 v11 v10)
        ver_name_list=("v2.0" "v1.1" "v1.0")
        for ver in "${ver_list[@]}"; do
            array_name="${ver}[@]"
            array=("${!array_name}")
            if [[ " ${array[*]} " == *" $system "* ]]; then
                index=$(echo ${ver_list[*]} | tr -s ' ' '\n' | grep -n "$ver" | cut -d':' -f1)
                ver="${ver_name_list[$((index-1))]}"
                break
            fi
        done
        if [[ "$system" == "centos8-stream" ]]; then
            url="https://git.ilolicon.dev/Ella-Alinda/images/raw/branch/main/centos8-stream.qcow2"
            curl -Lk -o "$file_path" "$url"
        else
            if [[ -n "$ver" ]]; then
                url="${cdn_success_url}https://github.com/oneclickvirt/kvm_images/releases/download/${ver}/${system}.qcow2"
                curl -Lk -o "$file_path" "$url"
            else
                _red "Unable to install corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                _red "无法安装对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                exit 1
            fi
        fi
    fi
elif [ "$system_arch" = "arch" ]; then
    systems=("ubuntu14" "ubuntu16" "ubuntu18" "ubuntu20" "ubuntu22")
    for sys in ${systems[@]}; do
        if [[ "$system" == "$sys" ]]; then
            file_path="/root/qcow/${system}.img"
            break
        fi
    done
    if [[ -z "$file_path" ]]; then
        # https://www.debian.org/mirror/list
        _red "Unable to install corresponding system, please check http://cloud-images.ubuntu.com for supported system images "
        _red "无法安装对应系统，请查看 http://cloud-images.ubuntu.com 支持的系统镜像 "
        exit 1
    fi
    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        case "$system" in
            ubuntu14)
                version="trusty"
                ;;
            ubuntu16)
                version="xenial"
                ;;
            ubuntu18)
                version="bionic"
                ;;
            ubuntu20)
                version="focal"
                ;;
            ubuntu22)
                version="jammy"
                ;;
            *)
                echo "Unsupported Ubuntu version."
                exit 1
                ;;
        esac
        url="http://cloud-images.ubuntu.com/${version}/current/${version}-server-cloudimg-arm64.img"
        curl -L -o "$file_path" "$url"
    fi
fi
# 检测IPV6相关的信息
if [ -f /usr/local/bin/pve_check_ipv6 ]; then
    ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
    IFS="/" read -ra parts <<< "$ipv6_address"
    part_1="${parts[0]}"
    part_2="${parts[1]}"
    IFS=":" read -ra part_1_parts <<< "$part_1"
    part_1_last="${part_1_parts[-1]}"
    if [ "$part_1_last" = "$vm_num" ]; then
        ipv6_address=""
    else
        part_1_head=$(echo "$part_1" | awk -F':' 'BEGIN {OFS=":"} {last=""; for (i=1; i<NF; i++) {last=last $i ":"}; print last}')
        ipv6_address="${part_1_head}${vm_num}"
    fi
fi
if [ -f /usr/local/bin/pve_ipv6_prefixlen ]; then
    ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
fi
if [ -f /usr/local/bin/pve_ipv6_gateway ]; then
    ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
fi
qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores $core --sockets 1 --cpu host --net0 virtio,bridge=vmbr0,firewall=0
if [ "$system_arch" = "x86" ]; then
    qm importdisk $vm_num /root/qcow/${system}.qcow2 ${storage}
else
    qm set $vm_num --bios ovmf
    qm importdisk $vm_num /root/qcow/${system}.img ${storage}
fi
sleep 3
raw_name=$(ls /var/lib/vz/images/${vm_num}/*.raw | xargs -n1 basename | tail -n 1)
if [ -n "$raw_name" ]; then
    qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:${vm_num}/${raw_name}
else
    qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:${vm_num}/vm-${vm_num}-disk-0.raw
fi
qm set $vm_num --bootdisk scsi0
qm set $vm_num --boot order=scsi0
qm set $vm_num --memory $memory
# --swap 256
qm set $vm_num --ide2 ${storage}:cloudinit
qm set $vm_num --nameserver 8.8.8.8
qm set $vm_num --searchdomain 8.8.4.4
qm set $vm_num --ipconfig1 ip=${ipv6_address}/${ipv6_prefixlen},gw=${ipv6_gateway}
qm set $vm_num --cipassword $password --ciuser $user
sleep 5
qm resize $vm_num scsi0 ${disk}G
if [ $? -ne 0 ]; then
    if [[ $disk =~ ^[0-9]+G$ ]]; then
        dnum=${disk::-1}
        disk_m=$((dnum * 1024))
        qm resize $vm_num scsi0 ${disk_m}M
    fi
fi
qm start $vm_num
echo "$vm_num $user $password $core $memory $disk $system $storage $ipv6_address" >> "vm${vm_num}"
# 虚拟机的相关信息将会存储到对应的虚拟机的NOTE中，可在WEB端查看
data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage 外网IPV6-ipv6")
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
