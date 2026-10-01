#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.08.26

# ./buildct.sh CTID 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘 独立IPV6
# ./buildct.sh 102 1234567 1 512 5 20001 20002 20003 30000 30025 debian11 local N

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
    sshn="${6:-20001}"
    web1_port="${7:-20002}"
    web2_port="${8:-20003}"
    port_first="${9:-29975}"
    port_last="${10:-30000}"
    system_ori="${11:-debian11}"
    storage="${12:-local}"
    independent_ipv6="${13:-N}"
    validate_storage_name "$storage"
    if ! [[ "$CTID" =~ ^[0-9]+$ ]] || [[ "$CTID" -lt 100 || "$CTID" -gt 256 ]]; then
        echo "CTID must be in the range 100 ~ 256: ${CTID}" >&2
        return 1
    fi
    local metadata_dir="${PVE_CT_METADATA_DIR:-/root}"
    if [ -e "${metadata_dir}/ct${CTID}" ] || [ -L "${metadata_dir}/ct${CTID}" ]; then
        echo "Refusing to replace existing container metadata: ${metadata_dir}/ct${CTID}" >&2
        return 1
    fi
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
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
        if [ ! -r "$PVE_DEFAULT_CT_CONFIG_FILE" ]; then
            echo "PVE default CT configuration is unreadable: $PVE_DEFAULT_CT_CONFIG_FILE" >&2
            return 1
        fi
        . "$PVE_DEFAULT_CT_CONFIG_FILE"
        return
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

create_container() {
    local ct_conf="/etc/pve/lxc/${CTID}.conf"
    local retry=0
    local max_retry=7
    local wait_interval=3
    user_ip="${pve_nat_prefix}.${CTID}"
    if [ "$fixed_system" = true ]; then
        pct create $CTID /var/lib/vz/template/cache/${system_name} -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
    else
        pct create $CTID ${storage}:vztmpl/${system_name} -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
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
    # Configure the network while the container is stopped.  Applying
    # `pct set --net*` after start asks PVE to hotplug the interface and can
    # fail on images that do not yet have /etc/network/interfaces.  The old
    # order printed that error but continued with a zero exit status, leaving
    # a container whose persisted config and running network differed.
    pct set "$CTID" --hostname "$CTID" || exit 1
}

start_container() {
    pct start "$CTID"
    if [ $? -ne 0 ]; then
        echo -e "\e[31mpct start failed for CT ${CTID}\e[0m"
        echo -e "\e[31mCT ${CTID} 启动失败\e[0m"
        exit 1
    fi
    sleep 5
}

