#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.10

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }

setup_locale() {
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
    if [[ -z "$utf8_locale" ]]; then
        _yellow "No UTF-8 locale found"
    else
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        _green "Locale set to $utf8_locale"
    fi
}

validate_vm_num() {
    # 检测 vm_num 是否为数字
    if ! [[ "$vm_num" =~ ^[0-9]+$ ]]; then
        _red "Error: vm_num must be a valid number."
        _red "错误：vm_num 必须是有效的数字。"
        return 1
    fi
    # 检测 vm_num 是否在范围 100 到 256 之间
    if [[ "$vm_num" -lt 100 || "$vm_num" -gt 256 ]]; then
        _red "Error: vm_num must be in the range 100 ~ 256."
        _red "错误：vm_num 需要在 100 到 256 以内。"
        return 1
    fi
    # 检查是否已有相同的 VM
    if qm list | awk '{print $1}' | grep -q "^${vm_num}$"; then
        _red "Error: A VM with vmid ${vm_num} already exists."
        _red "错误：vmid 为 ${vm_num} 的虚拟机已存在。"
        return 1
    fi
    # 检查是否已有相同的 CT
    if pct list | awk '{print $1}' | grep -q "^${vm_num}$"; then
        _red "Error: A CT with vmid ${vm_num} already exists."
        _red "错误：vmid 为 ${vm_num} 的容器已存在。"
        return 1
    fi
    _green "vm_num is valid and available: $vm_num"
    return 0
}

