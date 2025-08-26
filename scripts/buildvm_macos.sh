#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.06.09

# ./build_macos_vm.sh VMID CPU核数 内存 硬盘 SSH端口 VNC端口 系统 存储盘 独立IPV6
# ./build_macos_vm.sh 100 2 4096 45 44022 45901 high-sierra local N

cd /root >/dev/null 2>&1

init_params() {
    vm_num="${1:-102}"
    core="${2:-1}"
    memory="${3:-512}"
    disk="${4:-5}"
    sshn="${5:-40001}"
    vnc_port="${6:-5901}"
    system="${7:-big‑sur}"
    storage="${8:-local}"
    independent_ipv6="${9:-N}"
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
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
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        echo "CDN available, using CDN"
    else
        echo "No CDN available, no use CDN"
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

check_cpu_vendor() {
    # 检查是否为AMD或Intel CPU
    if grep -q "AMD" /proc/cpuinfo; then
        cpu_vendor="amd"
    elif grep -q "Intel" /proc/cpuinfo; then
        cpu_vendor="intel"
    else
        cpu_vendor="unknown"
    fi
    _green "CPU厂商: $cpu_vendor"
}

check_kvm_support_for_macos() {
    if [ -e /dev/kvm ]; then
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            _green "KVM硬件加速可用，将使用硬件加速。"
            if [ "$cpu_vendor" = "amd" ]; then
                # AMD CPU必须使用Penryn类型，但在Proxmox参数中使用默认值q35
                cpu_type="q35"
                kvm_flag="--kvm 1"
                cpu_args="-device isa-applesmc,osk=\"ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc\" -smbios type=2 -device usb-kbd,bus=ehci.0,port=2 -device usb-mouse,bus=ehci.0,port=3 -cpu Penryn,kvm=on,vendor=GenuineIntel,+kvm_pv_unhalt,+kvm_pv_eoi,+hypervisor,+invtsc,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+fma,+bmi1,+bmi2,+xsave,+xsaveopt,check"
            else
                # 非AMD CPU使用host
                cpu_type="q35"
                kvm_flag="--kvm 1"
                cpu_args="-device isa-applesmc,osk=\"ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc\" -smbios type=2 -device usb-kbd,bus=ehci.0,port=2 -device usb-mouse,bus=ehci.0,port=3 -cpu host,kvm=on,vendor=GenuineIntel,+kvm_pv_unhalt,+kvm_pv_eoi,+hypervisor,+invtsc"
            fi
            return 0
        fi
    fi
    if grep -E 'vmx|svm' /proc/cpuinfo >/dev/null; then
        _yellow "CPU支持虚拟化，但/dev/kvm不可用，请检查BIOS设置或内核模块。"
    else
        _yellow "CPU不支持硬件虚拟化。"
    fi
    _yellow "将使用QEMU软件模拟(TCG)模式，性能会受到影响。"
    # 软件模拟模式下使用qemu64
    cpu_type="q35"
    kvm_flag="--kvm 0"
    cpu_args="-device isa-applesmc,osk=\"ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc\" -smbios type=2 -device usb-kbd,bus=ehci.0,port=2 -device usb-mouse,bus=ehci.0,port=3 -cpu qemu64"
    return 1
}

check_iso_exists() {
    system_iso="/var/lib/vz/template/iso/${system}.iso"
    opencore_iso="/var/lib/vz/template/iso/opencore.iso"
    if [ ! -f "$system_iso" ]; then
        _red "错误：系统镜像 '${system}.iso' 未找到"
        _yellow "当前支持的系统镜像有："
        available_isos=$(find /var/lib/vz/template/iso/ -name "*.iso" | sed 's|/var/lib/vz/template/iso/||g' | sed 's/\.iso$//g' | sort)
        for iso in $available_isos; do
            _green "- $iso"
        done
        return 1
    fi
    if [ ! -f "$opencore_iso" ]; then
        _red "错误：OpenCore引导镜像 'opencore.iso' 未找到"
        return 1
    fi
    return 0
}

create_vm() {
    if [[ "$system" == "high-sierra" || "$system" == "mojave" ]]; then
        disk_device="--sata0"
    else
        disk_device="--virtio0"
    fi
    if [ "$independent_ipv6" == "n" ]; then
        qm create $vm_num --agent 1 --scsihw virtio-scsi-pci \
            --cores $core --sockets 1 \
            --net0 vmxnet3,bridge=vmbr1,firewall=0 \
            --args "$cpu_args" \
            --machine q35 \
            --ostype other \
            --bios ovmf \
            --memory $memory \
            --vga vmware \
            --balloon 0 \
            --tablet 1 \
            --autostart 0 \
            --onboot 0 \
            --numa 0 \
            --vmgenid 1 \
            --name macos-${vm_num} \
            ${kvm_flag}
    else
        qm create $vm_num --agent 1 --scsihw virtio-scsi-pci \
            --cores $core --sockets 1 \
            --net0 vmxnet3,bridge=vmbr1,firewall=0 \
            --net1 vmxnet3,bridge=vmbr2,firewall=0 \
            --args "$cpu_args" \
            --machine q35 \
            --ostype other \
            --bios ovmf \
            --memory $memory \
            --vga vmware \
            --balloon 0 \
            --tablet 1 \
            --autostart 0 \
            --onboot 0 \
            --numa 0 \
            --vmgenid 1 \
            --name macos-${vm_num} \
            ${kvm_flag}
    fi
    qm set $vm_num --efidisk0 ${storage}:4
    if [[ "$system" == "high-sierra" || "$system" == "mojave" ]]; then
        qm set $vm_num --sata0 ${storage}:${disk},cache=none,ssd=1,discard=on
        if [ $? -ne 0 ]; then
            echo "Failed to mount ${storage}:${disk}. Trying alternative disk file..."
            qm set $vm_num --sata0 ${storage}-lvm:${disk},cache=none,ssd=1,discard=on
            if [ $? -ne 0 ]; then
                echo "Failed to mount ${storage}-lvm:${disk}. Trying fallback file..."
                echo "All attempts to mount SATA disk failed for VM $vm_num. Exiting..."
                exit 1
            fi
        fi
        qm resize $vm_num sata0 ${disk}G
        if [ $? -ne 0 ]; then
            if [[ $disk =~ ^[0-9]+G$ ]]; then
                dnum=${disk::-1}
                disk_m=$((dnum * 1024))
                qm resize $vm_num sata0 ${disk_m}M
            fi
        fi
    else
        qm set $vm_num --virtio0 ${storage}:${disk},cache=none,discard=on
        if [ $? -ne 0 ]; then
            echo "Failed to mount ${storage}:${disk}. Trying alternative disk file..."
            qm set $vm_num --virtio0 ${storage}-lvm:${disk},cache=none,discard=on
            if [ $? -ne 0 ]; then
                echo "Failed to mount ${storage}-lvm:${disk}. Trying fallback file..."
                echo "All attempts to mount SATA disk failed for VM $vm_num. Exiting..."
                exit 1
            fi
        fi
        qm resize $vm_num virtio0 ${disk}G
        if [ $? -ne 0 ]; then
            if [[ $disk =~ ^[0-9]+G$ ]]; then
                dnum=${disk::-1}
                disk_m=$((dnum * 1024))
                qm resize $vm_num virtio0 ${disk_m}M
            fi
        fi
    fi
    qm set $vm_num --ide0 ${storage}:iso/opencore.iso,media=cdrom,cache=unsafe
    qm set $vm_num --ide1 ${storage}:iso/${system}.iso,media=cdrom,cache=unsafe
    if [[ "$system" == "high-sierra" || "$system" == "mojave" ]]; then
        grep -q '^boot:' /etc/pve/qemu-server/${vm_num}.conf &&
            sed -i 's/^boot:.*/boot: order=ide0;ide1;sata0;net0/' /etc/pve/qemu-server/${vm_num}.conf ||
            echo 'boot: order=ide0;ide1;sata0;net0' >>/etc/pve/qemu-server/${vm_num}.conf
    else
        grep -q '^boot:' /etc/pve/qemu-server/${vm_num}.conf &&
            sed -i 's/^boot:.*/boot: order=ide0;ide1;virtio0;net0/' /etc/pve/qemu-server/${vm_num}.conf ||
            echo 'boot: order=ide0;ide1;virtio0;net0' >>/etc/pve/qemu-server/${vm_num}.conf
    fi
    sed -i 's/media=cdrom/media=disk/' /etc/pve/qemu-server/${vm_num}.conf
    qemu_needs_fix=0
    if qemu-system-x86_64 --version | grep -e "6.1" -e "6.2" -e "7.1" -e "7.2" -e "8.0" -e "8.1" -e "9.0.2" -e "9.2.0" >/dev/null; then
        qemu_needs_fix=1
    fi
    if [ "$cpu_vendor" = "amd" ]; then
        if [ $qemu_needs_fix -eq 1 ]; then
            sed -i 's/+bmi2,+xsave,+xsaveopt,check/+bmi2,+xsave,+xsaveopt,check -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off/g' /etc/pve/qemu-server/${vm_num}.conf
        fi
    else # Intel or other CPU
        if [ $qemu_needs_fix -eq 1 ]; then
            sed -i 's/+kvm_pv_eoi,+hypervisor,+invtsc/+kvm_pv_eoi,+hypervisor,+invtsc -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off/g' /etc/pve/qemu-server/${vm_num}.conf
        fi
    fi
    return 0
}

configure_network() {
    user_ip="172.16.1.${vm_num}"
    if [ "$independent_ipv6" == "y" ]; then
        if [ ! -z "$host_ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
            if grep -q "vmbr2" /etc/network/interfaces; then
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
    return 0
}

setup_port_forwarding() {
    user_ip="172.16.1.${vm_num}"
    iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport ${sshn} -j DNAT --to-destination ${user_ip}:22
    iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport ${vnc_port} -j DNAT --to-destination ${user_ip}:5900
    if [ ! -f "/etc/iptables/rules.v4" ]; then
        touch /etc/iptables/rules.v4
    fi
    iptables-save | awk '{if($1=="COMMIT"){delete x}}$1=="-A"?!x[$0]++:1' | iptables-restore
    iptables-save >/etc/iptables/rules.v4
    service netfilter-persistent restart
}

save_vm_info() {
    if [ "$independent_ipv6_status" == "Y" ]; then
        echo "$vm_num $core $memory $disk $sshn $vnc_port $system $storage ${ipv6_address_without_last_segment}${vm_num}" >>"vm${vm_num}"
        data=$(echo " VMID CPU核数-CPU 内存-memory 硬盘-disk SSH端口 VNC端口 系统-system 存储盘-storage 独立IPV6地址-ipv6_address")
    else
        echo "$vm_num $core $memory $disk $sshn $vnc_port $system $storage" >>"vm${vm_num}"
        data=$(echo " VMID CPU核数-CPU 内存-memory 硬盘-disk SSH端口 VNC端口 系统-system 存储盘-storage")
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
    init_params "$@"
    validate_vm_num || exit 1
    get_system_arch || exit 1
    check_cpu_vendor
    check_kvm_support_for_macos
    check_iso_exists || exit 1
    check_ipv6_config || exit 1
    create_vm || exit 1
    configure_network
    setup_port_forwarding
    save_vm_info
    _green "macOS虚拟机创建完成！"
    _green "VM ID: $vm_num"
    _green "SSH端口: $sshn, VNC端口: $vnc_port"
    _green "CPU厂商: $cpu_vendor, 使用OpenCore引导和${system}系统镜像"
}

main "$@"
rm -rf default_vm_config.sh