configure_networking() {
    independent_ipv6_status="N"
    if [ "$independent_ipv6" == "y" ]; then
        if [ "${pve_direct_ipv6_available:-false}" = true ] || [ -s /usr/local/bin/pve_appended_content.txt ]; then
            appended_file="/usr/local/bin/pve_appended_content.txt"
            if [ -s "$appended_file" ]; then
                # 使用 vmbr1 网桥和 NAT 映射
                ct_internal_ipv6="$(pve_nat_ipv6_for_id "$CTID")" || return 1
                pct set "$CTID" --net0 "name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=${pve_nat_gateway}" || return 1
                pct set "$CTID" --net1 "name=eth1,ip6=${ct_internal_ipv6}/64,bridge=vmbr1,gw6=${pve_nat_ipv6_gateway}" || return 1
                pct set "$CTID" --nameserver 1.1.1.1 || return 1
                pct set "$CTID" --searchdomain local || return 1
                # 获取可用的外部 IPv6 地址
                host_external_ipv6=$(get_available_vmbr1_ipv6)
                if [ -z "$host_external_ipv6" ]; then
                    echo -e "\e[31mNo available IPv6 address found for NAT mapping\e[0m"
                    echo -e "\e[31m没有可用的IPv6地址用于NAT映射\e[0m"
                    return 1
                else
                    # 设置 NAT 映射
                    setup_nat_mapping "$ct_internal_ipv6" "$host_external_ipv6" || return 1
                    ct_external_ipv6="$host_external_ipv6"
                    echo "Container configured with NAT mapping: $ct_internal_ipv6 -> $host_external_ipv6"
                    echo "容器已配置NAT映射：$ct_internal_ipv6 -> $host_external_ipv6"
                    independent_ipv6_status="Y"
                fi
            elif [ "${pve_direct_ipv6_available:-false}" = true ]; then
                # 使用已确认的委派前缀直接分配 IPv6 地址
                pct set "$CTID" --net0 "name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=${pve_nat_gateway}" || return 1
                if ct_external_ipv6="$(pve_direct_ipv6_for_id "$CTID")"; then
                    direct_ipv6_bridge="$(pve_direct_ipv6_bridge)" || return 1
                    pct set "$CTID" --net1 "name=eth1,ip6=${ct_external_ipv6}/128,bridge=${direct_ipv6_bridge},gw6=${pve_direct_ipv6_gateway}" || return 1
                    pct set "$CTID" --nameserver 1.1.1.1 || return 1
                    pct set "$CTID" --searchdomain local || return 1
                    independent_ipv6_status="Y"
                    _fw6_drop_icmpv6_ping "${ct_external_ipv6}" "${pve_direct_ipv6_prefix}"
                    _fw_save
                else
                    echo "No safe public IPv6 address is available for CT ${CTID}" >&2
                    return 1
                fi
            fi
        else
            # A normal host address (including /128) is not a delegated
            # prefix. Give the guest a private ULA and share the host's
            # public egress through the already checked NAT66 rule.
            ct_internal_ipv6="$(pve_nat_ipv6_for_id "$CTID")" || return 1
            pct set "$CTID" --net0 "name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=${pve_nat_gateway}" || return 1
            pct set "$CTID" --net1 "name=eth1,ip6=${ct_internal_ipv6}/64,bridge=vmbr1,gw6=${pve_nat_ipv6_gateway}" || return 1
            pct set "$CTID" --nameserver '1.1.1.1 2606:4700:4700::1111' || return 1
            independent_ipv6_status="NAT66"
            echo "Container IPv6 NAT66 address: ${ct_internal_ipv6} (shared public egress)"
            echo "容器 IPv6 NAT66 地址：${ct_internal_ipv6}（共享公网出口）"
        fi
    fi
    if [ "$independent_ipv6_status" == "N" ]; then
        pct set "$CTID" --net0 "name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=${pve_nat_gateway}" || return 1
        pct set "$CTID" --nameserver 1.1.1.1 || return 1
        pct set "$CTID" --searchdomain local || return 1
    fi
    sleep 3
}

change_mirrors() {
    pct exec "$CTID" -- rm -f ChangeMirrors.sh || return 1
    pct exec "$CTID" -- curl -fsSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh || return 1
    pct exec "$CTID" -- test -s ChangeMirrors.sh || return 1
    pct exec "$CTID" -- chmod 755 ChangeMirrors.sh || return 1
    pct exec "$CTID" -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips >/dev/null || return 1
    pct exec "$CTID" -- rm -f ChangeMirrors.sh || return 1
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
        change_mirrors || return 1
        pct exec $CTID -- $pkg_manager install -y $packages
    fi
}

setup_ssh() {
    local system_type=$1
    if echo "$system_type" | grep -qiE "alpine|archlinux|gentoo|openwrt" >/dev/null 2>&1; then
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
}

check_network() {
    public_network_check_res=$(pct exec "$CTID" -- curl -lk -m 6 "${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test")
    if [[ $public_network_check_res == *"success"* ]]; then
        echo "network is public"
        echo "网络连通正常"
    else
        echo "nameserver 8.8.8.8" | pct exec "$CTID" -- tee -a /etc/resolv.conf
        sleep 1
        pct exec "$CTID" -- curl -lk -m 6 "${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test" || return 1
    fi
}

