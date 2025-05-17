#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.17
# 自动选择要绑定的IPV4地址 额外的IPV4地址需要与本机的IPV4地址在同一个子网内，即前缀一致
# 此时开设出的虚拟机的网关为宿主机的IPV4的网关，不需要强制约定MAC地址。
# 此时附加的IPV4地址是宿主机目前的IPV4地址顺位后面的地址
# 比如目前是 1.1.1.32 然后 1.1.1.33 已经有虚拟机了，那么本脚本附加IP地址为 1.1.1.34

# ./buildvm_extra_ip.sh VMID 用户名 密码 CPU核数 内存 硬盘 系统 存储盘 是否附加IPV6(默认为N)
# ./buildvm_extra_ip.sh 152 test1 1234567 1 512 5 debian11 local N

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
    independent_ipv6="${9:-N}"
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
    rm -rf "vm$vm_num"
    user_ip=""
    user_ip_range=""
    gateway=""
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
    curl -L "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/default_vm_config.sh" -o default_vm_config.sh
    . ./default_vm_config.sh
}

get_host_network_info() {
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
    user_ip_range=$(echo "$user_main_ip_range" | cut -d'/' -f2)
    ip_range=$((32 - user_ip_range))
    range=$((2 ** ip_range - 3))
    IFS='.' read -r -a octets <<<"$user_main_ip"
    ip_list=()
    for ((i = 0; i < $range; i++)); do
        octet=$((i % 256))
        if [ $octet -gt 254 ]; then
            break
        fi
        ip="${octets[0]}.${octets[1]}.${octets[2]}.$((octets[3] + octet))"
        ip_list+=("$ip")
    done
    _green "当前宿主机可用的外网IP列表长度为${range}"
    for ip in "${ip_list[@]}"; do
        if ! ping -c 1 "$ip" >/dev/null; then
            user_ip="$ip"
            break
        fi
    done
    gateway=$(grep -E "iface $interface" -A 3 "/etc/network/interfaces" | grep "gateway" | awk '{print $2}' | head -n 1)
    if [ -z "$gateway" ]; then
        gateway=$(grep -E "iface vmbr0" -A 3 "/etc/network/interfaces" | grep "gateway" | awk '{print $2}' | head -n 1)
        if [ -z "$gateway" ]; then
            _red "宿主机网关查询失败"
            exit 1
        fi
    fi
    if [ -z "$user_ip" ]; then
        _red "可使用的IP列表查询失败"
        exit 1
    fi
    if [ -z "$user_ip_range" ]; then
        _red "本虚拟机将要绑定的IP选择失败"
        exit 1
    fi
    _green "当前虚拟机将绑定的IP为：${user_ip}"
    user_ip_prefix=$(echo "$user_ip" | awk -F '.' '{print $1"."$2"."$3}')
    user_main_ip_prefix=$(echo "$user_main_ip" | awk -F '.' '{print $1"."$2"."$3}')
    if [ "$user_ip_prefix" = "$user_main_ip_prefix" ]; then
        _yellow "宿主机的IPV4前缀与将要开设的虚拟机的IPV4前缀相同。"
    else
        _blue "宿主机的IPV4前缀与将要开设的虚拟机的IPV4前缀不同，请使用 需要手动指定IPV4地址的版本 的脚本"
        exit 1
    fi
}

create_vm() {
    if [ "$independent_ipv6" == "n" ]; then
        qm create $vm_num \
            --agent 1 \
            --scsihw virtio-scsi-single \
            --serial0 socket \
            --cores $core \
            --sockets 1 \
            --cpu $cpu_type \
            --net0 virtio,bridge=vmbr0,firewall=0 \
            --ostype l26 \
            ${kvm_flag}
    else
        qm create $vm_num \
            --agent 1 \
            --scsihw virtio-scsi-single \
            --serial0 socket \
            --cores $core \
            --sockets 1 \
            --cpu $cpu_type \
            --net0 virtio,bridge=vmbr0,firewall=0 \
            --net1 virtio,bridge=vmbr2,firewall=0 \
            --ostype l26 \
            ${kvm_flag}
    fi
    if [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
        qm importdisk $vm_num /root/qcow/${system}.qcow2 ${storage}
    else
        qm set $vm_num --bios ovmf
        qm importdisk $vm_num /root/qcow/${system}.${ext} ${storage}
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
}

configure_vm() {
    qm set $vm_num --bootdisk scsi0
    qm set $vm_num --boot order=scsi0
    qm set $vm_num --memory $memory
    if [[ "$system_arch" == "arm" ]]; then
        qm set $vm_num --scsi1 ${storage}:cloudinit
    else
        qm set $vm_num --ide1 ${storage}:cloudinit
    fi
    if [ "$independent_ipv6" == "y" ]; then
        if [ ! -z "$host_ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
            if grep -q "vmbr2" /etc/network/interfaces; then
                qm set $vm_num --ipconfig0 ip=${user_ip}/${user_ip_range},gw=${gateway}
                qm set $vm_num --ipconfig1 ip6="${ipv6_address_without_last_segment}${vm_num}/128",gw6="${host_ipv6_address}"
                qm set $vm_num --nameserver 1.1.1.1
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
        qm set $vm_num --ipconfig0 ip=${user_ip}/${user_ip_range},gw=${gateway}
        qm set $vm_num --nameserver 8.8.8.8
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

save_vm_info() {
    if [ "$independent_ipv6_status" == "Y" ]; then
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
    get_system_arch || exit 1
    check_kvm_support
    init_params "$@"
    validate_vm_num || exit 1
    get_host_network_info
    create_vm
    configure_vm
    save_vm_info
}

main "$@"
rm -rf default_vm_config.sh
