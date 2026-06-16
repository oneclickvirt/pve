#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.06.09
# ./buildvm.sh VMID 用户名 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘 独立IPV6
# ./buildvm.sh 102 test1 1234567 1 512 5 40001 40002 40003 50000 50025 debian11 local N

cd /root >/dev/null 2>&1

generate_password() {
    local value
    value=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
    if [ -z "$value" ]; then
        value="$(date +%s%N | md5sum | cut -c 3-14)"
    fi
    printf '%s' "$value"
}

validate_storage_name() {
    local value="$1"
    if [[ -z "$value" || ! "$value" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "Invalid storage name: $value"
        echo "存储盘名称无效：$value"
        exit 1
    fi
}

init_params() {
    vm_num="${1:-102}"
    user="${2:-test}"
    password="${3:-$(generate_password)}"
    core="${4:-1}"
    memory="${5:-512}"
    disk="${6:-5}"
    sshn="${7:-40001}"
    web1_port="${8:-40002}"
    web2_port="${9:-40003}"
    port_first="${10:-49975}"
    port_last="${11:-50000}"
    system="${12:-ubuntu22}"
    storage="${13:-local}"
    independent_ipv6="${14:-N}"
    validate_storage_name "$storage"
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
    if [ ! -d "qcow" ]; then
        mkdir qcow
    fi
    rm -rf "vm$vm_num"
}

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}")) # 打乱数组顺序
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    if [ "${WITHOUTCDN^^}" = "TRUE" ]; then
        export cdn_success_url=""
        echo "WITHOUTCDN=TRUE, skip CDN acceleration"
        echo "WITHOUTCDN=TRUE，跳过 CDN 加速"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        echo "CDN available, using CDN"
        echo "检测到可用 CDN，使用 CDN 加速"
    else
        echo "No CDN available, using original links"
        echo "未检测到可用 CDN，使用原始链接"
        export cdn_success_url=""
    fi
}

download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=5
    local attempt=1
    local delay=1
    while [ $attempt -le $max_attempts ]; do
        wget -q "$url" -O "$output" && return 0
        echo "Download failed: $url, try $attempt, wait $delay seconds and retry..."
        echo "下载失败：$url，尝试第 $attempt 次，等待 $delay 秒后重试..."
        sleep $delay
        attempt=$((attempt + 1))
        delay=$((delay * 2))
        [ $delay -gt 30 ] && delay=30
    done
    echo -e "\e[31mDownload failed: $url, maximum number of attempts exceeded ($max_attempts)\e[0m"
    echo -e "\e[31m下载失败：$url，超过最大尝试次数 ($max_attempts)\e[0m"
    return 1
}

load_default_config() {
    local config_url="${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/default_vm_config.sh"
    local config_file="default_vm_config.sh"
    if download_with_retry "$config_url" "$config_file"; then
        . "./$config_file"
    else
        echo -e "\e[31mUnable to load default configuration, script terminated.\e[0m"
        echo -e "\e[31m无法加载默认配置，脚本终止。\e[0m"
        exit 1
    fi
}

create_vm() {
    appended_file="/usr/local/bin/pve_appended_content.txt"
    if [ "$independent_ipv6" == "n" ]; then
        qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket \
            --cores $core --sockets 1 --cpu $cpu_type \
            --net0 virtio,bridge=vmbr1,firewall=0 \
            --ostype l26 \
            ${kvm_flag}
    else
        if [ -s "$appended_file" ]; then
            net1_bridge="vmbr1"
        else
            net1_bridge="vmbr2"
        fi
        qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket \
            --cores $core --sockets 1 --cpu $cpu_type \
            --net0 virtio,bridge=vmbr1,firewall=0 \
            --net1 virtio,bridge="$net1_bridge",firewall=0 \
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
    volid=$(pvesm list "$storage" | awk -v vmid="${vm_num}" '$5 == vmid && $1 ~ /\.raw$/ {print $1}' | tail -n 1)
    if [ -z "$volid" ]; then
        echo "No .raw file found for VM ID '${vm_num}' in storage '${storage}'. Searching for other formats..."
        echo "在存储 '${storage}' 中未找到 VM ID '${vm_num}' 的 .raw 文件，正在尝试其他格式..."
        volid=$(pvesm list "$storage" | awk -v vmid="${vm_num}" '$5 == vmid {print $1}' | tail -n 1)
    fi
    if [ -z "$volid" ]; then
        echo "Error: No file found for VM ID '${vm_num}' in storage '${storage}'"
        echo "错误：在存储 '${storage}' 中未找到 VM ID '${vm_num}' 对应的磁盘文件"
        return 1
    fi
    file_path=$(pvesm path ${volid})
    if [ $? -ne 0 ] || [ -z "$file_path" ]; then
        echo "Error: Failed to resolve path for volume '${volid}'"
        echo "错误：无法解析卷 '${volid}' 对应的路径"
        return 1
    fi
    file_name=$(basename "$file_path")
    echo "Found file: $file_name"
    echo "已找到磁盘文件：$file_name"
    echo "Attempting to set SCSI hardware with virtio-scsi-pci for VM $vm_num..."
    echo "正在尝试为 VM $vm_num 设置 virtio-scsi-pci SCSI 硬件..."
    qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:${vm_num}/vm-${vm_num}-disk-0.raw
    if [ $? -ne 0 ]; then
        echo "Failed to set SCSI hardware with vm-${vm_num}-disk-0.raw. Trying alternative disk file..."
        echo "使用 vm-${vm_num}-disk-0.raw 设置 SCSI 硬件失败，正在尝试其他磁盘文件..."
        qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:${vm_num}/$file_name
        if [ $? -ne 0 ]; then
            echo "Failed to set SCSI hardware with $file_name for VM $vm_num. Trying fallback file..."
            echo "使用 $file_name 为 VM $vm_num 设置 SCSI 硬件失败，正在尝试回退文件..."
            qm set $vm_num --scsihw virtio-scsi-pci --scsi0 ${storage}:$file_name
            if [ $? -ne 0 ]; then
                echo "All attempts failed. Exiting..."
                echo "所有尝试均失败，脚本退出..."
                return 1
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
    configure_network
    qm resize $vm_num scsi0 ${disk}G
    if [ $? -ne 0 ]; then
        if [[ $disk =~ ^[0-9]+G$ ]]; then
            dnum=${disk::-1}
            disk_m=$((dnum * 1024))
            qm resize $vm_num scsi0 ${disk_m}M
        fi
    fi
    qm start $vm_num
    return 0
}

