#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.10

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }

set_locale() {
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
    if [[ -z "$utf8_locale" ]]; then
        echo "No UTF-8 locale found"
    else
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        echo "Locale set to $utf8_locale"
    fi
}

get_system_arch() {
    local sysarch="$(uname -m)"
    if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
        local sysarch="$(arch)"
    fi
    case "${sysarch}" in
    "i386" | "i686" | "x86_64")
        system_arch="x86"
        ;;
    "armv7l" | "armv8" | "armv8l" | "aarch64")
        system_arch="arm"
        ;;
    *)
        system_arch=""
        ;;
    esac
    if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
        _red "This script can only run on machines under x86_64 or arm architecture."
        return 1
    fi
    return 0
}

check_china() {
    _yellow "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            _yellow "根据ipapi.co提供的信息，当前IP可能在中国，使用中国镜像下载"
            CN=true
        fi
    fi
}

validate_ctid() {
    # 检查 CTID 是否为数字
    if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
        _red "Error: CTID must be a valid number."
        _red "错误：CTID 必须是有效的数字。"
        return 1
    fi
    # 检查 CTID 是否在范围 100 到 256 之间
    if [[ "$CTID" -lt 100 || "$CTID" -gt 256 ]]; then
        _red "Error: CTID must be in the range 100 ~ 256."
        _red "错误：CTID 需要在 100 到 256 以内。"
        return 1
    fi
    # 检查是否已有相同的 VM
    if qm list | awk '{print $1}' | grep -q "^${CTID}$"; then
        _red "Error: A VM with vmid ${CTID} already exists."
        _red "错误：vmid 为 ${CTID} 的虚拟机已存在。"
        return 1
    fi
    # 检查是否已有相同的 CT
    if pct list | awk '{print $1}' | grep -q "^${CTID}$"; then
        _red "Error: A CT with vmid ${CTID} already exists."
        _red "错误：vmid 为 ${CTID} 的容器已存在。"
        return 1
    fi
    _green "CTID is valid and available: $CTID"
    return 0
}

check_ipv6_setup() {
    if [ "$independent_ipv6" == "y" ]; then
        service_status=$(systemctl is-active ndpresponder.service)
        if [ "$service_status" == "active" ]; then
            _green "The ndpresponder service started successfully and is running, and the host can open a service with a separate IPV6 address."
            _green "ndpresponder服务启动成功且正在运行，宿主机可开设带独立IPV6地址的服务。"
        else
            _green "The status of the ndpresponder service is abnormal and the host may not open a service with a separate IPV6 address."
            _green "ndpresponder服务状态异常，宿主机不可开设带独立IPV6地址的服务。"
            return 1
        fi
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
    else
        if [ -f /usr/local/bin/pve_check_ipv6 ]; then
            ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
            IFS="/" read -ra parts <<<"$ipv6_address"
            part_1="${parts[0]}"
            part_2="${parts[1]}"
            IFS=":" read -ra part_1_parts <<<"$part_1"
            if [ ! -z "${part_1_parts[*]}" ]; then
                part_1_last="${part_1_parts[-1]}"
                if [ "$part_1_last" = "$CTID" ]; then
                    ipv6_address=""
                else
                    part_1_head=$(echo "$part_1" | awk -F':' 'BEGIN {OFS=":"} {last=""; for (i=1; i<NF; i++) {last=last $i ":"}; print last}')
                    ipv6_address="${part_1_head}${CTID}"
                fi
            fi
        fi
        if [ -f /usr/local/bin/pve_ipv6_prefixlen ]; then
            ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
        fi
        if [ -f /usr/local/bin/pve_ipv6_gateway ]; then
            ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
        fi
    fi
}

get_available_vmbr1_ipv6() {
    local appended_file="/usr/local/bin/pve_appended_content.txt"
    local used_ips_file="/usr/local/bin/pve_used_vmbr1_ips.txt"
    if [ ! -f "$used_ips_file" ]; then
        touch "$used_ips_file"
    fi
    local available_ips=()
    if [ -f "$appended_file" ]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^#[[:space:]]*control-alias ]]; then
                read -r next_line
                if [[ "$next_line" =~ ^iface[[:space:]]+.*[[:space:]]+inet6[[:space:]]+static ]]; then
                    read -r addr_line
                    if [[ "$addr_line" =~ ^[[:space:]]*address[[:space:]]+([^/]+) ]]; then
                        available_ips+=("${BASH_REMATCH[1]}")
                    fi
                fi
            fi
        done < "$appended_file"
    fi
    for ip in "${available_ips[@]}"; do
        if ! grep -q "^$ip$" "$used_ips_file"; then
            echo "$ip" >> "$used_ips_file"
            echo "$ip"
            return 0
        fi
    done
    echo ""
    return 1
}