ensure_fixed_system_tools() {
    if pct exec "$CTID" -- sh -c 'command -v curl >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1'; then
        return 0
    fi
    if pct exec "$CTID" -- sh -c 'command -v apt-get >/dev/null 2>&1'; then
        pct exec "$CTID" -- env DEBIAN_FRONTEND=noninteractive apt-get update -y || return 1
        pct exec "$CTID" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y curl lsof || return 1
    elif pct exec "$CTID" -- sh -c 'command -v dnf >/dev/null 2>&1'; then
        pct exec "$CTID" -- dnf install -y curl lsof || return 1
    elif pct exec "$CTID" -- sh -c 'command -v yum >/dev/null 2>&1'; then
        pct exec "$CTID" -- yum install -y curl lsof || return 1
    elif pct exec "$CTID" -- sh -c 'command -v apk >/dev/null 2>&1'; then
        pct exec "$CTID" -- apk add --no-cache curl lsof || return 1
    elif pct exec "$CTID" -- sh -c 'command -v zypper >/dev/null 2>&1'; then
        pct exec "$CTID" -- zypper --non-interactive install curl lsof || return 1
    else
        echo "Unable to install required fixed-image probe tools (curl, lsof)" >&2
        echo "无法为固定镜像安装必要的探针工具（curl、lsof）" >&2
        return 1
    fi
    pct exec "$CTID" -- sh -c 'command -v curl >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1'
}

restart_ssh() {
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
}

