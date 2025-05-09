#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.09
# ./buildct_onlyv6.sh CTID 密码 CPU核数 内存 硬盘 系统 存储盘
# ./buildct_onlyv6.sh 102 1234567 1 512 5 debian11 local

cd /root >/dev/null 2>&1

init() {
    CTID="${1:-102}"
    password="${2:-123456}"
    core="${3:-1}"
    memory="${4:-512}"
    disk="${5:-5}"
    system_ori="${6:-debian11}"
    storage="${7:-local}"
    rm -rf "ct$CTID"
    en_system=$(echo "$system_ori" | sed 's/[0-9]*//g; s/\.$//')
    num_system=$(echo "$system_ori" | sed 's/[a-zA-Z]*//g')
    system="$en_system-$num_system"
}

check_requirements() {
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
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
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
    curl -L "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/default_ct_config.sh" -o default_ct_config.sh
    . ./default_ct_config.sh
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

setup_mirrors_for_cn() {
    pct exec $CTID -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
    pct exec $CTID -- chmod 777 ChangeMirrors.sh
    pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
    pct exec $CTID -- rm -rf ChangeMirrors.sh
}

setup_container_os() {
    if [ "$fixed_system" = true ]; then
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            sleep 1
        else
            setup_mirrors_for_cn
        fi
        sleep 2
        public_network_check_res=$(pct exec $CTID -- curl -lk -m 6 ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test)
        if [[ $public_network_check_res == *"success"* ]]; then
            echo "network is public"
        else
            echo "nameserver 8.8.8.8" | pct exec $CTID -- tee -a /etc/resolv.conf
            sleep 1
            pct exec $CTID -- curl -lk -m 6 ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test
        fi
        sleep 2
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
    else
        if echo "$system" | grep -qiE "centos|almalinux|rockylinux" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                pct exec $CTID -- yum update -y
                pct exec $CTID -- yum install -y dos2unix curl
            else
                pct exec $CTID -- yum install -y curl
                setup_mirrors_for_cn
                pct exec $CTID -- yum install -y dos2unix
            fi
        elif echo "$system" | grep -qiE "fedora" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                pct exec $CTID -- dnf update -y
                pct exec $CTID -- dnf install -y dos2unix curl
            else
                pct exec $CTID -- dnf install -y curl
                setup_mirrors_for_cn
                pct exec $CTID -- dnf install -y dos2unix
            fi
        elif echo "$system" | grep -qiE "opensuse" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                pct exec $CTID -- zypper update -y
                pct exec $CTID -- zypper --non-interactive install dos2unix curl
            else
                pct exec $CTID -- zypper --non-interactive install curl
                setup_mirrors_for_cn
                pct exec $CTID -- zypper --non-interactive install dos2unix
            fi
        elif echo "$system" | grep -qiE "alpine|archlinux" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                sleep 1
            else
                pct exec $CTID -- wget https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh
                pct exec $CTID -- chmod 777 ChangeMirrors.sh
                pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
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
                setup_mirrors_for_cn
                pct exec $CTID -- apt-get install dos2unix -y
            fi
        fi
        if echo "$system" | grep -qiE "alpine|archlinux|gentoo|openwrt" >/dev/null 2>&1; then
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
    pct set $CTID --net0 name=eth0,ip6="${ipv6_address_without_last_segment}${CTID}/128",bridge=vmbr2,gw6="${host_ipv6_address}"
    pct set $CTID --net1 name=eth1,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1
    pct set $CTID --nameserver 8.8.8.8,2001:4860:4860::8888 --nameserver 8.8.4.4,2001:4860:4860::8844
    sleep 3
}

save_container_info() {
    echo "$CTID $password $core $memory $disk $system_ori $storage ${ipv6_address_without_last_segment}${CTID}" >>"ct${CTID}"
    data=$(echo " CTID root密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage 外网IPV6-ipv6")
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

finalize_container() {
    pct exec $CTID -- echo '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb' | crontab -
    pct exec $CTID -- rm -rf /etc/network/.pve-ignore.interfaces
    pct exec $CTID -- touch /etc/.pve-ignore.resolv.conf
    pct exec $CTID -- touch /etc/.pve-ignore.hosts
    pct exec $CTID -- touch /etc/.pve-ignore.hostname
}

main() {
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    load_default_config
    set_locale
    check_requirements
    get_system_arch || exit 1
    check_china
    init "$@"
    validate_ctid || exit 1
    get_ipv6_info
    prepare_system_image || exit 1
    create_container
    setup_container_os
    finalize_container
    save_container_info
}

main "$@"
