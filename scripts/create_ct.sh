#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2024.12.14

# cd /root

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    echo "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    echo "Locale set to $utf8_locale"
fi

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
        system_arch="arch"
        ;;
    *)
        system_arch=""
        ;;
    esac
}

check_cdn() {
    local o_url=$1
    for cdn_url in "${cdn_urls[@]}"; do
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
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, no use CDN"
    fi
}

cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
check_cdn_file

pre_check() {
    home_dir=$(eval echo "~$(whoami)")
    if [ "$home_dir" != "/root" ]; then
        _red "The script will exit if the current path is not /root."
        _red "当前路径不是/root，脚本将退出。"
        exit 1
    fi
    if ! command -v dos2unix >/dev/null 2>&1; then
        apt-get install dos2unix -y
    fi
    if [ ! -f "buildct.sh" ]; then
        curl -L ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/buildct.sh -o buildct.sh && chmod +x buildct.sh
        dos2unix buildct.sh
    fi
}

# files=$(find . -maxdepth 1 -name "ct*" | sort)
# if [ -n "$files" ]; then
#   for file in $files
#   do
#     cat "$file" >> ctlog
#   done
# fi

check_info() {
    log_file="ctlog"
    if [ ! -f "ctlog" ]; then
        _yellow "ctrlog file does not exist in the current directory"
        _yellow "当前目录下不存在ctlog文件"
        ct_num=11
        web2_port=20003
        port_end=30025
    else
        while read line; do
            last_line="$line"
        done <"$log_file"
        last_line_array=($last_line)
        ct_num="${last_line_array[0]}"
        password="${last_line_array[1]}"
        ssh_port="${last_line_array[5]}"
        web1_port="${last_line_array[6]}"
        web2_port="${last_line_array[7]}"
        port_start="${last_line_array[8]}"
        port_end="${last_line_array[9]}"
        system="${last_line_array[10]}"
        storage="${last_line_array[11]}"
        _green "Information corresponding to the current last NAT container:"
        _green "当前最后一个NAT容器对应的信息："
        echo "NAT容器(NAT container): $ct_num"
        #   echo "用户名: $user"
        #   echo "密码: $password"
        echo "外网SSH端口(Extranet SSH port): $ssh_port"
        echo "外网80端口(Extranet port 80): $web1_port"
        echo "外网443端口(Extranet port 443): $web2_port"
        echo "外网其他端口范围(Other port ranges): $port_start-$port_end"
        echo "系统(System)：$system"
        echo "存储盘(Storage Disk)：$storage"
    fi
}

build_new_cts() {
    while true; do
        _green "How many more NAT servers need to be generated? (Enter how many new NAT servers to add):"
        reading "还需要生成几个NAT服务器？(输入新增几个NAT服务器)：" new_nums
        if [[ "$new_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "Invalid input, please enter a positive integer."
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    while true; do
        _green "How many CPUs are assigned to each container? (Enter 1 if 1 core is assigned to each container):"
        reading "每个容器分配几个CPU？(若每个容器分配1核，则输入1)：" cpu_nums
        if [[ "$cpu_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "Invalid input, please enter a positive integer."
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    while true; do
        _green "How much memory is allocated per container? (If 512 MB of memory is allocated per container, enter 512):"
        reading "每个容器分配多少内存？(若每个容器分配512MB内存，则输入512)：" memory_nums
        if [[ "$memory_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "Invalid input, please enter a positive integer."
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    while true; do
        _green "On which storage drive are the containers opened? (Leave blank or enter 'local' if the container is to be opened on the system disk):"
        reading "容器们开设在哪个存储盘上？(若容器要开设在系统盘上，则留空或输入local)：" storage
        if [ -z "$storage" ]; then
            storage="local"
        fi
        break
    done
    while true; do
        _green "How many hard disks are allocated per container? (If 5G hard drives are allocated per container, enter 5):"
        reading "每个容器分配多少硬盘？(若每个容器分配5G硬盘，则输入5)：" disk_nums
        if [[ "$disk_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "Invalid input, please enter a positive integer."
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    while true; do
        _green "What system does each container use? (Leave blank or enter debian11 if all use debian11):"
        reading "每个容器都使用什么系统？(若都使用debian11，则留空或输入debian11)：" system
        if [ -z "$system" ]; then
            system="debian11"
        fi
        # 这块待增加系统列表查询
        break
    done
    while true; do
        _green "Need to attach a separate IPV6 address to each container?([N]/y)"
        reading "是否附加独立的IPV6地址？([N]/y)" independent_ipv6
        independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
        if [ "$independent_ipv6" = "y" ] || [ "$independent_ipv6" = "n" ]; then
            break
        else
            _yellow "Invalid input, please enter y or n."
            _yellow "输入无效，请输入Y或者N。"
        fi
    done
    for ((i = 1; i <= $new_nums; i++)); do
        ct_num=$(($ct_num + 1))
        ori=$(date | md5sum)
        password=${ori:2:9}
        ssh_port=$(($web2_port + 1))
        web1_port=$(($web2_port + 2))
        web2_port=$(($web1_port + 1))
        port_start=$(($port_end + 1))
        port_end=$(($port_start + 25))
        ./buildct.sh $ct_num $password $cpu_nums $memory_nums $disk_nums $ssh_port $web1_port $web2_port $port_start $port_end $system $storage $independent_ipv6
        cat "ct$ct_num" >>ctlog
        rm -rf "ct$ct_num"
        if [ "$i" = "$new_nums" ]; then
            break
        fi
        sleep 30
    done
}

pre_check
check_info
build_new_cts
check_info
