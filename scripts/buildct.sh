#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.06.09

# ./buildct.sh CTID 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘 独立IPV6
# ./buildct.sh 102 1234567 1 512 5 20001 20002 20003 30000 30025 debian11 local N

cd /root >/dev/null 2>&1

init() {
    CTID="${1:-102}"
    password="${2:-123456}"
    core="${3:-1}"
    memory="${4:-512}"
    disk="${5:-5}"
    sshn="${6:-20001}"
    web1_port="${7:-20002}"
    web2_port="${8:-20003}"
    port_first="${9:-29975}"
    port_last="${10:-30000}"
    system_ori="${11:-debian11}"
    storage="${12:-local}"
    independent_ipv6="${13:-N}"
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
    rm -rf "ct$name"
    en_system=$(echo "$system_ori" | sed 's/[0-9]*//g; s/\.$//')
    num_system=$(echo "$system_ori" | sed 's/[a-zA-Z]*//g')
    system="$en_system-$num_system"
}

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
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
    local config_url="${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/default_ct_config.sh"
    local config_file="default_ct_config.sh"
    if download_with_retry "$config_url" "$config_file"; then
        . "./$config_file"
    else
        echo -e "\e[31mUnable to load default configuration, script terminated.\e[0m"
        echo -e "\e[31m无法加载默认配置，脚本终止。\e[0m"
        exit 1
    fi
}

create_container() {
    user_ip="172.16.1.${CTID}"
    if [ "$fixed_system" = true ]; then
        pct create $CTID /var/lib/vz/template/cache/${system_name} -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
    else
        pct create $CTID ${storage}:vztmpl/${system_name} -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
    fi
    pct start $CTID
    sleep 5
    pct set $CTID --hostname $CTID
}

