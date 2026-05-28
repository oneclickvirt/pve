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
            echo "挂载 ${storage}:${disk} 失败，正在尝试其他磁盘文件..."
            qm set $vm_num --sata0 ${storage}-lvm:${disk},cache=none,ssd=1,discard=on
            if [ $? -ne 0 ]; then
                echo "Failed to mount ${storage}-lvm:${disk}. Trying fallback file..."
                echo "挂载 ${storage}-lvm:${disk} 失败，正在尝试回退文件..."
                echo "All attempts to mount SATA disk failed for VM $vm_num. Exiting..."
                echo "为 VM $vm_num 挂载 SATA 磁盘的所有尝试均失败，脚本退出..."
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
            echo "挂载 ${storage}:${disk} 失败，正在尝试其他磁盘文件..."
            qm set $vm_num --virtio0 ${storage}-lvm:${disk},cache=none,discard=on
            if [ $? -ne 0 ]; then
                echo "Failed to mount ${storage}-lvm:${disk}. Trying fallback file..."
                echo "挂载 ${storage}-lvm:${disk} 失败，正在尝试回退文件..."
                echo "All attempts to mount SATA disk failed for VM $vm_num. Exiting..."
                echo "为 VM $vm_num 挂载磁盘的所有尝试均失败，脚本退出..."
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
    # 使用专属 opencore ISO（含独立SMBIOS）；若生成失败则回退到共享 opencore.iso
    local opencore_iso_name
    opencore_iso_name=$(basename "${MACOS_OPENCORE_ISO:-/var/lib/vz/template/iso/opencore.iso}")
    qm set $vm_num --ide0 ${storage}:iso/${opencore_iso_name},media=cdrom,cache=unsafe
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
    _fw_add_dnat "vmbr0" "tcp" "${sshn}" "${user_ip}:22"
    _fw_add_dnat "vmbr0" "tcp" "${vnc_port}" "${user_ip}:5900"
    _fw_save
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
    # 将生成的SMBIOS信息写入VM配置注释，方便追踪
    if [ -n "$MACOS_SERIAL" ]; then
        printf '# macOS-SMBIOS: Serial=%s MLB=%s UUID=%s\n#\n' \
            "$MACOS_SERIAL" "$MACOS_MLB" "$MACOS_UUID" >>"/tmp/temp${vm_num}.txt"
    fi
    cat "/etc/pve/qemu-server/${vm_num}.conf" >>"/tmp/temp${vm_num}.txt"
    cp "/tmp/temp${vm_num}.txt" "/etc/pve/qemu-server/${vm_num}.conf"
    rm -rf "/tmp/temp${vm_num}.txt"
    cat "vm${vm_num}"
}

# =============================================
# macOS SMBIOS 序列号生成与注入
# 参考: https://github.com/corpnewt/GenSMBIOS
#       https://github.com/luchina-gabriel/OSX-PROXMOX
# =============================================

# 全局变量：由 setup_macos_smbios 填充，失败时保持为空
MACOS_SERIAL=""
MACOS_MLB=""
MACOS_UUID=""
MACOS_OPENCORE_ISO=""

