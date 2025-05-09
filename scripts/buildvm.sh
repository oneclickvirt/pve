#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.09
# ./buildvm.sh VMID 用户名 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘 独立IPV6
# ./buildvm.sh 102 test1 1234567 1 512 5 40001 40002 40003 50000 50025 debian11 local N

cd /root >/dev/null 2>&1

init_params() {
    vm_num="${1:-102}"
    user="${2:-test}"
    password="${3:-123456}"
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
        echo "No CDN available, using original links"
        export cdn_success_url=""
    fi
}

load_default_config() {
    curl -L "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/default_config.sh" -o default_config.sh
    . ./default_config.sh
}

create_vm() {
    if [ "$independent_ipv6" == "n" ]; then
        qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket \
            --cores $core --sockets 1 --cpu $cpu_type \
            --net0 virtio,bridge=vmbr1,firewall=0 \
            ${kvm_flag}
    else
        qm create $vm_num --agent 1 --scsihw virtio-scsi-single --serial0 socket \
            --cores $core --sockets 1 --cpu $cpu_type \
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
        return 1
    fi
    file_path=$(pvesm path ${volid})
    if [ $? -ne 0 ] || [ -z "$file_path" ]; then
        echo "Error: Failed to resolve path for volume '${volid}'"
        return 1
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
        qm set $vm_num --ipconfig0 ip=${user_ip}/24,gw=172.16.1.1
        qm set $vm_num --nameserver 8.8.8.8
        # qm set $vm_num --nameserver 8.8.4.4
        qm set $vm_num --searchdomain local
    fi
    qm set $vm_num --cipassword $password --ciuser $user
    sleep 5
}

setup_port_forwarding() {
    user_ip="172.16.1.${num}"
    iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport ${sshn} -j DNAT --to-destination ${user_ip}:22
    if [ "${web1_port}" -ne 0 ]; then
        iptables -t nat -A PREROUTING -i vmbr0 -p tcp -m tcp --dport ${web1_port} -j DNAT --to-destination ${user_ip}:80
    fi
    if [ "${web2_port}" -ne 0 ]; then
        iptables -t nat -A PREROUTING -i vmbr0 -p tcp -m tcp --dport ${web2_port} -j DNAT --to-destination ${user_ip}:443
    fi
    if [ "${port_first}" -ne 0 ] && [ "${port_last}" -ne 0 ]; then
        iptables -t nat -A PREROUTING -i vmbr0 -p tcp -m tcp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
        iptables -t nat -A PREROUTING -i vmbr0 -p udp -m udp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
    fi
    if [ ! -f "/etc/iptables/rules.v4" ]; then
        touch /etc/iptables/rules.v4
    fi
    iptables-save | awk '{if($1=="COMMIT"){delete x}}$1=="-A"?!x[$0]++:1' | iptables-restore
    iptables-save >/etc/iptables/rules.v4
    service netfilter-persistent restart
}

save_vm_info() {
    if [ "$independent_ipv6_status" == "Y" ]; then
        echo "$vm_num $user $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system $storage ${ipv6_address_without_last_segment}${vm_num}" >>"vm${vm_num}"
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
rm -rf default_config.sh