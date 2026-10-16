#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.08.26
# 手动指定要绑定的IPV4地址
# 情况1: 额外的IPV4地址需要与本机的IPV4地址在不同的子网内，即前缀不一致
# 此时开设出的虚拟机的网关为宿主机的IPV4地址，它充当透明网桥，并且不是路由路径的一部分。
# 这意味着到达路由器的数据包将具有开设出的虚拟机的源 MAC 地址。
# 如果路由器无法识别源 MAC 地址，流量将被标记为"滥用"，并"可能"导致服务器被阻止。
# (如果使用Hetzner的独立服务器务必提供附加IPV4地址对应的MAC地址防止被报告滥用)
# 情况2: 额外的IPV4地址需要与本机的IPV4地址在同一个子网内，即前缀一致
# 此时自动识别，使用的网关将与宿主机的网关一致

# ./buildvm_manual_ip.sh VMID 用户名 密码 CPU核数 内存 硬盘 系统 存储盘 IPV4地址(带子网掩码) 是否附加IPV6(默认为N) MAC地址(不提供时将不指定虚拟机的MAC地址)
# 示例：
# ./buildvm_manual_ip.sh 152 test1 examplePass123 1 512 5 debian11 local a.b.c.d/32 N 4c:52:62:0e:04:c6

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
    vm_num="${1:-152}"
    user="${2:-test}"
    password="${3:-$(generate_password)}"
    core="${4:-1}"
    memory="${5:-512}"
    disk="${6:-5}"
    system="${7:-ubuntu22}"
    storage="${8:-local}"
    extra_ip="${9}"
    independent_ipv6="${10:-N}"
    validate_storage_name "$storage"
    pve_validate_guest_metadata vm "$vm_num" || return 1
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
    [[ "$independent_ipv6" == y || "$independent_ipv6" == n ]] || return 1
    mac_address="${11}"
    user_ip=""
    user_ip_range=""
    gateway=""
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
        echo "No CDN available, no use CDN"
        echo "未检测到可用 CDN，不使用 CDN 加速"
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
        [ -r "$PVE_DEFAULT_VM_CONFIG" ] || return 1
        . "$PVE_DEFAULT_VM_CONFIG"
        return $?
    fi
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

get_network_info() {
    pve_public_ipv4_config manual "$extra_ip" || return 1
}

check_subnet() {
    # The shared live preflight validates the entire CIDR and gateway, rather
    # than comparing the first three octets or restarting the host network.
    same_subnet_status=true
}

create_vm() {
    appended_file="${PVE_IPV6_MAPPING_FILE:-/usr/local/bin/pve_appended_content.txt}"
    if [ -n "$mac_address" ]; then
        net0="--net0 virtio,bridge=vmbr0,firewall=0,macaddr=$mac_address"
    else
        net0="--net0 virtio,bridge=vmbr0,firewall=0"
    fi
    if [ "$independent_ipv6" = "y" ]; then
        if [ -s "$appended_file" ] || [ "${pve_direct_ipv6_available:-false}" != true ]; then
            net1="--net1 virtio,bridge=vmbr1,firewall=0"
        else
            direct_ipv6_bridge="$(pve_direct_ipv6_bridge)" || return 1
            net1="--net1 virtio,bridge=${direct_ipv6_bridge},firewall=0"
        fi
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
        --ostype l26 \
        $kvm_flag || return 1
}

import_disk_and_setup() {
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
        exit 1
    fi
    qm set "$vm_num" --scsihw virtio-scsi-pci --scsi0 "$volid" || return 1
    qm set $vm_num --bootdisk scsi0 || return 1
    qm set $vm_num --boot order=scsi0 || return 1
    qm set $vm_num --memory $memory || return 1
    if [[ "$system_arch" == "arm" ]]; then
        qm set $vm_num --scsi1 ${storage}:cloudinit || return 1
    else
        qm set $vm_num --ide1 ${storage}:cloudinit || return 1
    fi
}

configure_network() {
    user_ip="${user_ip}"
    qm set "$vm_num" --ipconfig0 "ip=${user_ip}/${user_ip_range},gw=${gateway}" || return 1
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

resize_and_start() {
    pve_resize_vm_disk || return 1
    pve_release_public_ipv4_lock || return 1
    qm start "$vm_num" || return 1
}

save_vm_info() {
    if [ "$independent_ipv6_status" == "N" ]; then
        metadata_values="$vm_num $user $password $core $memory $disk $system $storage $user_ip"
        data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage 外网IP地址-ipv4")
    else
        metadata_values="$vm_num $user $password $core $memory $disk $system $storage $user_ip $vm_external_ipv6"
        data=$(echo " VMID 用户名-username 密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage 外网IPV4-ipv4 外网IPV6-ipv6")
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
    pve_load_direct_ipv6_config || exit 1
    setup_locale
    get_system_arch || exit 1
    check_kvm_support
    init_params "$@" || exit 1
    validate_vm_num || exit 1
    get_network_info || exit 1
    check_subnet || exit 1
    check_ipv6_config || exit 1
    prepare_system_image || exit 1
    create_vm || exit 1
    import_disk_and_setup || exit 1
    configure_network || exit 1
    resize_and_start || exit 1
    save_vm_info || exit 1
}

main "$@"
if [ -n "${downloaded_default_config:-}" ]; then
    rm -f -- "$downloaded_default_config"
fi