get_system_arch() {
    local sysarch="$(uname -m)"
    if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
        local sysarch="$(arch)"
    fi
    # 根据架构信息设置系统位数并下载文件,其余 * 包括了 x86_64
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

check_kvm_support() {
    if [ -e /dev/kvm ]; then
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            _green "KVM硬件加速可用，将使用硬件加速。"
            _green "KVM hardware acceleration is available. Using hardware acceleration."
            cpu_type="host"
            kvm_flag="--kvm 1"
            return 0
        fi
    fi
    if grep -E 'vmx|svm' /proc/cpuinfo >/dev/null; then
        _yellow "CPU支持虚拟化，但/dev/kvm不可用，请检查BIOS设置或内核模块。"
        _yellow "CPU supports virtualization, but /dev/kvm is not available. Please check BIOS settings or kernel modules."
    else
        _yellow "CPU不支持硬件虚拟化。"
        _yellow "CPU does not support hardware virtualization."
    fi
    _yellow "将使用QEMU软件模拟(TCG)模式，性能会受到影响。"
    _yellow "Falling back to QEMU software emulation (TCG). Performance will be affected."
    if [[ "$system_arch" == "arm" ]]; then
        cpu_type="max"
    else
        cpu_type="qemu64"
    fi
    kvm_flag="--kvm 0"
    return 1
}

prepare_system_image() {
    if [ "$system_arch" = "x86" ]; then
        prepare_x86_image || return 1
    elif [ "$system_arch" = "arm" ]; then
        prepare_arm_image || return 1
    else
        echo "Unknown architecture: $system_arch"
        return 1
    fi
}

prepare_x86_image() {
    file_path=""
    # 过去手动修补的镜像
    old_images=("debian10" "debian11" "debian12" "ubuntu18" "ubuntu20" "ubuntu22" "centos7" "archlinux" "almalinux8" "fedora33" "fedora34" "opensuse-leap-15" "alpinelinux_edge" "alpinelinux_stable" "rockylinux8" "centos8-stream")
    # 获取新的自动修补的镜像列表
    new_images=($(curl -slk -m 6 https://down.idc.wiki/Image/realServer-Template/current/qcow2/ | grep -o '<a href="[^"]*">' | awk -F'"' '{print $2}' | sed -n '/qcow2$/s#/Image/realServer-Template/current/qcow2/##p'))
    if [[ -n "$new_images" ]]; then
        for ((i = 0; i < ${#new_images[@]}; i++)); do
            new_images[i]=${new_images[i]%.qcow2}
        done
        combined=($(echo "${old_images[@]}" "${new_images[@]}" | tr ' ' '\n' | sort -u))
        systems=("${combined[@]}")
    else
        systems=("${old_images[@]}")
    fi
    # 检查是否支持指定系统
    for sys in ${systems[@]}; do
        if [[ "$system" == "$sys" ]]; then
            file_path="/root/qcow/${system}.qcow2"
            break
        fi
    done
    if [[ -z "$file_path" ]]; then
        _red "Unable to install corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
        _red "无法安装对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
        return 1
    fi
    if [ ! -f "$file_path" ]; then
        download_x86_image
    fi
    return 0
}

download_x86_image() {
    ver=""
    # 尝试使用新镜像
    if [[ -n "$new_images" ]]; then
        matched_images=()
        for image in "${new_images[@]}"; do
            if [[ "$image" == $system* ]]; then
                matched_images+=("$image")
            fi
        done
        if [[ ${#matched_images[@]} -gt 0 ]]; then
            # 优先选择带 cloud 的，并按版本号排序
            sorted_images=$(printf "%s\n" "${matched_images[@]}" | sort -r)
            for img in $sorted_images; do
                if [[ "$img" == *cloud* ]]; then
                    selected_image="$img"
                    break
                fi
            done
            # 如果没有带 cloud 的，就取第一个版本最高的
            if [[ -z "$selected_image" ]]; then
                selected_image=$(echo "$sorted_images" | head -n1)
            fi
            if [[ -n "$selected_image" ]]; then
                ver="auto_build"
                url="${cdn_success_url}https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/${selected_image}.qcow2"
                curl -Lk -o "$file_path" "$url"
                if [ $? -ne 0 ]; then
                    _red "Failed to download $file_path"
                    ver=""
                    rm -rf "$file_path"
                else
                    _blue "Use auto-fixed image: ${selected_image}"
                    return 0
                fi
            fi
        fi
    fi
    # 如果新镜像不可用，使用旧镜像
    if [[ -z "$ver" ]]; then
        v20=("fedora34" "almalinux8" "debian11" "debian12" "ubuntu18" "ubuntu20" "ubuntu22" "centos7" "alpinelinux_edge" "alpinelinux_stable" "rockylinux8")
        v11=("ubuntu18" "ubuntu20" "ubuntu22" "debian10" "debian11")
        v10=("almalinux8" "archlinux" "fedora33" "opensuse-leap-15" "ubuntu18" "ubuntu20" "ubuntu22" "debian10" "debian11")
        ver_list=(v20 v11 v10)
        ver_name_list=("v2.0" "v1.1" "v1.0")
        for ver in "${ver_list[@]}"; do
            array_name="${ver}[@]"
            array=("${!array_name}")
            if [[ " ${array[*]} " == *" $system "* ]]; then
                index=$(echo ${ver_list[*]} | tr -s ' ' '\n' | grep -n "$ver" | cut -d':' -f1)
                ver="${ver_name_list[$((index - 1))]}"
                break
            fi
        done
        if [[ "$system" == "centos8-stream" ]]; then
            url="https://api.ilolicon.com/centos8-stream.qcow2"
            curl -Lk -o "$file_path" "$url"
            if [ $? -ne 0 ]; then
                _red "Unable to download corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                _red "无法下载对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                rm -rf "$file_path"
                return 1
            else
                _blue "Use manual-fixed image: ${system}"
                return 0
            fi
        else
            if [[ -n "$ver" ]]; then
                url="${cdn_success_url}https://github.com/oneclickvirt/kvm_images/releases/download/${ver}/${system}.qcow2"
                curl -Lk -o "$file_path" "$url"
                if [ $? -ne 0 ]; then
                    _red "Unable to download corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                    _red "无法下载对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                    rm -rf "$file_path"
                    return 1
                else
                    _blue "Use manual-fixed image: ${system}"
                    return 0
                fi
            else
                _red "Unable to install corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                _red "无法安装对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                return 1
            fi
        fi
    fi
}

prepare_arm_image() {
    # 非local全局定义参数，后续有使用
    system="$1"
    ext="img"
    url=""
    declare -A ubuntu_map=(
        [ubuntu14]=trusty [ubuntu16]=xenial [ubuntu18]=bionic
        [ubuntu20]=focal [ubuntu22]=jammy
    )
    declare -A debian_map=(
        [10]=buster [11]=bullseye [12]=bookworm [13]=trixie
    )
    if [[ "$system" == "debian" ]]; then
        local latest=$(printf "%s\n" "${!debian_map[@]}" | sort -nr | head -n1)
        system="debian${latest}"
    fi
    if [[ -n "${ubuntu_map[$system]}" ]]; then
        ext="img"
        local codename=${ubuntu_map[$system]}
        url="http://cloud-images.ubuntu.com/${codename}/current/${codename}-server-cloudimg-arm64.img"
    elif [[ "$system" =~ debian([0-9]+) ]]; then
        ext="qcow2"
        local ver=${BASH_REMATCH[1]}
        local codename=${debian_map[$ver]}
        url="https://cloud.debian.org/images/cloud/${codename}/latest/debian-${ver}-generic-arm64.qcow2"
    else
        echo -e "错误: 不支持的系统版本 ${system}\nError: Unsupported system version: ${system}" >&2
        echo -e "请查看 http://cloud-images.ubuntu.com 和 https://cloud.debian.org/images/cloud 支持的系统镜像\nSee supported images at http://cloud-images.ubuntu.com and https://cloud.debian.org/images/cloud."
        return 1
    fi
    local file_path="/root/qcow/${system}.${ext}"
    if [[ ! -f "$file_path" ]]; then
        echo -e "开始下载镜像: ${url}\nDownloading image: ${url}"
        curl -L -o "$file_path" "$url"
        if [[ $? -ne 0 ]]; then
            echo -e "下载失败: ${url}\nDownload failed: ${url}" >&2
            return 1
        fi
    else
        echo -e "镜像已存在: ${file_path}\nImage already exists: ${file_path}"
    fi
    return 0
}

check_ipv6_config() {
    independent_ipv6_status="N"
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
                if [ "$part_1_last" = "$vm_num" ]; then
                    ipv6_address=""
                else
                    part_1_head=$(echo "$part_1" | awk -F':' 'BEGIN {OFS=":"} {last=""; for (i=1; i<NF; i++) {last=last $i ":"}; print last}')
                    ipv6_address="${part_1_head}${vm_num}"
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
    return 0
}

is_ipv4() {
    local ip=$1
    local regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    if [[ $ip =~ $regex ]]; then
        return 0
    else
        return 1
    fi
}
