#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.04.20
# 手动指定要绑定的IPV4地址
# 情况1: 额外的IPV4地址需要与本机的IPV4地址在不同的子网内，即前缀不一致
# 此时开设出的虚拟机的网关为宿主机的IPV4地址，它充当透明网桥，并且不是路由路径的一部分。
# 这意味着到达路由器的数据包将具有开设出的虚拟机的源 MAC 地址。
# 如果路由器无法识别源 MAC 地址，流量将被标记为“滥用”，并“可能”导致服务器被阻止。
# (如果使用Hetzner的独立服务器务必提供附加IPV4地址对应的MAC地址防止被报告滥用)
# 情况2: 额外的IPV4地址需要与本机的IPV4地址在同一个子网内，即前缀一致
# 此时自动识别，使用的网关将与宿主机的网关一致

# ./buildvm_manual_ip.sh VMID 用户名 密码 CPU核数 内存 硬盘 系统 存储盘 IPV4地址(带子网掩码) 是否附加IPV6(默认为N) MAC地址(不提供时将不指定虚拟机的MAC地址)
# 示例：
# ./buildvm_manual_ip.sh 152 test1 oneclick123 1 512 5 debian11 local a.b.c.d/32 N 4c:52:62:0e:04:c6

cd /root >/dev/null 2>&1
# 创建独立IPV4地址的虚拟机
vm_num="${1:-152}"
user="${2:-test}"
password="${3:-123456}"
core="${4:-1}"
memory="${5:-512}"
disk="${6:-5}"
system="${7:-ubuntu22}"
storage="${8:-local}"
extra_ip="${9}"
independent_ipv6="${10:-N}"
independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
mac_address="${11}"
rm -rf "vm$name"
user_ip=""
user_ip_range=""
gateway=""

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    _green "Locale set to $utf8_locale"
fi
# 检测vm_num是否为数字
if ! [[ "$vm_num" =~ ^[0-9]+$ ]]; then
    _red "Error: vm_num must be a valid number."
    _red "错误：vm_num 必须是有效的数字。"
    exit 1
fi
# 检测vm_num是否在范围100到256之间
if [[ "$vm_num" -ge 100 && "$vm_num" -le 256 ]]; then
    _green "vm_num is valid: $vm_num"
else
    _red "Error: vm_num must be in the range 100 ~ 256."
    _red "错误： vm_num 需要在100到256以内。"
    exit 1
fi
num=$vm_num
if [[ -z "$extra_ip" ]]; then
    _yellow "No IPV4 address is manually assigned"
    _yellow "IPV4地址未手动指定"
    exit 1
else
    user_ip=$(echo "$extra_ip" | cut -d'/' -f1)
    user_ip_range=$(echo "$extra_ip" | cut -d'/' -f2)
    if is_ipv4 "$user_ip"; then
        _green "This IPV4 address will be used: ${user_ip}"
        _green "将使用此IPV4地址: ${user_ip}"
    else
        _yellow "IPV4 addresses do not conform to the rules"
        _yellow "IPV4地址不符合规则"
        exit 1
    fi
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

check_kvm_support() {
    if [ -e /dev/kvm ]; then
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            _green "KVM硬件加速可用，将使用硬件加速。"
            _green "KVM hardware acceleration is available. Using hardware acceleration."
            return 0
        fi
    fi
    if grep -E 'vmx|svm' /proc/cpuinfo >/dev/null; then
        _yellow "CPU支持虚拟化，但/dev/kvm不可用，请检查BIOS设置或内核模块。"
        _yellow "CPU supports virtualization, but /dev/kvm is not available. Please check BIOS settings or kernel modules."
    else
        _yellow "CPU不支持硬件虚拟化。"
        _yellow "CPU does not support hardware virtualization."
    fi
    _yellow "将使用QEMU软件模拟(TCG)模式，性能会受到影响。"
    _yellow "Falling back to QEMU software emulation (TCG). Performance will be affected."
    return 1
}

is_ipv4() {
    local ip=$1
    local regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    if [[ $ip =~ $regex ]]; then
        return 0 # 符合IPv4格式
    else
        return 1 # 不符合IPv4格式
    fi
}