configure_os() {
    if [ "$fixed_system" = true ]; then
        if [[ "${CN}" == true ]]; then
            change_mirrors || return 1
        fi
        ensure_fixed_system_tools || return 1
        sleep 2
        check_network || return 1
        sleep 2
        restart_ssh
    else
        if echo "$system" | grep -qiE "centos|almalinux|rockylinux" >/dev/null 2>&1; then
            install_packages "yum" "dos2unix curl" || return 1
        elif echo "$system" | grep -qiE "fedora" >/dev/null 2>&1; then
            install_packages "dnf" "dos2unix curl" || return 1
        elif echo "$system" | grep -qiE "opensuse" >/dev/null 2>&1; then
            install_packages "zypper --non-interactive" "dos2unix curl" || return 1
        elif echo "$system" | grep -qiE "alpine|archlinux" >/dev/null 2>&1; then
            if [[ "${CN}" == true ]]; then
                change_mirrors || return 1
            fi
        elif echo "$system" | grep -qiE "ubuntu|debian|devuan" >/dev/null 2>&1; then
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                pct exec $CTID -- apt-get update -y
                pct exec $CTID -- dpkg --configure -a
                pct exec $CTID -- apt-get update
                pct exec $CTID -- apt-get install dos2unix curl -y
            else
                pct exec $CTID -- apt-get install curl -y --fix-missing
                change_mirrors || return 1
                pct exec $CTID -- apt-get install dos2unix -y
            fi
        fi
        setup_ssh "$system" || return 1
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

save_container_info() {
    local metadata_dir="${PVE_CT_METADATA_DIR:-/root}"
    local metadata_file="${metadata_dir}/ct${CTID}"
    local ct_conf="${PVE_CT_CONFIG_DIR:-/etc/pve/lxc}/${CTID}.conf"
    local metadata_tmp comment_tmp metadata_values entry
    local -a comment_entries
    if [ -e "$metadata_file" ] || [ -L "$metadata_file" ]; then
        echo "Refusing to replace existing container metadata: ${metadata_file}" >&2
        return 1
    fi
    if [ "$independent_ipv6_status" == "Y" ]; then
        printf -v metadata_values '%s %s %s %s %s %s %s %s %s %s %s %s %s' \
            "$CTID" "$password" "$core" "$memory" "$disk" "$sshn" "$web1_port" "$web2_port" \
            "$port_first" "$port_last" "$system_ori" "$storage" "${ct_external_ipv6}"
        comment_entries=("CTID ${CTID}" "CPU核数-CPU ${core}" "内存-memory ${memory}" "硬盘-disk ${disk}" \
            "SSH端口 ${sshn}" "80端口 ${web1_port}" "443端口 ${web2_port}" \
            "外网端口起-port-start ${port_first}" "外网端口止-port-end ${port_last}" \
            "系统-system ${system_ori}" "存储盘-storage ${storage}" "独立IPV6地址-ipv6_address ${ct_external_ipv6}")
    elif [ "$independent_ipv6_status" == "NAT66" ]; then
        printf -v metadata_values '%s %s %s %s %s %s %s %s %s %s %s %s %s' \
            "$CTID" "$password" "$core" "$memory" "$disk" "$sshn" "$web1_port" "$web2_port" \
            "$port_first" "$port_last" "$system_ori" "$storage" "${ct_internal_ipv6}"
        comment_entries=("CTID ${CTID}" "CPU核数-CPU ${core}" "内存-memory ${memory}" "硬盘-disk ${disk}" \
            "SSH端口 ${sshn}" "80端口 ${web1_port}" "443端口 ${web2_port}" \
            "外网端口起-port-start ${port_first}" "外网端口止-port-end ${port_last}" \
            "系统-system ${system_ori}" "存储盘-storage ${storage}" "共享NAT66地址-ipv6_address ${ct_internal_ipv6}")
    else
        printf -v metadata_values '%s %s %s %s %s %s %s %s %s %s %s %s' \
            "$CTID" "$password" "$core" "$memory" "$disk" "$sshn" "$web1_port" "$web2_port" \
            "$port_first" "$port_last" "$system_ori" "$storage"
        comment_entries=("CTID ${CTID}" "CPU核数-CPU ${core}" "内存-memory ${memory}" "硬盘-disk ${disk}" \
            "SSH端口 ${sshn}" "80端口 ${web1_port}" "443端口 ${web2_port}" \
            "外网端口起-port-start ${port_first}" "外网端口止-port-end ${port_last}" \
            "系统-system ${system_ori}" "存储盘-storage ${storage}")
    fi
    mkdir -p "$metadata_dir" || return 1
    metadata_tmp=$(mktemp "${metadata_dir}/.ct${CTID}.XXXXXX") || return 1
    if ! printf '%s\n' "$metadata_values" >"$metadata_tmp" || ! chmod 600 "$metadata_tmp"; then
        rm -f -- "$metadata_tmp"
        return 1
    fi
    if ! ln -- "$metadata_tmp" "$metadata_file"; then
        rm -f -- "$metadata_tmp"
        echo "Unable to save container metadata without replacing an existing file: ${metadata_file}" >&2
        return 1
    fi
    rm -f -- "$metadata_tmp"
    if [ -f "$ct_conf" ]; then
        comment_tmp=$(mktemp "${metadata_dir}/.ct${CTID}.comments.XXXXXX") || return 1
        for entry in "${comment_entries[@]}"; do
            printf '# %s\n\n' "$entry"
        done >"$comment_tmp"
        cat "$ct_conf" >>"$comment_tmp" || { rm -f -- "$comment_tmp"; return 1; }
        if ! cp "$comment_tmp" "$ct_conf"; then
            rm -f -- "$comment_tmp"
            return 1
        fi
        rm -f -- "$comment_tmp"
    else
        echo -e "\e[33mSkip writing metadata into missing LXC config: $ct_conf\e[0m"
        echo -e "\e[33m跳过写入不存在的 LXC 配置文件：$ct_conf\e[0m"
    fi
}

main() {
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    load_default_config
    load_nat_ipv4_config || exit 1
    set_locale
    get_system_arch || exit 1
    check_china
    init "$@" || exit 1
    validate_ctid || exit 1
    check_ipv6_setup || exit 1
    prepare_system_image || exit 1
    create_container
    configure_networking || exit 1
    start_container
    configure_os || exit 1
    configure_container_extras
    setup_port_forwarding
    save_container_info
}

main "$@"