configure_networking() {
    independent_ipv6_status="N"
    if [ "$independent_ipv6" == "y" ]; then
        if [ ! -z "$host_ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
            appended_file="/usr/local/bin/pve_appended_content.txt"
            if [ -s "$appended_file" ]; then
                # 使用 vmbr1 网桥和 NAT 映射
                ct_internal_ipv6="2001:db8:1::${CTID}"
                pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1
                pct set $CTID --net1 name=eth1,ip6="${ct_internal_ipv6}/64",bridge=vmbr1,gw6="2001:db8:1::1"
                pct set $CTID --nameserver 1.1.1.1
                pct set $CTID --searchdomain local
                # 获取可用的外部 IPv6 地址
                host_external_ipv6=$(get_available_vmbr1_ipv6)
                if [ -z "$host_external_ipv6" ]; then
                    echo -e "\e[31mNo available IPv6 address found for NAT mapping\e[0m"
                    echo -e "\e[31m没有可用的IPv6地址用于NAT映射\e[0m"
                    independent_ipv6_status="N"
                else
                    # 设置 NAT 映射
                    setup_nat_mapping "$ct_internal_ipv6" "$host_external_ipv6"
                    ct_external_ipv6="$host_external_ipv6"
                    echo "Container configured with NAT mapping: $ct_internal_ipv6 -> $host_external_ipv6"
                    echo "容器已配置NAT映射：$ct_internal_ipv6 -> $host_external_ipv6"
                    independent_ipv6_status="Y"
                fi
            elif grep -q "vmbr2" /etc/network/interfaces; then
                # 使用 vmbr2 网桥直接分配IPv6地址
                pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1
                pct set $CTID --net1 name=eth1,ip6="${ipv6_address_without_last_segment}${CTID}/128",bridge=vmbr2,gw6="${host_ipv6_address}"
                pct set $CTID --nameserver 1.1.1.1
                pct set $CTID --searchdomain local
                ct_external_ipv6="${ipv6_address_without_last_segment}${CTID}"
                independent_ipv6_status="Y"
            fi
        fi
    fi
    if [ "$independent_ipv6_status" == "N" ]; then
        pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1
        pct set $CTID --nameserver 1.1.1.1
        pct set $CTID --searchdomain local
    fi
    sleep 3
}

change_mirrors() {
    pct exec $CTID -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
    pct exec $CTID -- chmod 777 ChangeMirrors.sh
    pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null
    pct exec $CTID -- rm -rf ChangeMirrors.sh
}

install_packages() {
    local pkg_manager=$1
    local packages=$2
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        pct exec $CTID -- $pkg_manager update -y
        pct exec $CTID -- $pkg_manager install -y $packages
    else
        if [[ "$packages" == *"curl"* ]]; then
            pct exec $CTID -- $pkg_manager install -y curl
        fi
        change_mirrors
        pct exec $CTID -- $pkg_manager install -y $packages
    fi
}

setup_ssh() {
    local system_type=$1
    if echo "$system_type" | grep -qiE "alpine|archlinux|gentoo|openwrt" >/dev/null 2>&1; then
        pct exec $CTID -- curl -L ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/ssh_sh.sh -o ssh_sh.sh
        pct exec $CTID -- chmod 777 ssh_sh.sh
        pct exec $CTID -- dos2unix ssh_sh.sh
        pct exec $CTID -- bash ssh_sh.sh
    else
        pct exec $CTID -- curl -L ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/ssh_bash.sh -o ssh_bash.sh
        pct exec $CTID -- chmod 777 ssh_bash.sh
        pct exec $CTID -- dos2unix ssh_bash.sh
        pct exec $CTID -- bash ssh_bash.sh
    fi
}

check_network() {
    public_network_check_res=$(pct exec $CTID -- curl -lk -m 6 ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test)
    if [[ $public_network_check_res == *"success"* ]]; then
        echo "network is public"
    else
        echo "nameserver 8.8.8.8" | pct exec $CTID -- tee -a /etc/resolv.conf
        sleep 1
        pct exec $CTID -- curl -lk -m 6 ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test
    fi
}

restart_ssh() {
    ssh_check_res=$(pct exec $CTID -- lsof -i:22)
    if [[ $ssh_check_res == *"ssh"* ]]; then
        echo "ssh config correct"
    else
        pct exec $CTID -- service ssh restart
        pct exec $CTID -- service sshd restart
        sleep 2
        pct exec $CTID -- systemctl restart sshd
        pct exec $CTID -- systemctl restart ssh
    fi
}

configure_os() {
    if [ "$fixed_system" = true ]; then
        if [[ "${CN}" == true ]]; then
            change_mirrors
        fi
        sleep 2
        check_network
        sleep 2
        restart_ssh
    else
        if echo "$system" | grep -qiE "centos|almalinux|rockylinux" >/dev/null 2>&1; then
            install_packages "yum" "dos2unix curl"
        elif echo "$system" | grep -qiE "fedora" >/dev/null 2>&1; then
            install_packages "dnf" "dos2unix curl"
        elif echo "$system" | grep -qiE "opensuse" >/dev/null 2>&1; then
            install_packages "zypper --non-interactive" "dos2unix curl"
        elif echo "$system" | grep -qiE "alpine|archlinux" >/dev/null 2>&1; then
            if [[ "${CN}" == true ]]; then
                pct exec $CTID -- wget https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh
                pct exec $CTID -- chmod 777 ChangeMirrors.sh
                pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null
                pct exec $CTID -- rm -rf ChangeMirrors.sh
            fi
        elif echo "$system" | grep -qiE "ubuntu|debian|devuan" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                pct exec $CTID -- apt-get update -y
                pct exec $CTID -- dpkg --configure -a
                pct exec $CTID -- apt-get update
                pct exec $CTID -- apt-get install dos2unix curl -y
            else
                pct exec $CTID -- apt-get install curl -y --fix-missing
                change_mirrors
                pct exec $CTID -- apt-get install dos2unix -y
            fi
        fi
        setup_ssh "$system"
    fi
}

configure_container_extras() {
    if [ "$independent_ipv6_status" == "Y" ]; then
        pct exec $CTID -- echo '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb' | crontab -
    fi
    pct exec $CTID -- rm -rf /etc/network/.pve-ignore.interfaces
    pct exec $CTID -- touch /etc/.pve-ignore.resolv.conf
    pct exec $CTID -- touch /etc/.pve-ignore.hosts
    pct exec $CTID -- touch /etc/.pve-ignore.hostname
}

setup_port_forwarding() {
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

save_container_info() {
    if [ "$independent_ipv6_status" == "Y" ]; then
        echo "$CTID $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system_ori $storage ${ct_external_ipv6}" >>"ct${CTID}"
        data=$(echo " CTID root密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage 独立IPV6地址-ipv6_address")
    else
        echo "$CTID $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system_ori $storage" >>"ct${CTID}"
        data=$(echo " CTID root密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage")
    fi
    values=$(cat "ct${CTID}")
    IFS=' ' read -ra data_array <<<"$data"
    IFS=' ' read -ra values_array <<<"$values"
    length=${#data_array[@]}
    for ((i = 0; i < $length; i++)); do
        echo "${data_array[$i]} ${values_array[$i]}"
        echo ""
    done >"/tmp/temp${CTID}.txt"
    sed -i 's/^/# /' "/tmp/temp${CTID}.txt"
    cat "/etc/pve/lxc/${CTID}.conf" >>"/tmp/temp${CTID}.txt"
    cp "/tmp/temp${CTID}.txt" "/etc/pve/lxc/${CTID}.conf"
    rm -rf "/tmp/temp${CTID}.txt"
    cat "ct${CTID}"
}

main() {
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    load_default_config
    set_locale
    get_system_arch || exit 1
    check_china
    init "$@"
    validate_ctid || exit 1
    check_ipv6_setup
    prepare_system_image || exit 1
    create_container
    configure_networking
    configure_os
    configure_container_extras
    setup_port_forwarding
    save_container_info
}

main "$@"