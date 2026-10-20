#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.08.26
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
    pve_validate_guest_metadata vm "$vm_num" || return 1
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
    [[ "$independent_ipv6" == y || "$independent_ipv6" == n ]] || return 1
    if [ ! -d "qcow" ]; then
        mkdir qcow
    fi
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
    if [ -n "${PVE_DEFAULT_VM_CONFIG:-}" ]; then
        if [ ! -r "$PVE_DEFAULT_VM_CONFIG" ]; then
            echo "Local VM configuration is not readable: $PVE_DEFAULT_VM_CONFIG" >&2
            return 1
        fi
        . "$PVE_DEFAULT_VM_CONFIG"
        return $?
    fi
    local config_url="${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/default_vm_config.sh"
    local config_file="default_vm_config.sh"
    if download_with_retry "$config_url" "$config_file"; then
        downloaded_default_config="$config_file"
        . "./$config_file"
    else
        echo -e "\e[31mUnable to load default configuration, script terminated.\e[0m"
        echo -e "\e[31m无法加载默认配置，脚本终止。\e[0m"
        exit 1
    fi
}

create_vm() {
    appended_file="${PVE_IPV6_MAPPING_FILE:-/usr/local/bin/pve_appended_content.txt}"
    if [ "$independent_ipv6" == "n" ]; then
        qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket \
            --cores $core --sockets 1 --cpu $cpu_type \
            --net0 virtio,bridge=vmbr1,firewall=0 \
            --ostype l26 \
            --onboot 1 \
            ${kvm_flag} || return 1
    else
        if [ -s "$appended_file" ] || [ "${pve_direct_ipv6_available:-false}" != true ]; then
            net1_bridge="vmbr1"
        else
            net1_bridge="$(pve_direct_ipv6_bridge)" || return 1
        fi
        qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket \
            --cores $core --sockets 1 --cpu $cpu_type \
            --net0 virtio,bridge=vmbr1,firewall=0 \
            --net1 virtio,bridge="$net1_bridge",firewall=0 \
            --ostype l26 \
            --onboot 1 \
            ${kvm_flag} || return 1
    fi
    if [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
        qm importdisk $vm_num /root/qcow/${system}.qcow2 ${storage} || return 1
    else
        qm set $vm_num --bios ovmf || return 1
        qm importdisk $vm_num /root/qcow/${system}.${ext} ${storage} || return 1
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
    qm set "$vm_num" --scsihw virtio-scsi-pci --scsi0 "$volid" || return 1
    qm set $vm_num --bootdisk scsi0 || return 1
    qm set $vm_num --boot order=scsi0 || return 1
    qm set $vm_num --memory $memory || return 1
    # --swap 256
    if [[ "$system_arch" == "arm" ]]; then
        qm set $vm_num --scsi1 ${storage}:cloudinit || return 1
    else
        qm set $vm_num --ide1 ${storage}:cloudinit || return 1
    fi
    configure_network || return 1
    pve_resize_vm_disk || return 1
    qm start "$vm_num" || return 1
    return 0
}

configure_network() {
    user_ip="${pve_nat_prefix}.${vm_num}"
    qm set "$vm_num" --ipconfig0 "ip=${user_ip}/24,gw=${pve_nat_gateway}" || return 1
    independent_ipv6_status=N
    if [ "$independent_ipv6" == y ]; then
        pve_configure_vm_ipv6 1 || return 1
        qm set "$vm_num" --nameserver '1.1.1.1 2606:4700:4700::1111' || return 1
    else
        qm set "$vm_num" --nameserver 1.1.1.1 || return 1
    fi
    qm set "$vm_num" --searchdomain local || return 1
    qm set "$vm_num" --cipassword="$password" --ciuser="$user" || return 1
}

setup_port_forwarding() {
    user_ip="${pve_nat_prefix}.${vm_num}"
    if [ "${sshn}" -ne 0 ]; then
        _fw_add_dnat "vmbr0" "tcp" "${sshn}" "${user_ip}:22" || return 1
    fi
    if [ "${web1_port}" -ne 0 ]; then
        _fw_add_dnat "vmbr0" "tcp" "${web1_port}" "${user_ip}:80" || return 1
    fi
    if [ "${web2_port}" -ne 0 ]; then
        _fw_add_dnat "vmbr0" "tcp" "${web2_port}" "${user_ip}:443" || return 1
    fi
    if [ "${port_first}" -ne 0 ] && [ "${port_last}" -ne 0 ]; then
        _fw_add_dnat_range "vmbr0" "tcp" "${port_first}-${port_last}" "${user_ip}:${port_first}-${port_last}" || return 1
        _fw_add_dnat_range "vmbr0" "udp" "${port_first}-${port_last}" "${user_ip}:${port_first}-${port_last}" || return 1
    fi
    _fw_save || return 1
}

save_vm_info() {
    if [ "$independent_ipv6_status" != "N" ]; then
        metadata_values="$vm_num $user $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system $storage $vm_external_ipv6"
        data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage 独立IPV6地址-ipv6_address")
    else
        metadata_values="$vm_num $user $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system $storage"
        data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage")
    fi
    if [ "$independent_ipv6_status" = NAT66 ]; then
        data="${data//独立IPV6地址-ipv6_address/共享NAT66地址-ipv6_address}"
        data="${data//外网IPV6-ipv6/共享NAT66地址-ipv6}"
    fi
    pve_save_guest_record vm "$vm_num" "$metadata_values" "$data" || return 1
}

main() {
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    load_default_config || exit 1
    load_nat_ipv4_config || exit 1
    setup_locale
    init_params "$@" || exit 1
    validate_vm_num || exit 1
    pve_nat_ipv4_for_id "$vm_num" >/dev/null || exit 1
    get_system_arch || exit 1
    check_kvm_support
    prepare_system_image || exit 1
    check_ipv6_config || exit 1
    create_vm || exit 1
    setup_port_forwarding || exit 1
    save_vm_info || exit 1
}

main "$@"
if [ -n "${downloaded_default_config:-}" ]; then
    rm -f -- "$downloaded_default_config"
fi
