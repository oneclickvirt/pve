#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.09

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
        exit 1
    fi
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
            exit 1
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

prepare_system_image() {
    if [ "$system_arch" = "x86" ]; then
        find_and_download_system_image_x86
    elif [ "$system_arch" = "arm" ]; then
        find_and_download_system_image_arm
    else
        echo "Unknown architecture: $system_arch"
    fi
}

find_and_download_system_image_arm() {
    system_name=""
    system_names=()
    usable_system=false
    response=$(curl -slk -m 6 "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxc_arm_images/main/fixed_images.txt")
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        system_names+=($(echo "$response"))
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
    elif [ -z $num_system ]; then
        for ((i = 0; i < ${#system_names[@]}; i++)); do
            if [[ "${system_names[$i]}" == "${en_system}_"* ]]; then
                system_name="${system_names[$i]}"
                break
            fi
        done
    else
        version="$num_system"
        system_name="${en_system}_${version}"
    fi
    if [ ${#system_names[@]} -eq 0 ] && [ -z "$system_name" ]; then
        _red "No suitable system names found."
        exit 1
    else
        for sy in "${system_names[@]}"; do
            if [[ $sy == "${system_name}"* ]]; then
                usable_system=true
                system_name="$sy"
            fi
        done
    fi
    if [ "$usable_system" = false ]; then
        _red "Invalid system version."
        exit 1
    fi
    if [ -n "${system_name}" ]; then
        if [ ! -f "/var/lib/vz/template/cache/${system_name}" ]; then
            curl -o "/var/lib/vz/template/cache/${system_name}" "${cdn_success_url}https://github.com/oneclickvirt/lxc_arm_images/releases/download/${en_system}/${system_name}"
        else
            echo "File already exists: /var/lib/vz/template/cache/${system_name}"
        fi
        fixed_system=true
    fi
}

find_and_download_system_image_x86() {
    fixed_system=false
    system="${en_system}-${num_system}"
    system_name=""
    system_names=()
    response=$(curl -slk -m 6 "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxc_amd64_images/main/fixed_images.txt")
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        system_names+=($(echo "$response"))
    fi
    for image_name in "${system_names[@]}"; do
        if [ -z "${num_system}" ]; then
            if [[ "$image_name" == "${en_system}"* ]]; then
                fixed_system=true
                image_download_url="https://github.com/oneclickvirt/lxc_amd64_images/releases/download/${en_system}/${image_name}"
                if [ ! -f "/var/lib/vz/template/cache/${image_name}" ]; then
                    curl -o "/var/lib/vz/template/cache/${image_name}" "${cdn_success_url}${image_download_url}"
                    if [ $? -ne 0 ]; then
                        _red "Failed to download ${system_name}"
                        fixed_system=false
                        rm -rf "/var/lib/vz/template/cache/${system_name}"
                    fi
                fi
                echo "A matching image exists and will be created using ${image_name}"
                echo "匹配的镜像存在，将使用 ${image_name} 进行创建"
                system_name="$image_name"
                break
            fi
        else
            if [[ "$image_name" == "${en_system}_${num_system}"* ]]; then
                fixed_system=true
                image_download_url="https://github.com/oneclickvirt/lxc_amd64_images/releases/download/${en_system}/${image_name}"
                if [ ! -f "/var/lib/vz/template/cache/${image_name}" ]; then
                    curl -o "/var/lib/vz/template/cache/${image_name}" "${cdn_success_url}${image_download_url}"
                    if [ $? -ne 0 ]; then
                        _red "Failed to download ${system_name}"
                        fixed_system=false
                        rm -rf "/var/lib/vz/template/cache/${system_name}"
                    fi
                fi
                echo "A matching image exists and will be created using ${image_name}"
                echo "匹配的镜像存在，将使用 ${image_name} 进行创建"
                system_name="$image_name"
                break
            fi
        fi
    done
    if [ "$fixed_system" = false ] && [ -z "$system_name" ]; then
        system_name=""
        system_names=()
        response=$(curl -slk -m 6 "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve_lxc_images/main/fixed_images.txt")
        if [ $? -eq 0 ] && [ -n "$response" ]; then
            system_names+=($(echo "$response"))
        fi
        pve_version=$(pveversion)
        if [[ $pve_version == pve-manager/5* ]]; then
            _blue "Detected that PVE version is too low to use zst format images"
        else
            if [ ${#system_names[@]} -eq 0 ]; then
                echo "No suitable system names found."
            elif [ -z $num_system ]; then
                for ((i = 0; i < ${#system_names[@]}; i++)); do
                    if [[ "${system_names[$i]}" == "${en_system}-"* ]]; then
                        system_name="${system_names[$i]}"
                        fixed_system=true
                        if [ ! -f "/var/lib/vz/template/cache/${system_name}" ]; then
                            curl -o "/var/lib/vz/template/cache/${system_name}" "${cdn_success_url}https://github.com/oneclickvirt/pve_lxc_images/releases/download/${en_system}/${system_name}"
                            if [ $? -ne 0 ]; then
                                _red "Failed to download ${system_name}"
                                fixed_system=false
                                rm -rf "/var/lib/vz/template/cache/${system_name}"
                            fi
                        fi
                        _blue "Use self-fixed image: ${system_name}"
                        break
                    fi
                done
            else
                for sy in "${system_names[@]}"; do
                    if [[ $sy == "${system}"* ]]; then
                        system_name="$sy"
                        fixed_system=true
                        if [ ! -f "/var/lib/vz/template/cache/${system_name}" ]; then
                            curl -o "/var/lib/vz/template/cache/${system_name}" "${cdn_success_url}https://github.com/oneclickvirt/pve_lxc_images/releases/download/${en_system}/${system_name}"
                            if [ $? -ne 0 ]; then
                                _red "Failed to download ${system_name}"
                                fixed_system=false
                                rm -rf "/var/lib/vz/template/cache/${system_name}"
                            fi
                        fi
                        _blue "Use self-fixed image: ${system_name}"
                        break
                    fi
                done
            fi
        fi
    fi
    if [ "$fixed_system" = false ] && [ -z "$system_name" ]; then
        if [ -z $num_system ]; then
            system_name=$(pveam available --section system | grep "$en_system" | awk '{print $2}' | head -n1)
            if ! pveam available --section system | grep "$en_system" >/dev/null; then
                _red "No such system"
                exit 1
            else
                _green "Use $system_name"
            fi
            if [ ! -f "/var/lib/vz/template/cache/${system_name}" ]; then
                pveam download local $system_name
            fi
        else
            system_name=$(pveam available --section system | grep "$system" | awk '{print $2}' | head -n1)
            if ! pveam available --section system | grep "$system" >/dev/null; then
                _red "No such system"
                exit 1
            else
                _green "Use $system_name"
            fi
            if [ ! -f "/var/lib/vz/template/cache/${system_name}" ]; then
                pveam download local $system_name
            fi
        fi
    fi
}