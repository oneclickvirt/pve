#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.09
# 创建NAT全端口映射的虚拟机
# 前置条件：
# 要用到的外网IPV4地址已绑定到vmbr0网卡上(手动附加时务必在PVE安装完毕且自动配置网关后再附加)，且宿主机的IPV4地址仍为顺序第一
# 即 使用 curl ip.sb 仍显示宿主机原有IPV4地址，但可通过额外的IPV4地址登录进入宿主机

# ./buildvm_fullnat_ip.sh VMID 用户名 密码 CPU核数 内存 硬盘 系统 存储盘 外网IPV4地址 是否附加IPV6(默认为N)
# 示例：
# ./buildvm_fullnat_ip.sh 152 test1 oneclick123 1 1024 10 debian11 local a.b.c.d N

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
    extranet_ipv4="${9}"
    independent_ipv6="${10:-N}"
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
    rm -rf "vm$vm_num"
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
    if [ ! -d "qcow" ]; then
        mkdir qcow
    fi
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
    qm set $vm_num --bootdisk scsi0
    qm set $vm_num --boot order=scsi0
    qm set $vm_num --memory $memory
    # --swap 256
    if [[ "$system_arch" == "arm" ]]; then
        qm set $vm_num --scsi1 ${storage}:cloudinit
    else
        qm set $vm_num --ide1 ${storage}:cloudinit
    fi
}

configure_network() {
    user_ip="172.16.1.${vm_num}"
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
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    load_default_config || exit 1
    setup_locale
    get_system_arch || exit 1
    check_kvm_support
    init_params "$@"
    validate_vm_num || exit 1
    prepare_system_image
    check_network
    check_ipv6_config
    create_vm
    configure_network
    setup_firewall
    record_vm_info
}

main "$@"
rm -rf default_vm_config.sh