setup_nat_mapping() {
    local ct_internal_ipv6="$1"
    local host_external_ipv6="$2"
    local rules_file="/usr/local/bin/ipv6_nat_rules.sh"
    if [ ! -f "$rules_file" ]; then
        cat > "$rules_file" << 'EOF'
#!/bin/bash
EOF
        chmod +x "$rules_file"
    fi
    ip6tables -t nat -A PREROUTING -d "$host_external_ipv6" -j DNAT --to-destination "$ct_internal_ipv6"
    ip6tables -t nat -A POSTROUTING -s "$ct_internal_ipv6" -j SNAT --to-source "$host_external_ipv6"
    echo "ip6tables -t nat -A PREROUTING -d $host_external_ipv6 -j DNAT --to-destination $ct_internal_ipv6" >> "$rules_file"
    echo "ip6tables -t nat -A POSTROUTING -s $ct_internal_ipv6 -j SNAT --to-source $host_external_ipv6" >> "$rules_file"
    if ! grep -q "@reboot root /usr/local/bin/ipv6_nat_rules.sh" /etc/crontab; then
        echo "@reboot root /usr/local/bin/ipv6_nat_rules.sh" >> /etc/crontab
    fi
    if ! grep -q "post-up /usr/local/bin/ipv6_nat_rules.sh" /etc/network/interfaces; then
        sed -i '/^auto vmbr0$/a post-up /usr/local/bin/ipv6_nat_rules.sh' /etc/network/interfaces
    fi
}

prepare_system_image() {
    if [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
        find_and_download_system_image_x86 || return 1
    elif [ "$system_arch" = "arm" ]; then
        find_and_download_system_image_arm || return 1
    else
        echo "Unknown architecture: $system_arch"
        return 1
    fi
    return 0
}

_download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=5
    local attempt=1
    local wait_time=1
    while ((attempt <= max_attempts)); do
        curl -Lk --connect-timeout 10 --retry 0 -o "$output" "$url"
        if [ $? -eq 0 ]; then
            return 0
        else
            _yellow "Download attempt $attempt failed. Retrying in $wait_time seconds..."
            sleep $wait_time
            wait_time=$((wait_time * 2))
            ((attempt++))
        fi
    done
    return 1
}

_fetch_list_with_retry() {
    local url="$1"
    local attempts=0
    local max_attempts=5
    local delay=1
    fetch_list_response=""
    while ((attempts < max_attempts)); do
        response=$(curl -slk -m 6 "${url}")
        if [[ $? -eq 0 && -n "$response" ]]; then
            fetch_list_response="$response"
            return 0
        fi

        sleep "$delay"
        ((attempts++))
        delay=$((delay * 2))
        [[ $delay -gt 16 ]] && delay=16
    done
    return 1
}