configure_network() {
    user_ip="172.16.1.${vm_num}"
    if [ "$independent_ipv6" == "y" ]; then
        if [ ! -z "$host_ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
            qm set $vm_num --ipconfig0 ip=${user_ip}/24,gw=172.16.1.1
            appended_file="/usr/local/bin/pve_appended_content.txt"
            if [ -s "$appended_file" ]; then
                # 使用 vmbr1 网桥和 NAT 映射
                vm_internal_ipv6="2001:db8:1::${vm_num}"
                qm set $vm_num --ipconfig1 ip6="${vm_internal_ipv6}/64",gw6="2001:db8:1::1"
                host_external_ipv6=$(get_available_vmbr1_ipv6)
                if [ -z "$host_external_ipv6" ]; then
                    echo -e "\e[31mNo available IPv6 address found for NAT mapping\e[0m"
                    echo -e "\e[31m没有可用的IPv6地址用于NAT映射\e[0m"
                    independent_ipv6_status="N"
                else
                    setup_nat_mapping "$vm_internal_ipv6" "$host_external_ipv6"
                    vm_external_ipv6="$host_external_ipv6"
                    echo "VM configured with NAT mapping: $vm_internal_ipv6 -> $host_external_ipv6"
                    echo "虚拟机已配置NAT映射：$vm_internal_ipv6 -> $host_external_ipv6"
                    independent_ipv6_status="Y"
                fi
            elif grep -q "vmbr2" /etc/network/interfaces; then
                # 使用 vmbr2 网桥直接分配IPv6地址
                qm set $vm_num --ipconfig1 ip6="${ipv6_address_without_last_segment}${vm_num}/128",gw6="${host_ipv6_address}"
                vm_external_ipv6="${ipv6_address_without_last_segment}${vm_num}"
                independent_ipv6_status="Y"
                _fw6_drop_icmpv6_ping "${ipv6_address_without_last_segment}${vm_num}" "${ipv6_prefixlen:+${ipv6_address_without_last_segment}/${ipv6_prefixlen}}"
                _fw_save
            else
                independent_ipv6_status="N"
            fi
            qm set $vm_num --nameserver "1.1.1.1 2606:4700:4700::1111" || qm set $vm_num --nameserver 1.1.1.1
            qm set $vm_num --searchdomain local
        else
            independent_ipv6_status="N"
        fi
    else
        independent_ipv6_status="N"
    fi
    if [ "$independent_ipv6_status" == "N" ]; then
        qm set $vm_num --ipconfig0 ip=${user_ip}/24,gw=172.16.1.1
        qm set $vm_num --nameserver 8.8.8.8
        # qm set $vm_num --nameserver 8.8.4.4
        qm set $vm_num --searchdomain local
    fi
    qm set $vm_num --cipassword $password --ciuser $user
    sleep 5
}

setup_port_forwarding() {
    user_ip="172.16.1.${vm_num}"
    _fw_add_dnat "vmbr0" "tcp" "${sshn}" "${user_ip}:22"
    if [ "${web1_port}" -ne 0 ]; then
        _fw_add_dnat "vmbr0" "tcp" "${web1_port}" "${user_ip}:80"
    fi
    if [ "${web2_port}" -ne 0 ]; then
        _fw_add_dnat "vmbr0" "tcp" "${web2_port}" "${user_ip}:443"
    fi
    if [ "${port_first}" -ne 0 ] && [ "${port_last}" -ne 0 ]; then
        _fw_add_dnat_range "vmbr0" "tcp" "${port_first}-${port_last}" "${user_ip}:${port_first}-${port_last}"
        _fw_add_dnat_range "vmbr0" "udp" "${port_first}-${port_last}" "${user_ip}:${port_first}-${port_last}"
    fi
    _fw_save
}

save_vm_info() {
    if [ "$independent_ipv6_status" == "Y" ]; then
        echo "$vm_num $user $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system $storage $vm_external_ipv6" >>"vm${vm_num}"
        data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage 独立IPV6地址-ipv6_address")
    else
        echo "$vm_num $user $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system $storage" >>"vm${vm_num}"
        data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage")
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
    init_params "$@"
    validate_vm_num || exit 1
    get_system_arch || exit 1
    check_kvm_support
    prepare_system_image || exit 1
    check_ipv6_config || exit 1
    create_vm || exit 1
    setup_port_forwarding
    save_vm_info
}

main "$@"
rm -rf default_vm_config.sh