# 生成苹果格式的系统序列号（12位，非元音字符集）
# 格式: 工厂前缀(3) + 年份/周码(2) + 流水线(3) + 型号标识(4)
generate_mac_serial() {
    local charset="BCDFGHJKLMNPQRSTVWXYZ0123456789"
    local len=${#charset}
    local prefixes=("C02" "C07" "C3Q" "C1N" "C17" "D25" "FK1")
    local prefix="${prefixes[$((RANDOM % ${#prefixes[@]}))]}"
    local serial="$prefix"
    local i
    for ((i = 0; i < 9; i++)); do
        serial="${serial}${charset:$((RANDOM % len)):1}"
    done
    echo "$serial"
}

# 生成主板序列号（MLB，17位）
generate_mlb() {
    local charset="BCDFGHJKLMNPQRSTVWXYZ0123456789"
    local len=${#charset}
    local prefixes=("C02" "C07" "C3Q" "C1N" "C17")
    local prefix="${prefixes[$((RANDOM % ${#prefixes[@]}))]}"
    local mlb="$prefix"
    local i
    for ((i = 0; i < 14; i++)); do
        mlb="${mlb}${charset:$((RANDOM % len)):1}"
    done
    echo "$mlb"
}

# 生成系统 UUID（标准格式）
generate_system_uuid() {
    local uuid=""
    if command -v uuidgen >/dev/null 2>&1; then
        uuid=$(uuidgen | tr 'a-f' 'A-F')
    elif [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(tr 'a-z' 'A-Z' </proc/sys/kernel/random/uuid)
    elif command -v python3 >/dev/null 2>&1; then
        uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())" 2>/dev/null)
    fi
    if [ -z "$uuid" ]; then
        uuid="00000000-0000-0000-0000-000000000000"
        _yellow "uuid生成工具不可用，使用占位UUID"
    fi
    echo "$uuid"
}

# 创建一份 per-VM 的 opencore ISO 副本并将生成的 SMBIOS 注入 config.plist
# 参数: vm_id  serial  mlb  uuid
# 成功返回0，失败返回1（调用方回退到原始 opencore.iso）
patch_opencore_iso() {
    local vm_id="$1" serial="$2" mlb="$3" uuid="$4"
    local src_iso="/var/lib/vz/template/iso/opencore.iso"
    local dst_iso="/var/lib/vz/template/iso/opencore_${vm_id}.iso"
    local loop_dev="" mount_point="/tmp/opencore_mnt_${vm_id}"
    local mounted=false ret=0

    # 前置检查
    [ -f "$src_iso" ] || { _yellow "源 opencore.iso 不存在，跳过 SMBIOS 注入"; return 1; }
    command -v python3 >/dev/null 2>&1 || { _yellow "python3 不可用，跳过 SMBIOS 注入"; return 1; }

    _yellow "正在为 VM ${vm_id} 创建专属 opencore ISO..."
    cp "$src_iso" "$dst_iso" 2>/dev/null || { _red "复制 opencore.iso 失败"; return 1; }

    # 清理旧挂载点
    umount "$mount_point" 2>/dev/null || true
    rm -rf "$mount_point"
    mkdir -p "$mount_point"

    # ── 挂载策略1：losetup -P（适用于带分区表的混合磁盘镜像）──
    loop_dev=$(losetup -f 2>/dev/null)
    if [ -n "$loop_dev" ] && losetup -P "$loop_dev" "$dst_iso" 2>/dev/null; then
        sleep 1  # 等待内核扫描分区设备
        local efi_part="${loop_dev}p1"
        if [ -b "$efi_part" ]; then
            if mount -t vfat "$efi_part" "$mount_point" 2>/dev/null ||
                mount "$efi_part" "$mount_point" 2>/dev/null; then
                mounted=true
            fi
        fi
        # 分区挂载失败时，尝试直接挂载整个循环设备（纯 FAT32 镜像）
        if [ "$mounted" = false ]; then
            if mount -t vfat "$loop_dev" "$mount_point" 2>/dev/null ||
                mount "$loop_dev" "$mount_point" 2>/dev/null; then
                mounted=true
            fi
        fi
        if [ "$mounted" = false ]; then
            losetup -d "$loop_dev" 2>/dev/null
            loop_dev=""
        fi
    else
        [ -n "$loop_dev" ] && losetup -d "$loop_dev" 2>/dev/null
        loop_dev=""
    fi

    # ── 挂载策略2：直接 loop 挂载（FAT32 裸镜像或 ISO9660 只读降级）──
    if [ "$mounted" = false ]; then
        if mount -o loop "$dst_iso" "$mount_point" 2>/dev/null; then
            mounted=true
        fi
    fi

    if [ "$mounted" = false ]; then
        _yellow "无法挂载 opencore ISO，跳过 SMBIOS 注入"
        [ -n "$loop_dev" ] && losetup -d "$loop_dev" 2>/dev/null
        rmdir "$mount_point" 2>/dev/null
        rm -f "$dst_iso"
        return 1
    fi

    # 查找 config.plist（通常在 EFI/OC/config.plist）
    local config_plist
    config_plist=$(find "$mount_point" -name "config.plist" 2>/dev/null | head -1)
    if [ -z "$config_plist" ]; then
        _yellow "在 opencore ISO 中未找到 config.plist，跳过 SMBIOS 注入"
        umount "$mount_point" 2>/dev/null
        [ -n "$loop_dev" ] && losetup -d "$loop_dev" 2>/dev/null
        rmdir "$mount_point" 2>/dev/null
        rm -f "$dst_iso"
        return 1
    fi

    _yellow "找到 config.plist: $config_plist"

    # 使用 python3 plistlib 修改 PlatformInfo/Generic 节点
    # 参数通过命令行传递，避免 bash 变量替换带来的注入风险
    python3 - "$config_plist" "$serial" "$mlb" "$uuid" <<'PYEOF'
import sys, plistlib

config_path, serial, mlb, uuid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(config_path, 'rb') as f:
        pl = plistlib.load(f)

    platform_info = pl.get('PlatformInfo', {})
    generic = platform_info.get('Generic', {})

    if not isinstance(generic, dict) or not generic:
        print("SKIP: PlatformInfo/Generic section not found or empty in config.plist")
        sys.exit(1)

    generic['SystemSerialNumber'] = serial
    generic['MLB'] = mlb
    generic['SystemUUID'] = uuid
    platform_info['Generic'] = generic
    pl['PlatformInfo'] = platform_info

    with open(config_path, 'wb') as f:
        plistlib.dump(pl, f, fmt=plistlib.FMT_XML)

    print("SUCCESS: patched SystemSerialNumber=%s MLB=%s UUID=%s" % (serial, mlb, uuid))
except Exception as e:
    print("ERROR: %s" % e, file=sys.stderr)
    sys.exit(1)
PYEOF
    ret=$?

    # 卸载并释放循环设备
    umount "$mount_point" 2>/dev/null || true
    [ -n "$loop_dev" ] && losetup -d "$loop_dev" 2>/dev/null
    rmdir "$mount_point" 2>/dev/null || true

    if [ $ret -ne 0 ]; then
        _yellow "config.plist 修改失败，回退到原始 opencore.iso（固定序列号兜底）"
        rm -f "$dst_iso"
        return 1
    fi

    _green "专属 opencore ISO 已创建：opencore_${vm_id}.iso"
    return 0
}

# 生成 SMBIOS 数据并尝试注入 per-VM opencore ISO
# 成功时：MACOS_SERIAL/MLB/UUID 和 MACOS_OPENCORE_ISO 均被设置
# 失败时：MACOS_OPENCORE_ISO 回退到共享 opencore.iso（保持原有写死序列号逻辑）
setup_macos_smbios() {
    local serial mlb uuid
    serial=$(generate_mac_serial)
    mlb=$(generate_mlb)
    uuid=$(generate_system_uuid)

    _yellow "生成的 macOS SMBIOS 信息："
    _yellow "  序列号 (SystemSerialNumber): $serial"
    _yellow "  主板序列号 (MLB):            $mlb"
    _yellow "  系统 UUID:                   $uuid"

    if patch_opencore_iso "$vm_num" "$serial" "$mlb" "$uuid"; then
        MACOS_SERIAL="$serial"
        MACOS_MLB="$mlb"
        MACOS_UUID="$uuid"
        MACOS_OPENCORE_ISO="/var/lib/vz/template/iso/opencore_${vm_num}.iso"
        _green "SMBIOS 已成功生成并注入专属 opencore ISO"
    else
        _yellow "SMBIOS 注入失败 → 使用共享 opencore.iso（固定序列号兜底，原逻辑不变）"
        MACOS_OPENCORE_ISO="/var/lib/vz/template/iso/opencore.iso"
    fi
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
    setup_macos_smbios
    check_ipv6_config || exit 1
    create_vm || exit 1
    configure_network
    setup_port_forwarding
    save_vm_info
    _green "macOS虚拟机创建完成！"
    _green "VM ID: $vm_num"
    _green "SSH端口: $sshn, VNC端口: $vnc_port"
    _green "CPU厂商: $cpu_vendor, 使用OpenCore引导和${system}系统镜像"
    if [ -n "$MACOS_SERIAL" ]; then
        _green "macOS SMBIOS 序列号: $MACOS_SERIAL | MLB: $MACOS_MLB | UUID: $MACOS_UUID"
    else
        _yellow "macOS SMBIOS: 使用 opencore.iso 内置固定序列号（生成失败兜底）"
    fi
}

main "$@"
rm -rf default_vm_config.sh
