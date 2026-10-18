#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.08.26
# ./buildct_onlyv6.sh CTID 密码 CPU核数 内存 硬盘 系统 存储盘
# ./buildct_onlyv6.sh 102 1234567 1 512 5 debian11 local

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

init() {
    CTID="${1:-102}"
    password="${2:-$(generate_password)}"
    core="${3:-1}"
    memory="${4:-512}"
    disk="${5:-5}"
    system_ori="${6:-debian11}"
    storage="${7:-local}"
    validate_storage_name "$storage"
    pve_validate_guest_metadata ct "$CTID" || return 1
    en_system=$(echo "$system_ori" | sed 's/[0-9]*//g; s/\.$//')
    num_system=$(echo "$system_ori" | sed 's/[a-zA-Z]*//g')
    system="$en_system-$num_system"
}

check_requirements() {
    appended_file="${PVE_IPV6_MAPPING_FILE:-/usr/local/bin/pve_appended_content.txt}"
    if [ -s "$appended_file" ]; then
        _green "Additional IPv6 addresses exist for mapping by NAT, and the host can open services with separate IPV6 addresses."
        _green "存在额外的IPv6地址可供映射，宿主机可开设带独立IPV6地址的服务。"
    elif [ "${pve_direct_ipv6_available:-false}" = true ]; then
        if pve_direct_ipv6_ndp_required && [ "$(systemctl is-active ndpresponder.service 2>/dev/null || true)" != active ]; then
            _red "ndpresponder is required for this IPv6 prefix but is not active"
            _red "当前 IPv6 前缀需要 ndpresponder，但服务未运行"
            exit 1
        fi
    elif pve_nat66_ready; then
        _yellow 'Using IPv6 NAT66 with a shared public egress address'
        _yellow '使用 IPv6 NAT66，共享宿主机公网出口'
    else
        _red "No delegated public IPv6 prefix is available for an IPv6-only container"
        _red "未检测到可用于纯 IPv6 容器的已委派公网前缀"
        exit 1
    fi
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
    if [ -n "${PVE_DEFAULT_CT_CONFIG_FILE:-}" ]; then
        [ -r "$PVE_DEFAULT_CT_CONFIG_FILE" ] || return 1
        . "$PVE_DEFAULT_CT_CONFIG_FILE"
        return $?
    fi
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

get_ipv6_info() {
    if [ -f /usr/local/bin/pve_check_ipv6 ]; then
        host_ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
    fi
    if [ -f /usr/local/bin/pve_ipv6_prefixlen ]; then
        ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
    fi
    if [ -f /usr/local/bin/pve_ipv6_gateway ]; then
        ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
    fi
}

setup_mirrors_for_cn() {
    pct exec "$CTID" -- rm -f ChangeMirrors.sh || return 1
    pct exec "$CTID" -- curl -fsSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh || return 1
    pct exec "$CTID" -- test -s ChangeMirrors.sh || return 1
    pct exec "$CTID" -- chmod 755 ChangeMirrors.sh || return 1
    pct exec "$CTID" -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips >/dev/null || return 1
    pct exec "$CTID" -- rm -f ChangeMirrors.sh || return 1
}

setup_container_os() {
    if [ "$fixed_system" = true ]; then
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            sleep 1
        else
            setup_mirrors_for_cn || return 1
        fi
        sleep 2
        public_network_check_res=$(pct exec $CTID -- curl -lk -m 6 ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test 2>/dev/null || true)
        if [[ $public_network_check_res == *"success"* ]]; then
            echo "network is public"
            echo "网络连通正常"
        else
            echo "nameserver 8.8.8.8" | pct exec $CTID -- tee -a /etc/resolv.conf
            sleep 1
            pct exec $CTID -- curl -lk -m 6 ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test || return 1
        fi
        sleep 2
        ssh_check_res=$(pct exec $CTID -- lsof -i:22)
        if [[ $ssh_check_res == *"ssh"* ]]; then
            echo "ssh config correct"
            echo "SSH 配置正常"
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
                setup_mirrors_for_cn || return 1
                pct exec $CTID -- yum install -y dos2unix
            fi
        elif echo "$system" | grep -qiE "fedora" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                pct exec $CTID -- dnf update -y
                pct exec $CTID -- dnf install -y dos2unix curl
            else
                pct exec $CTID -- dnf install -y curl
                setup_mirrors_for_cn || return 1
                pct exec $CTID -- dnf install -y dos2unix
            fi
        elif echo "$system" | grep -qiE "opensuse" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                pct exec $CTID -- zypper update -y
                pct exec $CTID -- zypper --non-interactive install dos2unix curl
            else
                pct exec $CTID -- zypper --non-interactive install curl
                setup_mirrors_for_cn || return 1
                pct exec $CTID -- zypper --non-interactive install dos2unix
            fi
        elif echo "$system" | grep -qiE "alpine|archlinux" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                sleep 1
            else
                setup_mirrors_for_cn || return 1
            fi
        elif echo "$system" | grep -qiE "ubuntu|debian|devuan" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                pct exec $CTID -- apt-get update -y
                pct exec $CTID -- dpkg --configure -a
                pct exec $CTID -- apt-get update
                pct exec $CTID -- apt-get install dos2unix curl -y
            else
                pct exec $CTID -- apt-get install curl -y --fix-missing
                setup_mirrors_for_cn || return 1
                pct exec $CTID -- apt-get install dos2unix -y
            fi
        fi
        if echo "$system" | grep -qiE "alpine|archlinux|gentoo|openwrt" >/dev/null 2>&1; then
            pct exec "$CTID" -- rm -f ssh_sh.sh || return 1
            pct exec "$CTID" -- curl -fsSL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/ssh_sh.sh" -o ssh_sh.sh || return 1
            pct exec "$CTID" -- test -s ssh_sh.sh || return 1
            pct exec "$CTID" -- chmod 755 ssh_sh.sh || return 1
            pct exec "$CTID" -- dos2unix ssh_sh.sh || return 1
            pct exec "$CTID" -- bash ssh_sh.sh || return 1
        else
            pct exec "$CTID" -- rm -f ssh_bash.sh || return 1
            pct exec "$CTID" -- curl -fsSL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/ssh_bash.sh" -o ssh_bash.sh || return 1
            pct exec "$CTID" -- test -s ssh_bash.sh || return 1
            pct exec "$CTID" -- chmod 755 ssh_bash.sh || return 1
            pct exec "$CTID" -- dos2unix ssh_bash.sh || return 1
            pct exec "$CTID" -- bash ssh_bash.sh || return 1
        fi
    fi
}

ensure_guest_ipv6_network() {
    # Debian cloud templates often enable systemd-networkd without shipping a
    # matching unit.  Persist the PVE-provided IPv6 address and gateway so a
    # first boot, stop/start, guest reboot, and host reboot all converge.
    pct exec "$CTID" -- sh -c 'ip link set dev eth0 up; if command -v ifup >/dev/null 2>&1; then ifup eth0 >/dev/null 2>&1 || true; fi' || return 1
    if pct exec "$CTID" -- sh -c 'command -v systemctl >/dev/null 2>&1 && systemctl is-enabled systemd-networkd >/dev/null 2>&1'; then
        pct exec "$CTID" -- sh -c 'mkdir -p /etc/systemd/network; cat > /etc/systemd/network/10-oneclickvirt-ipv6.network' <<EOF
[Match]
Name=eth0

[Network]
Address=${ct_external_ipv6}/${pve_direct_ipv6_prefix##*/}
Gateway=${pve_direct_ipv6_gateway}
DNS=2606:4700:4700::1111
DNS=2001:4860:4860::8888
IPv6AcceptRA=no
EOF
        if [ "${independent_ipv6_status:-}" = NAT66 ]; then
            pct exec "$CTID" -- sh -c "sed -i 's#Address=.*#Address=${ct_external_ipv6}/64#; s#Gateway=.*#Gateway=${pve_nat_ipv6_gateway}#' /etc/systemd/network/10-oneclickvirt-ipv6.network"
        fi
        pct exec "$CTID" -- systemctl restart systemd-networkd || return 1
        pct exec "$CTID" -- networkctl reconfigure eth0 >/dev/null 2>&1 || true
    fi
    pct exec "$CTID" -- ip -6 addr show dev eth0 | grep -q 'inet6 ' || return 1
    pct exec "$CTID" -- ip -6 route show default | grep -q . || return 1
}

create_container() {
    pve_prepare_ct_template || return 1
    local ct_conf="${PVE_CT_CONFIG_DIR:-/etc/pve/lxc}/${CTID}.conf"
    local retry=0
    local max_retry=7
    local wait_interval=3
    user_ip="${pve_nat_prefix}.${CTID}"
    # lxc-usernsexec needs traversable mountpoints even when the caller uses umask 077.
    # Keep the caller mask and private credential records unchanged.
    if [ "$fixed_system" = true ]; then
        (umask 022; pct create "$CTID" "/var/lib/vz/template/cache/${system_name}" -cores "$core" -cpuunits 1024 -memory "$memory" -swap 128 -rootfs "${storage}:${disk}" -onboot 1 --password="$password" -features nesting=1)
    else
        (umask 022; pct create "$CTID" "${storage}:vztmpl/${system_name}" -cores "$core" -cpuunits 1024 -memory "$memory" -swap 128 -rootfs "${storage}:${disk}" -onboot 1 --password="$password" -features nesting=1)
    fi
    if [ $? -ne 0 ]; then
        echo -e "\e[31mpct create failed for CT ${CTID}, container will not be started\e[0m"
        echo -e "\e[31mCT ${CTID} 创建失败，已停止后续启动流程\e[0m"
        exit 1
    fi
    while [ $retry -lt $max_retry ]; do
        if [ -f "$ct_conf" ]; then
            break
        fi
        sleep $wait_interval
        retry=$((retry + 1))
    done
    if [ ! -f "$ct_conf" ]; then
        echo -e "\e[31mLXC config not found after create: $ct_conf\e[0m"
        echo -e "\e[31m创建后未检测到 LXC 配置文件：$ct_conf\e[0m"
        echo -e "\e[31mPlease check pve-cluster status and /etc/pve mount state\e[0m"
        echo -e "\e[31m请检查 pve-cluster 状态和 /etc/pve 挂载状态\e[0m"
        exit 1
    fi
    pct set "$CTID" --hostname "$CTID" || return 1
    appended_file="${PVE_IPV6_MAPPING_FILE:-/usr/local/bin/pve_appended_content.txt}"
    if [ -s "$appended_file" ]; then
        # 使用 vmbr1 网桥和 NAT 映射
        ct_internal_ipv6="$(pve_nat_ipv6_for_id "$CTID")" || return 1
        pct set $CTID --net0 name=eth0,ip=manual,ip6="${ct_internal_ipv6}/64",bridge=vmbr1,gw6="${pve_nat_ipv6_gateway}" || return 1
        pct set "$CTID" --nameserver "2606:4700:4700::1111 2001:4860:4860::8888" || return 1
        # 获取可用的外部 IPv6 地址
        host_external_ipv6=$(get_available_vmbr1_ipv6)
        if [ -z "$host_external_ipv6" ]; then
            echo -e "\e[31mNo available IPv6 address found for NAT mapping\e[0m"
            echo -e "\e[31m没有可用的IPv6地址用于NAT映射\e[0m"
            exit 1
        fi
        # 设置 NAT 映射
        setup_nat_mapping "$ct_internal_ipv6" "$host_external_ipv6" || return 1
        ct_external_ipv6="$host_external_ipv6"
        echo "Container configured with NAT mapping: $ct_internal_ipv6 -> $host_external_ipv6"
        echo "容器已配置NAT映射：$ct_internal_ipv6 -> $host_external_ipv6"
    elif [ "${pve_direct_ipv6_available:-false}" = true ]; then
        # 使用已确认的直连网桥直接分配 IPv6 地址
        ct_external_ipv6="$(pve_direct_ipv6_for_id "$CTID")" || exit 1
        direct_ipv6_bridge="$(pve_direct_ipv6_bridge)" || exit 1
        pct set $CTID --net0 name=eth0,ip=manual,ip6="${ct_external_ipv6}/${pve_direct_ipv6_prefix##*/}",bridge="${direct_ipv6_bridge}",gw6="${pve_direct_ipv6_gateway}" || return 1
        pct set "$CTID" --nameserver "2606:4700:4700::1111 2001:4860:4860::8888" || return 1
        echo "Container configured with ${direct_ipv6_bridge}: ${ct_external_ipv6}"
        echo "容器已配置使用 ${direct_ipv6_bridge}：${ct_external_ipv6}"
        _fw6_drop_icmpv6_ping "${ct_external_ipv6}" "${pve_direct_ipv6_prefix}"
        _fw_save
    else
        pve_nat66_ready || return 1
        ct_external_ipv6="$(pve_nat_ipv6_for_id "$CTID")" || return 1
        pct set "$CTID" --net0 "name=eth0,ip=manual,ip6=${ct_external_ipv6}/64,bridge=vmbr1,gw6=${pve_nat_ipv6_gateway}" || return 1
        pct set "$CTID" --nameserver '2606:4700:4700::1111 2001:4860:4860::8888' || return 1
        independent_ipv6_status=NAT66
    fi
    pct start "$CTID" || return 1
    ensure_guest_ipv6_network || return 1
    pve_configure_ct_dns 6 || return 1
    sleep 3
}

save_container_info() {
    local ipv6_label=外网IPV6-ipv6
    [ "${independent_ipv6_status:-}" != NAT66 ] || ipv6_label=共享NAT66地址-ipv6
    pve_save_guest_record ct "$CTID" "$CTID $password $core $memory $disk $system_ori $storage ${ct_external_ipv6}" \
        "CTID root密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage $ipv6_label"
}

finalize_container() {
    pct exec "$CTID" -- rm -f /etc/network/.pve-ignore.interfaces || return 1
    pct exec "$CTID" -- touch /etc/.pve-ignore.resolv.conf || return 1
    pct exec "$CTID" -- touch /etc/.pve-ignore.hosts || return 1
    pct exec "$CTID" -- touch /etc/.pve-ignore.hostname || return 1
}

main() {
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    load_default_config
    load_nat_ipv4_config || exit 1
    pve_load_direct_ipv6_config || exit 1
    set_locale
    check_requirements
    get_system_arch || exit 1
    check_china
    init "$@" || exit 1
    validate_ctid || exit 1
    get_ipv6_info
    prepare_system_image || exit 1
    create_container || exit 1
    setup_container_os || exit 1
    pve_configure_ct_dns 6 || exit 1
    finalize_container || exit 1
    save_container_info || exit 1
}

main "$@"
