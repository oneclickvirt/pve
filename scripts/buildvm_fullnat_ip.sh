#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.04.20
# 创建NAT全端口映射的虚拟机
# 前置条件：
# 要用到的外网IPV4地址已绑定到vmbr0网卡上(手动附加时务必在PVE安装完毕且自动配置网关后再附加)，且宿主机的IPV4地址仍为顺序第一
# 即 使用 curl ip.sb 仍显示宿主机原有IPV4地址，但可通过额外的IPV4地址登录进入宿主机

# ./buildvm_fullnat_ip.sh VMID 用户名 密码 CPU核数 内存 硬盘 系统 存储盘 外网IPV4地址 是否附加IPV6(默认为N)
# 示例：
# ./buildvm_fullnat_ip.sh 152 test1 oneclick123 1 1024 10 debian11 local a.b.c.d N

cd /root >/dev/null 2>&1
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }

init_params() {
    vm_num="${1:-152}"
    user="${2:-test}"
    password="${3:-123456}"
    core="${4:-1}"
    memory="${5:-512}"
    disk="${6:-5}"
    system="${7:-ubuntu22}"
    storage="${8:-local}"
    extranet_ipv4="${9}"
    independent_ipv6="${10:-N}"
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
    rm -rf "vm$vm_num"
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
    if [[ -z "$utf8_locale" ]]; then
        _yellow "No UTF-8 locale found"
    else
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        _green "Locale set to $utf8_locale"
    fi
    if ! [[ "$vm_num" =~ ^[0-9]+$ ]]; then
        _red "Error: vm_num must be a valid number."
        _red "错误：vm_num 必须是有效的数字。"
        exit 1
    fi
    if [[ "$vm_num" -ge 100 && "$vm_num" -le 256 ]]; then
        _green "vm_num is valid: $vm_num"
    else
        _red "Error: vm_num must be in the range 100 ~ 256."
        _red "错误： vm_num 需要在100到256以内。"
        exit 1
    fi
    num=$vm_num
    if [[ -z "$extranet_ipv4" ]]; then
        _yellow "No IPV4 address is manually assigned"
        _yellow "IPV4地址未手动指定"
        exit 1
    else
        if is_ipv4 "$extranet_ipv4"; then
            _green "This IPV4 address will be used: ${extranet_ipv4}"
            _green "将使用此IPV4地址: ${extranet_ipv4}"
        else
            _yellow "IPV4 addresses do not conform to the rules"
            _yellow "IPV4地址不符合规则"
            exit 1
        fi
    fi
    cdn_urls=("http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    if [ ! -d "qcow" ]; then
        mkdir qcow
    fi
}

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
            cpu_type="host"
            kvm_flag="--kvm 1"
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
    cpu_type="qemu64"
    kvm_flag="--kvm 0"
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

download_image() {
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
}

check_network() {
    # 查询信息
    if ! command -v lshw >/dev/null 2>&1; then
        apt-get install -y lshw
    fi
    if ! command -v ping >/dev/null 2>&1; then
        apt-get install -y iputils-ping
        apt-get install -y ping
    fi
    interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
    _green "The current IP to which the VM will be bound is: ${extranet_ipv4}"
    _green "当前虚拟机将绑定的IP为：${extranet_ipv4}"
}

check_ipv6() {
    independent_ipv6_status="N"
    if [ "$independent_ipv6" == "y" ]; then
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
}

create_vm() {
    if [ "$independent_ipv6" = "n" ]; then
        qm create "$vm_num" \
            --agent 1 \
            --scsihw virtio-scsi-single \
            --serial0 socket \
            --cores "$core" \
            --sockets 1 \
            --cpu "$cpu_type" \
            --net0 virtio,bridge=vmbr1,firewall=0 \
            ${kvm_flag}
    elif [ "$independent_ipv6" = "y" ]; then
        qm create "$vm_num" \
            --agent 1 \
            --scsihw virtio-scsi-single \
            --serial0 socket \
            --cores "$core" \
            --sockets 1 \
            --cpu "$cpu_type" \
            --net0 virtio,bridge=vmbr1,firewall=0 \
            --net1 virtio,bridge=vmbr2,firewall=0 \
            ${kvm_flag}
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
}

configure_network() {
    user_ip="172.16.1.${num}"
    if [ "$independent_ipv6" == "y" ]; then
        if [ ! -z "$host_ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
            if grep -q "vmbr2" /etc/network/interfaces; then
                qm set $vm_num --ipconfig0 ip=${user_ip}/24,gw=172.16.1.1
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
        _green "Use ${user_ip}/32 to set ipconfig0"
        qm set $vm_num --ipconfig0 ip=${user_ip}/24,gw=172.16.1.1
        qm set $vm_num --nameserver 8.8.8.8
        # qm set $vm_num --nameserver 8.8.4.4
        qm set $vm_num --searchdomain local
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
}

setup_firewall() {
    iptables -t nat -A PREROUTING -d $extranet_ipv4 -p tcp -j DNAT --to-destination $user_ip
    iptables -t nat -A PREROUTING -d $extranet_ipv4 -p udp -j DNAT --to-destination $user_ip
    iptables -t nat -A POSTROUTING -s $user_ip -o vmbr0 -j SNAT --to-source $extranet_ipv4

    if [ ! -f "/etc/iptables/rules.v4" ]; then
        touch /etc/iptables/rules.v4
    fi
    iptables-save | awk '{if($1=="COMMIT"){delete x}}$1=="-A"?!x[$0]++:1' | iptables-restore
    iptables-save >/etc/iptables/rules.v4
    service netfilter-persistent restart
}

record_vm_info() {
    # 虚拟机的相关信息将会存储到对应的虚拟机的NOTE中，可在WEB端查看
    if [ "$independent_ipv6_status" == "N" ]; then
        echo "$vm_num $user $password $core $memory $disk $system $storage $extranet_ipv4" >>"vm${vm_num}"
        data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage 外网IP地址-ipv4")
    else
        echo "$vm_num $user $password $core $memory $disk $system $storage $extranet_ipv4 ${ipv6_address_without_last_segment}${vm_num}" >>"vm${vm_num}"
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
}

main() {
    init_params "$@"
    get_system_arch
    if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
        _red "This script can only run on machines under x86_64 or arm architecture."
        exit 1
    fi
    check_kvm_support
    download_image
    check_network
    check_ipv6
    create_vm
    configure_network
    setup_firewall
    record_vm_info
}

main "$@"
