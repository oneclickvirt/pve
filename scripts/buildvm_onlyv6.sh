#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.17
# 自动选择要绑定的IPV6地址
# ./buildvm_onlyv6.sh VMID 用户名 密码 CPU核数 内存 硬盘 系统 存储盘
# ./buildvm_onlyv6.sh 152 test1 1234567 1 512 5 debian11 local

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
    rm -rf "vm$vm_num"
    if [ ! -d "qcow" ]; then
        mkdir qcow
    fi
}

check_environment() {
    if [ ! -f /usr/local/bin/pve_check_ipv6 ]; then
        _yellow "No ipv6 address exists to open a server with a standalone IPV6 address"
    fi
    if ! grep -q "vmbr2" /etc/network/interfaces; then
        _yellow "No vmbr2 exists to open a server with a standalone IPV6 address"
    fi
    service_status=$(systemctl is-active ndpresponder.service)
    if [ "$service_status" == "active" ]; then
        _green "The ndpresponder service started successfully and is running, and the host can open a service with a separate IPV6 address."
        _green "ndpresponder服务启动成功且正在运行，宿主机可开设带独立IPV6地址的服务。"
    else
        _green "The status of the ndpresponder service is abnormal and the host may not open a service with a separate IPV6 address."
        _green "ndpresponder服务状态异常，宿主机不可开设带独立IPV6地址的服务。"
        exit 1
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

get_ipv6_info() {
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
}

create_vm() {
    qm create $vm_num \
        --agent 1 \
        --scsihw virtio-scsi-single \
        --serial0 socket \
        --cores $core \
        --sockets 1 \
        --cpu $cpu_type \
        --net0 virtio,bridge=vmbr1,firewall=0 \
        --net1 virtio,bridge=vmbr2,firewall=0 \
        --ostype l26 \
        ${kvm_flag}
    if [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
        qm importdisk $vm_num /root/qcow/${system}.qcow2 ${storage}
    else
        qm set $vm_num --bios ovmf
        qm importdisk $vm_num /root/qcow/${system}.${ext} ${storage}
    fi
    sleep 3
}

configure_vm() {
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
    qm set $vm_num --nameserver 1.1.1.1
    # qm set $vm_num --nameserver 1.0.0.1
    qm set $vm_num --searchdomain local
    user_ip="172.16.1.${vm_num}"
    qm set $vm_num --ipconfig0 ip=${user_ip}/24,gw=172.16.1.1
    qm set $vm_num --ipconfig1 ip6="${ipv6_address_without_last_segment}${vm_num}/128",gw6="${host_ipv6_address}"
    qm set $vm_num --cipassword $password --ciuser $user
    sleep 5
}

resize_disk() {
    qm resize $vm_num scsi0 ${disk}G
    if [ $? -ne 0 ]; then
        if [[ $disk =~ ^[0-9]+G$ ]]; then
            dnum=${disk::-1}
            disk_m=$((dnum * 1024))
            qm resize $vm_num scsi0 ${disk_m}M
        fi
    fi
}

start_vm_and_save_info() {
    qm start $vm_num
    echo "$vm_num $user $password $core $memory $disk $system $storage ${ipv6_address_without_last_segment}${vm_num}" >>"vm${vm_num}"
    # 虚拟机的相关信息将会存储到对应的虚拟机的NOTE中，可在WEB端查看
    data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage 外网IPV6-ipv6")
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
    init_params "$@"
    validate_vm_num || exit 1
    check_environment
    get_system_arch || exit 1
    check_kvm_support
    prepare_system_image
    get_ipv6_info
    create_vm
    configure_vm
    resize_disk
    start_vm_and_save_info
}

main "$@"
rm -rf default_vm_config.sh