check_cdn() {
    local o_url=$1
    for cdn_url in "${cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
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

cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
if [ ! -d "qcow" ]; then
    mkdir qcow
fi
get_system_arch
if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
    _red "This script can only run on machines under x86_64 or arm architecture."
    exit 1
fi
if check_kvm_support; then
    cpu_type="host"
else
    cpu_type="qemu64"
fi
if [ "$system_arch" = "x86" ]; then
    file_path=""
    # 过去手动修补的镜像
    old_images=(
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
    # 新的自动修补的镜像
    # response=$(curl -sSL -m 6 -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/oneclickvirt/pve_kvm_images/releases/tags/images")
    # # 如果 https://api.github.com/ 请求失败，则使用 https://githubapi.spiritlhl.workers.dev/ ，此时可能宿主机无IPV4网络
    # if [ -z "$response" ]; then
    #     response=$(curl -sSL -m 6 -H "Accept: application/vnd.github.v3+json" "https://githubapi.spiritlhl.workers.dev/repos/oneclickvirt/pve_kvm_images/releases/tags/images")
    # fi
    # # 如果 https://githubapi.spiritlhl.workers.dev/ 请求失败，则使用 https://githubapi.spiritlhl.top/ ，此时可能宿主机在国内
    # if [ -z "$response" ]; then
    #     response=$(curl -sSL -m 6 -H "Accept: application/vnd.github.v3+json" "https://githubapi.spiritlhl.top/repos/oneclickvirt/pve_kvm_images/releases/tags/images")
    # fi
    # if [[ -n "$response" ]]; then
    #     new_images=($(echo "$response" | grep -oP '"name": "\K[^"]+' | grep 'qcow2' | awk '{print $1}'))
    #     for ((i=0; i<${#new_images[@]}; i++)); do
    #         new_images[i]=${new_images[i]%.qcow2}
    #     done
    #     combined=($(echo "${old_images[@]}" "${new_images[@]}" | tr ' ' '\n' | sort -u))
    #     systems=("${combined[@]}")
    # else
    #     systems=("${old_images[@]}")
    # fi
    new_images=($(curl -slk -m 6 https://down.idc.wiki/Image/realServer-Template/current/qcow2/ | grep -o '<a href="[^"]*">' | awk -F'"' '{print $2}' | sed -n '/qcow2$/s#/Image/realServer-Template/current/qcow2/##p'))
    if [[ -n "$new_images" ]]; then
        for ((i = 0; i < ${#new_images[@]}; i++)); do
            new_images[i]=${new_images[i]%.qcow2}
        done
        combined=($(echo "${old_images[@]}" "${new_images[@]}" | tr ' ' '\n' | sort -u))
        systems=("${combined[@]}")
    else
        systems=("${old_images[@]}")
    fi
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
        # 使用新镜像，自动修补版本
        if [[ -n "$new_images" ]]; then
            for image in "${new_images[@]}"; do
                if [[ " ${image} " == *" $system "* ]]; then
                    ver="auto_build"
                    url="${cdn_success_url}https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/${image}.qcow2"
                    curl -Lk -o "$file_path" "$url"
                    if [ $? -ne 0 ]; then
                        _red "Failed to download $file_path"
                        ver=""
                        rm -rf "$file_path"
                        break
                    else
                        _blue "Use auto-fixed image: ${image}"
                        break
                    fi
                fi
            done
        fi
        # 使用旧镜像，手动修补版本
        if [[ -z "$ver" ]]; then
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
                    ver="${ver_name_list[$((index - 1))]}"
                    break
                fi
            done
            if [[ "$system" == "centos8-stream" ]]; then
                url="https://api.ilolicon.com/centos8-stream.qcow2"
                curl -Lk -o "$file_path" "$url"
                if [ $? -ne 0 ]; then
                    _red "Unable to download corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                    _red "无法下载对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                    rm -rf "$file_path"
                    exit 1
                else
                    _blue "Use manual-fixed image: ${system}"
                    break
                fi
            else
                if [[ -n "$ver" ]]; then
                    url="${cdn_success_url}https://github.com/oneclickvirt/kvm_images/releases/download/${ver}/${system}.qcow2"
                    curl -Lk -o "$file_path" "$url"
                    if [ $? -ne 0 ]; then
                        _red "Unable to download corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                        _red "无法下载对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                        rm -rf "$file_path"
                        exit 1
                    else
                        _blue "Use manual-fixed image: ${system}"
                        break
                    fi
                else
                    _red "Unable to install corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                    _red "无法安装对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                    exit 1
                fi
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
    if [ -n "$file_path" ] && [ ! -f "$file_path" ]; then
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
# 查询信息
if ! command -v lshw >/dev/null 2>&1; then
    apt-get install -y lshw
fi
if ! command -v ping >/dev/null 2>&1; then
    apt-get install -y iputils-ping
    apt-get install -y ping
fi
interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
user_main_ip_range=$(grep -A 1 "iface ${interface}" /etc/network/interfaces | grep "address" | awk '{print $2}' | head -n 1)
if [ -z "$user_main_ip_range" ]; then
    user_main_ip_range=$(grep -A 1 "iface vmbr0" /etc/network/interfaces | grep "address" | awk '{print $2}' | head -n 1)
    if [ -z "$user_main_ip_range" ]; then
        _red "Host available IP interval query failed"
        _red "宿主机可用IP区间查询失败"
        exit 1
    fi
fi
user_main_ip=$(echo "$user_main_ip_range" | cut -d'/' -f1)
# 宿主机的网关
gateway=$(grep -E "iface $interface" -A 3 "/etc/network/interfaces" | grep "gateway" | awk '{print $2}' | head -n 1)
if [ -z "$gateway" ]; then
    gateway=$(grep -E "iface vmbr0" -A 3 "/etc/network/interfaces" | grep "gateway" | awk '{print $2}' | head -n 1)
    if [ -z "$gateway" ]; then
        _red "Host gateway query failed"
        _red "宿主机网关查询失败"
        exit 1
    fi
fi
# echo "ip=${user_ip}/${user_ip_range},gw=${gateway}"
# 检查变量是否为空并执行相应操作
if [ -z "$user_ip" ]; then
    _red "Available IP match failed"
    _red "可使用的IP匹配失败"
    exit 1
fi
if [ -z "$user_ip_range" ]; then
    _red "Available subnet size match failed"
    _red "可使用的子网大小匹配失败"
    exit 1
fi
_green "The current IP to which the VM will be bound is: ${user_ip}"
_green "当前虚拟机将绑定的IP为：${user_ip}"
user_ip_prefix=$(echo "$user_ip" | awk -F '.' '{print $1"."$2"."$3}')
user_main_ip_prefix=$(echo "$user_main_ip" | awk -F '.' '{print $1"."$2"."$3}')
same_subnet_status=false
if [ "$user_ip_prefix" = "$user_main_ip_prefix" ]; then
    _yellow "The IPV4 prefix of the host is the same as the IPV4 prefix of the virtual machine that will be provisioned,"
    _yellow "If the additional IP address you want to bind to is one that follows the host IP in sequence, "
    _yellow "you may need to use the script that automatically selects the IPV4 address to bind to"
    _yellow "宿主机的IPV4前缀与将要开设的虚拟机的IPV4前缀相同"
    _yellow "如果你要绑定的额外IP地址是宿主机IP顺位后面的地址，你可能需要使用 自动选择要绑定的IPV4地址 的脚本"
    sleep 3
    same_subnet_status=true
else
    _blue "The IPV4 prefix of the host machine is different from the IPV4 prefix of the virtual machine that will be opened,"
    _blue "and the routes for the corresponding subnets will be appended automatically"
    _blue "宿主机的IPV4前缀与将要开设的虚拟机的IPV4前缀不同，将自动附加对应子网的路由"
    same_subnet_status=false
    # 检测是否需要添加路由到配置文件中
    if grep -q "iface vmbr0 inet static" /etc/network/interfaces && grep -q "post-up route add -net ${user_ip_prefix}.0/${user_ip_range} gw ${user_main_ip}" /etc/network/interfaces; then
        _blue "The route for the new subnet already exists and does not need to be added additionally."
        _blue "新的子网的路由已存在，无需额外添加"
    else
        _blue "The route for the new subnet does not exist and is being added..."
        _blue "新的子网的路由不存在，正在添加..."
        line_number=$(grep -n "iface vmbr0 inet static" /etc/network/interfaces | cut -d: -f1)
        line_number=$((line_number + 5))
        chattr -i /etc/network/interfaces
        sed -i "${line_number}i\post-up route add -net ${user_ip_prefix}.0/${user_ip_range} gw ${user_main_ip}" /etc/network/interfaces
        chattr +i /etc/network/interfaces
        _blue "Route added successfully, restarting network in progress..."
        _blue "路由添加成功，正在重启网络..."
        sleep 1
        systemctl restart networking
        sleep 1
    fi
fi
# 检测IPV6相关的信息
if [ "$independent_ipv6" == "y" ]; then
    # 检测ndppd服务是否启动了
    service_status=$(systemctl is-active ndpresponder.service)
    if [ "$service_status" == "active" ]; then
        _green "The ndpresponder service started successfully and is running, and the host can open a service with a separate IPV6 address."
        _green "ndpresponder服务启动成功且正在运行，宿主机可开设带独立IPV6地址的服务。"
    else
        _green "The status of the ndpresponder service is abnormal and the host may not open a service with a separate IPV6 address."
        _green "ndpresponder服务状态异常，宿主机不可开设带独立IPV6地址的服务。"
        exit 1
    fi
    if [ -f /usr/local/bin/pve_check_ipv6 ]; then
        host_ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
        ipv6_address_without_last_segment="${host_ipv6_address%:*}:"
    fi
    if [ -f /usr/local/bin/pve_ipv6_prefixlen ]; then
        ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
    fi
    if [ -f /usr/local/bin/pve_ipv6_gateway ]; then
        ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
    fi
else
    if [ -f /usr/local/bin/pve_check_ipv6 ]; then
        ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
        IFS="/" read -ra parts <<<"$ipv6_address"
        part_1="${parts[0]}"
        part_2="${parts[1]}"
        IFS=":" read -ra part_1_parts <<<"$part_1"
        if [ ! -z "${part_1_parts[*]}" ]; then
            part_1_last="${part_1_parts[-1]}"
            if [ "$part_1_last" = "$vm_num" ]; then
                ipv6_address=""
            else
                part_1_head=$(echo "$part_1" | awk -F':' 'BEGIN {OFS=":"} {last=""; for (i=1; i<NF; i++) {last=last $i ":"}; print last}')
                ipv6_address="${part_1_head}${vm_num}"
            fi
        fi
    fi
    if [ -f /usr/local/bin/pve_ipv6_prefixlen ]; then
        ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
    fi
    if [ -f /usr/local/bin/pve_ipv6_gateway ]; then
        ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
    fi
fi
if [ "$independent_ipv6" = "n" ] && [ -n "$mac_address" ]; then
    qm create "$vm_num" --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores "$core" --sockets 1 --cpu $cpu_type --net0 virtio,bridge=vmbr0,firewall=0,macaddr="$mac_address"
elif [ "$independent_ipv6" = "n" ]; then
    qm create "$vm_num" --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores "$core" --sockets 1 --cpu $cpu_type --net0 virtio,bridge=vmbr0,firewall=0
elif [ "$independent_ipv6" = "y" ] && [ -n "$mac_address" ]; then
    qm create "$vm_num" --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores "$core" --sockets 1 --cpu $cpu_type --net0 virtio,bridge=vmbr0,firewall=0,macaddr="$mac_address" --net1 virtio,bridge=vmbr2,firewall=0
elif [ "$independent_ipv6" = "y" ]; then
    qm create "$vm_num" --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores "$core" --sockets 1 --cpu $cpu_type --net0 virtio,bridge=vmbr0,firewall=0 --net1 virtio,bridge=vmbr2,firewall=0
fi
if [ "$system_arch" = "x86" ]; then
    qm importdisk $vm_num /root/qcow/${system}.qcow2 ${storage}
else
    qm set $vm_num --bios ovmf
    qm importdisk $vm_num /root/qcow/${system}.img ${storage}
fi
sleep 3
volid=$(pvesm list ${storage} | awk -v vmid="${vm_num}" '$5 == vmid && $1 ~ /\.raw$/ {print $1}' | tail -n 1)
if [ -z "$volid" ]; then
    echo "No .raw file found for VM ID '${vm_num}' in storage '${storage}'. Searching for other formats..."
    volid=$(pvesm list ${storage} | awk -v vmid="${vm_num}" '$5 == vmid {print $1}' | tail -n 1)
fi
if [ -z "$volid" ]; then
    echo "Error: No file found for VM ID '${vm_num}' in storage '${storage}'"
    exit 1
fi
file_path=$(pvesm path ${volid})
if [ $? -ne 0 ] || [ -z "$file_path" ]; then
    echo "Error: Failed to resolve path for volume '${volid}'"
    exit 1
fi
file_name=$(basename "$file_path")
echo "Found file: $file_name"
echo "Attempting to set SCSI hardware with virtio-scsi-pci for VM $vm_num..."
qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:${vm_num}/vm-${vm_num}-disk-0.raw
if [ $? -ne 0 ]; then
    echo "Failed to set SCSI hardware with vm-${vm_num}-disk-0.raw. Trying alternative disk file..."
    qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:${vm_num}/$file_name
    if [ $? -ne 0 ]; then
        echo "Failed to set SCSI hardware with $file_name for VM $vm_num. Trying fallback file..."
        qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:$file_name
        if [ $? -ne 0 ]; then
            echo "All attempts failed. Exiting..."
            exit 1
        fi
    fi
fi
qm set $vm_num --bootdisk scsi0
qm set $vm_num --boot order=scsi0
qm set $vm_num --memory $memory
# --swap 256
qm set $vm_num --ide2 ${storage}:cloudinit
if [ "$independent_ipv6" == "y" ]; then
    if [ ! -z "$host_ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
        if grep -q "vmbr2" /etc/network/interfaces; then
            # qm set $vm_num --ipconfig0 ip=${user_ip}/${user_ip_range},gw=${user_main_ip}
            _green "Use ${user_ip}/32 to set ipconfig0"
            if [ "$same_subnet_status" = true ]; then
                # 同子网则虚拟机的网关同宿主机
                qm set $vm_num --ipconfig0 ip=${user_ip}/${user_ip_range},gw=${gateway}
            else
                # 不同子网则虚拟机的网关为宿主机IP地址
                qm set $vm_num --ipconfig0 ip=${user_ip}/32,gw=${user_main_ip}
            fi
            qm set $vm_num --ipconfig1 ip6="${ipv6_address_without_last_segment}${vm_num}/128",gw6="${host_ipv6_address}"
            qm set $vm_num --nameserver 1.1.1.1
            # qm set $vm_num --nameserver 1.0.0.1
            qm set $vm_num --searchdomain local
            independent_ipv6_status="Y"
        else
            independent_ipv6_status="N"
        fi
    else
        independent_ipv6_status="N"
    fi
else
    independent_ipv6_status="N"
fi
if [ "$independent_ipv6_status" == "N" ]; then
    # if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ] || [ "$ipv6_prefixlen" -gt 112 ]; then
    # qm set $vm_num --ipconfig0 ip=${user_ip}/${user_ip_range},gw=${user_main_ip}
    _green "Use ${user_ip}/32 to set ipconfig0"
    if [ "$same_subnet_status" = true ]; then
        # 同子网则虚拟机的网关同宿主机
        qm set $vm_num --ipconfig0 ip=${user_ip}/${user_ip_range},gw=${gateway}
    else
        # 不同子网则虚拟机的网关为宿主机IP地址
        qm set $vm_num --ipconfig0 ip=${user_ip}/32,gw=${user_main_ip}
    fi
    qm set $vm_num --nameserver 8.8.8.8
    # qm set $vm_num --nameserver 8.8.4.4
    qm set $vm_num --searchdomain local
    # else
    #     qm set $vm_num --ipconfig0 ip=${user_ip}/${user_ip_range},gw=${gateway},ip6=${ipv6_address}/${ipv6_prefixlen},gw6=${ipv6_gateway}
    #     qm set $vm_num --nameserver 8.8.8.8,2001:4860:4860::8888
    #     qm set $vm_num --searchdomain 8.8.4.4,2001:4860:4860::8844
    # fi
fi
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

# 虚拟机的相关信息将会存储到对应的虚拟机的NOTE中，可在WEB端查看
if [ "$independent_ipv6_status" == "N" ]; then
    echo "$vm_num $user $password $core $memory $disk $system $storage $user_ip" >>"vm${vm_num}"
    data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage 外网IP地址-ipv4")
else
    echo "$vm_num $user $password $core $memory $disk $system $storage $user_ip ${ipv6_address_without_last_segment}${vm_num}" >>"vm${vm_num}"
    data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage 外网IPV4-ipv4 外网IPV6-ipv6")
fi
values=$(cat "vm${vm_num}")
IFS=' ' read -ra data_array <<<"$data"
IFS=' ' read -ra values_array <<<"$values"
length=${#data_array[@]}
for ((i = 0; i < $length; i++)); do
    echo "${data_array[$i]} ${values_array[$i]}"
    echo ""
done >"/tmp/temp${vm_num}.txt"
sed -i 's/^/# /' "/tmp/temp${vm_num}.txt"
cat "/etc/pve/qemu-server/${vm_num}.conf" >>"/tmp/temp${vm_num}.txt"
cp "/tmp/temp${vm_num}.txt" "/etc/pve/qemu-server/${vm_num}.conf"
rm -rf "/tmp/temp${vm_num}.txt"
cat "vm${vm_num}"