find_and_download_system_image_arm() {
    system_name=""
    system_names=()
    usable_system=false
    # 获取可用列表，带指数退避，结果赋值到 system_names
    if _fetch_list_with_retry "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxc_arm_images/main/fixed_images.txt"; then
        mapfile -t system_names <<<"$fetch_list_response"
    fi
    ubuntu_versions=("18.04" "20.04" "22.04" "23.04" "23.10" "24.04")
    ubuntu_names=("bionic" "focal" "jammy" "lunar" "mantic" "noble")
    debian_versions=("10" "11" "12" "13")
    debian_names=("buster" "bullseye" "bookworm" "trixie")
    version=""
    if [ "$en_system" = "ubuntu" ]; then
        for ((i = 0; i < ${#ubuntu_versions[@]}; i++)); do
            if [ "${ubuntu_versions[$i]}" = "$num_system" ]; then
                version="${ubuntu_names[$i]}"
                system_name="${en_system}_${ubuntu_versions[$i]}_${ubuntu_names[$i]}_arm64_cloud.tar.xz"
                break
            fi
        done
    elif [ "$en_system" = "debian" ]; then
        for ((i = 0; i < ${#debian_versions[@]}; i++)); do
            if [ "${debian_versions[$i]}" = "$num_system" ]; then
                version="${debian_names[$i]}"
                system_name="${en_system}_${debian_versions[$i]}_${debian_names[$i]}_arm64_cloud.tar.xz"
                break
            fi
        done
    elif [ -z "$num_system" ]; then
        matched_systems=()
        for sy in "${system_names[@]}"; do
            if [[ "$sy" == "${en_system}_"* ]]; then
                matched_systems+=("$sy")
            fi
        done
        if [ ${#matched_systems[@]} -gt 0 ]; then
            IFS=$'\n' sorted=($(sort <<<"${matched_systems[*]}"))
            unset IFS
            system_name="${sorted[-1]}"
        fi
    else
        version="$num_system"
        system_name="${en_system}_${version}"
    fi
    # 校验是否在列表中
    if [ ${#system_names[@]} -gt 0 ] && [ -n "$system_name" ]; then
        for sy in "${system_names[@]}"; do
            if [[ "$sy" == "${system_name}"* ]]; then
                usable_system=true
                system_name="$sy"
                break
            fi
        done
    fi
    if [ "$usable_system" = false ]; then
        _red "Invalid system version."
        return 1
    fi
    # 开始下载
    if [ -n "$system_name" ]; then
        target="/var/lib/vz/template/cache/${system_name}"
        if [ ! -f "$target" ]; then
            url="${cdn_success_url}https://github.com/oneclickvirt/lxc_arm_images/releases/download/${en_system}/${system_name}"
            if ! _download_with_retry "$url" "$target"; then
                _red "Failed to download ${system_name}"
                return 1
            fi
        else
            _blue "File already exists: ${target}"
        fi
        fixed_system=true
    fi
    return 0
}

find_and_download_system_image_x86() {
    fixed_system=false
    system="${en_system}-${num_system}"
    system_name=""
    system_names=()
    # 优先从 lxc_amd64_images 列表获取，带指数退避
    if _fetch_list_with_retry "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxc_amd64_images/main/fixed_images.txt"; then
        mapfile -t system_names <<<"$fetch_list_response"
    fi
    for image_name in "${system_names[@]}"; do
        if { [ -z "$num_system" ] && [[ "$image_name" == "${en_system}"* ]]; } ||
            { [ -n "$num_system" ] && [[ "$image_name" == "${en_system}_${num_system}"* ]]; }; then
            fixed_system=true
            system_name="$image_name"
            break
        fi
    done
    if [ "$fixed_system" = true ] && [ -n "$system_name" ]; then
        target="/var/lib/vz/template/cache/${system_name}"
        url="${cdn_success_url}https://github.com/oneclickvirt/lxc_amd64_images/releases/download/${en_system}/${system_name}"
        if [ ! -f "$target" ]; then
            if ! _download_with_retry "$url" "$target"; then
                _red "Failed to download ${system_name}"
                rm -f "$target"
                fixed_system=false
            fi
        fi
        _blue "Use matching image: ${system_name}"
    fi
    # 如果未找到，再从 pve_lxc_images 列表获取，带指数退避
    if [ "$fixed_system" = false ]; then
        system_name=""
        system_names=()
        if _fetch_list_with_retry "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve_lxc_images/main/fixed_images.txt"; then
            mapfile -t system_names <<<"$fetch_list_response"
        fi
        pve_version=$(pveversion)
        allow_zst=true
        [[ $pve_version == pve-manager/5* ]] && allow_zst=false
        for sy in "${system_names[@]}"; do
            if { [ -z "$num_system" ] && [[ "$sy" == "${en_system}-"* ]]; } ||
                { [ -n "$num_system" ] && [[ "$sy" == "${system}"* ]]; }; then
                system_name="$sy"
                fixed_system=true
                target="/var/lib/vz/template/cache/${system_name}"
                url="${cdn_success_url}https://github.com/oneclickvirt/pve_lxc_images/releases/download/${en_system}/${system_name}"
                if [ ! -f "$target" ] && { $allow_zst || [[ "$system_name" != *.zst ]]; }; then
                    if ! _download_with_retry "$url" "$target"; then
                        _red "Failed to download ${system_name}"
                        rm -f "$target"
                        fixed_system=false
                    fi
                fi
                _blue "Use self-fixed image: ${system_name}"
                break
            fi
        done
    fi
    # 回退到 pveam
    if [ "$fixed_system" = false ]; then
        if [ -z "$num_system" ]; then
            system_name=$(pveam available --section system | grep "^${en_system}" | awk '{print $2}' | head -n1)
        else
            system_name=$(pveam available --section system | grep "^${system}" | awk '{print $2}' | head -n1)
        fi
        if [ -z "$system_name" ]; then
            _red "No such system"
            return 1
        fi
        _green "Use ${system_name}"
        target="/var/lib/vz/template/cache/${system_name}"
        if [ ! -f "$target" ]; then
            pveam download local "$system_name"
        fi
        fixed_system=true
    fi
    return 0
}
