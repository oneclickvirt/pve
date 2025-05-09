#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.09
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

init_params() {
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
    if [[ -z "$extra_ip" ]]; then
        _yellow "IPV4地址未手动指定"
        exit 1
    else
        user_ip=$(echo "$extra_ip" | cut -d'/' -f1)
        user_ip_range=$(echo "$extra_ip" | cut -d'/' -f2)
        if is_ipv4 "$user_ip"; then
            _green "将使用此IPV4地址: ${user_ip}"
        else
            _yellow "IPV4地址不符合规则"
            exit 1
        fi
    fi
    if [ ! -d "qcow" ]; then
        mkdir qcow
    fi
    rm -rf "vm$vm_num"
}

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}")) # 打乱数组顺序
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
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
        echo "CDN available, using CDN"
    else
        echo "No CDN available, no use CDN"
    fi
}

load_default_config() {
    curl -L "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/default_config.sh" -o default_config.sh
    . ./default_config.sh
}

get_network_info() {
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
            _red "宿主机可用IP区间查询失败"
            exit 1
        fi
    fi
    user_main_ip=$(echo "$user_main_ip_range" | cut -d'/' -f1)
    gateway=$(grep -E "iface $interface" -A 3 "/etc/network/interfaces" | grep "gateway" | awk '{print $2}' | head -n 1)
    if [ -z "$gateway" ]; then
        gateway=$(grep -E "iface vmbr0" -A 3 "/etc/network/interfaces" | grep "gateway" | awk '{print $2}' | head -n 1)
        if [ -z "$gateway" ]; then
            _red "宿主机网关查询失败"
            exit 1
        fi
    fi
    if [ -z "$user_ip" ]; then
        _red "可使用的IP匹配失败"
        exit 1
    fi
    if [ -z "$user_ip_range" ]; then
        _red "可使用的子网大小匹配失败"
        exit 1
    fi
    _green "当前虚拟机将绑定的IP为：${user_ip}"
}

check_subnet() {
    user_ip_prefix=$(echo "$user_ip" | awk -F '.' '{print $1"."$2"."$3}')
    user_main_ip_prefix=$(echo "$user_main_ip" | awk -F '.' '{print $1"."$2"."$3}')
    same_subnet_status=false
    if [ "$user_ip_prefix" = "$user_main_ip_prefix" ]; then
        _yellow "宿主机的IPV4前缀与将要开设的虚拟机的IPV4前缀相同"
        _yellow "如果你要绑定的额外IP地址是宿主机IP顺位后面的地址，你可能需要使用 自动选择要绑定的IPV4地址 的脚本"
        sleep 3
        same_subnet_status=true
    else
        _blue "宿主机的IPV4前缀与将要开设的虚拟机的IPV4前缀不同，将自动附加对应子网的路由"
        same_subnet_status=false
        if grep -q "iface vmbr0 inet static" /etc/network/interfaces && grep -q "post-up route add -net ${user_ip_prefix}.0/${user_ip_range} gw ${user_main_ip}" /etc/network/interfaces; then
            _blue "新的子网的路由已存在，无需额外添加"
        else
            _blue "新的子网的路由不存在，正在添加..."
            line_number=$(grep -n "iface vmbr0 inet static" /etc/network/interfaces | cut -d: -f1)
            line_number=$((line_number + 5))
            chattr -i /etc/network/interfaces
            sed -i "${line_number}i\post-up route add -net ${user_ip_prefix}.0/${user_ip_range} gw ${user_main_ip}" /etc/network/interfaces
            chattr +i /etc/network/interfaces
            _blue "路由添加成功，正在重启网络..."
            sleep 1
            systemctl restart networking
            sleep 1
        fi
    fi
}

create_vm() {
    if [ -n "$mac_address" ]; then
        net0="--net0 virtio,bridge=vmbr0,firewall=0,macaddr=$mac_address"
    else
        net0="--net0 virtio,bridge=vmbr0,firewall=0"
    fi
    if [ "$independent_ipv6" = "y" ]; then
        net1="--net1 virtio,bridge=vmbr2,firewall=0"
    else
        net1=""
    fi
    qm create "$vm_num" \
        --agent 1 \
        --scsihw virtio-scsi-single \
        --serial0 socket \
        --cores "$core" \
        --sockets 1 \
        --cpu "$cpu_type" \
        $net0 \
        $net1 \
        $kvm_flag
}

import_disk_and_setup() {
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
    if [[ "$system_arch" == "arm" ]]; then
        qm set $vm_num --scsi1 ${storage}:cloudinit
    else
        qm set $vm_num --ide1 ${storage}:cloudinit
    fi
}

configure_network() {
    independent_ipv6_status="N"
    if [ "$independent_ipv6" == "y" ]; then
        if [ ! -z "$host_ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
            if grep -q "vmbr2" /etc/network/interfaces; then
                _green "Use ${user_ip}/32 to set ipconfig0"
                if [ "$same_subnet_status" = true ]; then
                    qm set $vm_num --ipconfig0 ip=${user_ip}/${user_ip_range},gw=${gateway}
                else
                    qm set $vm_num --ipconfig0 ip=${user_ip}/32,gw=${user_main_ip}
                fi

                qm set $vm_num --ipconfig1 ip6="${ipv6_address_without_last_segment}${vm_num}/128",gw6="${host_ipv6_address}"
                qm set $vm_num --nameserver 1.1.1.1
                qm set $vm_num --searchdomain local
                independent_ipv6_status="Y"
            fi
        fi
    fi
    if [ "$independent_ipv6_status" == "N" ]; then
        _green "Use ${user_ip}/32 to set ipconfig0"
        if [ "$same_subnet_status" = true ]; then
            qm set $vm_num --ipconfig0 ip=${user_ip}/${user_ip_range},gw=${gateway}
        else
            qm set $vm_num --ipconfig0 ip=${user_ip}/32,gw=${user_main_ip}
        fi

        qm set $vm_num --nameserver 8.8.8.8
        qm set $vm_num --searchdomain local
    fi
    qm set $vm_num --cipassword $password --ciuser $user
}

resize_and_start() {
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

save_vm_info() {
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
}

main() {
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    load_default_config || exit 1
    setup_locale
    get_system_arch
    if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
        _red "This script can only run on machines under x86_64 or arm architecture."
        exit 1
    fi
    check_kvm_support
    init_params "$@"
    validate_params
    get_network_info
    check_subnet
    check_ipv6_config
    prepare_system_image
    create_vm
    import_disk_and_setup
    configure_network
    resize_and_start
    save_vm_info
}

main "$@"
rm -rf default_config.sh