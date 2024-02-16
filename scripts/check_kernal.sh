#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2024.02.16

# 用颜色输出信息
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
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi
command -v apt-get &>/dev/null
apt_get_status=$?
command -v apt &>/dev/null
apt_status=$?
if [ $apt_get_status -ne 0 ] || [ $apt_status -ne 0 ]; then
    _yellow "The host environment does not have the apt package manager command, please check the system"
    _yellow "宿主机的环境无apt包管理器命令，请检查系统"
    exit 1
fi
apt-get install lsb-release -y
if ! command -v lshw >/dev/null 2>&1; then
    apt-get install lshw -y
fi
if ! command -v ifconfig >/dev/null 2>&1; then
    apt-get install net-tools -y
fi
if ! command -v sipcalc >/dev/null 2>&1; then
    apt-get install sipcalc -y
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

check_config() {
    _blue "The machine configuration should meet the minimum requirements of at least 2 cores 2G RAM 20G hard drive"
    _green "本机配置应当满足至少2核2G内存20G硬盘的最低要求"

    # 检查硬盘大小
    total_disk=$(df -h / | awk '/\//{print $2}')
    total_disk_num=$(echo $total_disk | sed -E 's/([0-9.]+)([GT])/\1 \2/')
    total_disk_num=$(awk '{printf "%.0f", $1 * ($2 == "T" ? 1024 : 1)}' <<<"$total_disk_num")
    if [ "$total_disk_num" -lt 20 ]; then
        _red "The machine configuration does not meet the minimum requirements: at least 20G hard drive"
        _red "This machine's hard drive configuration does not allow for the installation of PVE"
        _red "本机配置不满足最低要求：至少20G硬盘"
        _red "本机硬盘配置无法安装PVE"
    fi

    # 检查CPU核心数
    cpu_cores=$(grep -c ^processor /proc/cpuinfo)
    if [ "$cpu_cores" -lt 2 ]; then
        _red "The local machine configuration does not meet the minimum requirements: at least 2 core CPU"
        _red "The number of CPUs on this machine is configured in such a way that PVE cannot be installed"
        _red "本机配置不满足最低要求：至少2核CPU"
        _red "本机CPU数量配置无法安装PVE"
    fi

    # 检查内存大小
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    swap_info=$(free -m | awk '/^Swap:/{print $2}')
    if [ "$swap_info" -ne 0 ]; then
        total_mem=$((total_mem + swap_info))
    fi
    if [ "$total_mem" -lt 2048 ]; then
        _red "The machine configuration does not meet the minimum requirements: at least 2G RAM"
        _red "The local memory configuration cannot install PVE"
        _red "本机配置不满足最低要求：至少2G内存"
        _red "本机内存配置无法安装PVE"
    fi
}

is_private_ipv6() {
    local address=$1
    local temp="0"
    # 输入为空
    if [[ ! -n $address ]]; then
        temp="1"
    fi
    # 输入不含:符号
    if [[ -n $address && $address != *":"* ]]; then
        temp="2"
    fi
    # 检查IPv6地址是否以fe80开头（链接本地地址）
    if [[ $address == fe80:* ]]; then
        temp="3"
    fi
    # 检查IPv6地址是否以fc00或fd00开头（唯一本地地址）
    if [[ $address == fc00:* || $address == fd00:* ]]; then
        temp="4"
    fi
    # 检查IPv6地址是否以2001:db8开头（文档前缀）
    if [[ $address == 2001:db8* ]]; then
        temp="5"
    fi
    # 检查IPv6地址是否以::1开头（环回地址）
    if [[ $address == ::1 ]]; then
        temp="6"
    fi
    # 检查IPv6地址是否以::ffff:开头（IPv4映射地址）
    if [[ $address == ::ffff:* ]]; then
        temp="7"
    fi
    # 检查IPv6地址是否以2002:开头（6to4隧道地址）
    if [[ $address == 2002:* ]]; then
        temp="8"
    fi
    # 检查IPv6地址是否以2001:开头（Teredo隧道地址）
    if [[ $address == 2001:* ]]; then
        temp="9"
    fi
    if [ "$temp" -gt 0 ]; then
        # 非公网情况
        return 0
    else
        # 其他情况为公网地址
        return 1
    fi
}

check_ipv6() {
    IPV6=$(ip -6 addr show | grep global | awk '{print length, $2}' | sort -nr | head -n 1 | awk '{print $2}' | cut -d '/' -f1)
    # ip a | grep -oP 'inet6 .*global.*mngtmpaddr' | awk '{print $2}'
    if [ ! -f /usr/local/bin/pve_last_ipv6 ] || [ ! -s /usr/local/bin/pve_last_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_last_ipv6)" = "" ]; then
        ipv6_list=$(ip -6 addr show | grep global | awk '{print length, $2}' | sort -nr | awk '{print $2}')
        line_count=$(echo "$ipv6_list" | wc -l)
        if [ "$line_count" -ge 2 ]; then
            # 获取最后一行的内容
            last_ipv6=$(echo "$ipv6_list" | tail -n 1)
            # 切分最后一个:之前的内容
            last_ipv6_prefix="${last_ipv6%:*}:"
            # 与${ipv6_gateway}比较是否相同
            if [ "${last_ipv6_prefix}" = "${ipv6_gateway%:*}:" ]; then
                echo $last_ipv6 >/usr/local/bin/pve_last_ipv6
            fi
            _blue "The local machine is bound to more than one IPV6 address"
            _green "本机绑定了不止一个IPV6地址"
        fi
    fi

    if is_private_ipv6 "$IPV6"; then # 由于是内网IPV6地址，需要通过API获取外网地址
        IPV6=""
        API_NET=("ipv6.ip.sb" "https://ipget.net" "ipv6.ping0.cc" "https://api.my-ip.io/ip" "https://ipv6.icanhazip.com")
        for p in "${API_NET[@]}"; do
            response=$(curl -sLk6m8 "$p" | tr -d '[:space:]')
            if [ $? -eq 0 ] && ! (echo "$response" | grep -q "error"); then
                IPV6="$response"
                break
            fi
            sleep 1
        done
    fi
    echo $IPV6 >/usr/local/bin/pve_check_ipv6
}

check_interface() {
    if [ -z "$interface_2" ]; then
        interface=${interface_1}
        return
    elif [ -n "$interface_1" ] && [ -n "$interface_2" ]; then
        if ! grep -q "$interface_1" "/etc/network/interfaces" && ! grep -q "$interface_2" "/etc/network/interfaces" && [ -f "/etc/network/interfaces.d/50-cloud-init" ]; then
            if grep -q "$interface_1" "/etc/network/interfaces.d/50-cloud-init" || grep -q "$interface_2" "/etc/network/interfaces.d/50-cloud-init"; then
                if ! grep -q "$interface_1" "/etc/network/interfaces.d/50-cloud-init" && grep -q "$interface_2" "/etc/network/interfaces.d/50-cloud-init"; then
                    interface=${interface_2}
                    return
                elif ! grep -q "$interface_2" "/etc/network/interfaces.d/50-cloud-init" && grep -q "$interface_1" "/etc/network/interfaces.d/50-cloud-init"; then
                    interface=${interface_1}
                    return
                fi
            fi
        fi
        if grep -q "$interface_1" "/etc/network/interfaces"; then
            interface=${interface_1}
            return
        elif grep -q "$interface_2" "/etc/network/interfaces"; then
            interface=${interface_2}
            return
        else
            interfaces_list=$(ip addr show | awk '/^[0-9]+: [^lo]/ {print $2}' | cut -d ':' -f 1)
            interface=""
            for iface in $interfaces_list; do
                if [[ "$iface" = "$interface_1" || "$iface" = "$interface_2" ]]; then
                    interface="$iface"
                fi
            done
            if [ -z "$interface" ]; then
                interface="eth0"
            fi
            return
        fi
    else
        interface="eth0"
        return
    fi
    _red "Physical interface not found, exit execution"
    _red "找不到物理接口，退出执行"
    exit 1
}

# 检测系统是否支持
get_system_arch
version=$(lsb_release -cs)
if [ "$system_arch" = "arch" ]; then
    _blue "system_arch: arch"
    _green "架构：arch"
    case $version in
    stretch | buster)
        _yellow "The recognized system is $version"
        _yellow "识别到的系统为 $version"
        _yellow "Please upgrade to use debian11 or debian12 system, otherwise you can't install pve by this script."
        _yellow "请升级使用debian11或debian12系统，否则无法通过本脚本安装pve"
        ;;
    bullseye | bookworm)
        _blue "The recognized system is $version"
        _green "识别到的系统为 $version"
        ;;
    *)
        _yellow "Error: Recognized as an unsupported version of Debian, but you can force an installation attempt or use the custom partitioning method to install the PVE"
        _yellow "Error: 识别为不支持的Debian版本，但你可以强行安装尝试或使用自定义分区的方法安装PVE"
        ;;
    esac
elif [ "$system_arch" = "x86" ]; then
    _blue "system_arch: x86"
    _green "架构：x86"
    case $version in
    stretch | buster | bullseye | bookworm)
        _blue "The recognized system is $version"
        _green "识别到的系统为 $version"
        ;;
    *)
        _yellow "Error: Recognized as an unsupported version of Debian, but you can force an installation attempt or use the custom partitioning method to install the PVE"
        _yellow "Error: 识别为不支持的Debian版本，但你可以强行安装尝试或使用自定义分区的方法安装PVE"
        ;;
    esac
else
    _yellow "Error: Recognized as an unsupported architecture, but you can force an installation attempt or use the custom partitioning method to install PVE"
    _yellow "Error: 识别为不支持的架构，但你可以强行安装尝试或使用自定义分区的方法安装PVE"
fi

# 检测IPV6网络配置
if command -v lshw >/dev/null 2>&1; then
    # 检测物理接口
    interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
    interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
    check_interface
    # 检测IPV6相关的信息
    if [ ! -f /usr/local/bin/pve_ipv6_gateway ] || [ ! -s /usr/local/bin/pve_ipv6_gateway ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_ipv6_gateway)" = "" ]; then
        ipv6_gateway=$(ip -6 route show | awk '/default via/{print $3}' | head -n1)
        # output=$(ip -6 route show | awk '/default via/{print $3}')
        # num_lines=$(echo "$output" | wc -l)
        # ipv6_gateway=""
        # if [ $num_lines -eq 1 ]; then
        #     ipv6_gateway="$output"
        # elif [ $num_lines -ge 2 ]; then
        #     non_fe80_lines=$(echo "$output" | grep -v '^fe80')
        #     if [ -n "$non_fe80_lines" ]; then
        #         ipv6_gateway=$(echo "$non_fe80_lines" | head -n 1)
        #     else
        #         ipv6_gateway=$(echo "$output" | head -n 1)
        #     fi
        # fi
        echo "$ipv6_gateway" >/usr/local/bin/pve_ipv6_gateway
    fi
    ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
    if [ ! -f /usr/local/bin/pve_check_ipv6 ]; then
        check_ipv6
    fi
    if [ ! -f /usr/local/bin/pve_fe80_address ] || [ ! -s /usr/local/bin/pve_fe80_address ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_fe80_address)" = "" ]; then
        fe80_address=$(ip -6 addr show dev $interface | awk '/inet6 fe80/ {print $2}')
        echo "$fe80_address" >/usr/local/bin/pve_fe80_address
    fi
    ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
    fe80_address=$(cat /usr/local/bin/pve_fe80_address)
    # 判断fe80是否已加白
    if [[ $ipv6_gateway == fe80* ]]; then
        ipv6_gateway_fe80="Y"
    else
        ipv6_gateway_fe80="N"
    fi
    if [ ! -f /usr/local/bin/pve_ipv6_prefixlen ]; then
        ipv6_prefixlen=""
        output=$(ifconfig ${interface} | grep -oP 'inet6 (?!fe80:).*prefixlen \K\d+')
        num_lines=$(echo "$output" | wc -l)
        if [ $num_lines -ge 2 ]; then
            ipv6_prefixlen=$(echo "$output" | sort -n | head -n 1)
        else
            ipv6_prefixlen=$(echo "$output" | head -n 1)
        fi
        if [ -z "$ipv6_prefixlen" ]; then
            ipv6_prefixlen=$(ifconfig eth0 | grep -oP 'prefixlen \K\d+' | head -n 1)
        fi
        if [ -z "$ipv6_prefixlen" ]; then
            ipv6_prefixlen=$(ifconfig vmbr0 | grep -oP 'prefixlen \K\d+' | head -n 1)
        fi
        if [ -z "$ipv6_prefixlen" ]; then
            ipv6_prefixlen=$(ifconfig vmbr1 | grep -oP 'prefixlen \K\d+' | head -n 1)
        fi
        echo "$ipv6_prefixlen" >/usr/local/bin/pve_ipv6_prefixlen
    fi
    ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
    if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
        :
    else
        # if ping -c 1 -6 -W 3 $ipv6_address >/dev/null 2>&1; then
        #     echo "IPv6 address is reachable."
        # else
        #     echo "IPv6 address is not reachable. Setting to empty."
        #     echo "" >/usr/local/bin/pve_check_ipv6
        # fi
        # if ping -c 1 -6 -W 3 $ipv6_gateway >/dev/null 2>&1; then
        #     echo "IPv6 gateway is reachable."
        # else
        #     echo "IPv6 gateway is not reachable. Setting to empty."
        #     echo "" >/usr/local/bin/pve_ipv6_gateway
        # fi
        ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
        ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
        _blue "The following IPV6 information is detected for this machine:"
        _green "检测到本机的IPV6信息如下："
        _green "ipv6_address: ${ipv6_address}"
        _green "ipv6_prefixlen: ${ipv6_prefixlen}"
        _green "ipv6_gateway: ${ipv6_gateway}"
    fi
    mac_address=$(ip a | grep -oP 'link/ether \K[0-9a-f:]+')
    mac_end_suffix=$(echo $mac_address | awk -F: '{print $4$5}')
    ipv6_end_suffix=${ipv6_address##*:}
    slaac_status=false
    if [[ $ipv6_address == *"ff:fe"* ]]; then
        _blue "Since the IPV6 address contains the ff:fe block, the probability is that the IPV6 address assigned out through SLAAC"
        _green "由于IPV6地址含有ff:fe块，大概率通过SLAAC分配出的IPV6地址"
        slaac_status=true
    elif [[ $ipv6_gateway == "fe80"* ]]; then
        _blue "Since IPV6 gateways begin with fe80, it is generally assumed that IPV6 addresses assigned through the SLAAC"
        _green "由于IPV6的网关是fe80开头，一般认为通过SLAAC分配出的IPV6地址"
        slaac_status=true
    elif [[ $ipv6_end_suffix == $mac_end_suffix ]]; then
        _blue "Since IPV6 addresses have the same suffix as mac addresses, the probability is that the IPV6 address assigned through the SLAAC"
        _green "由于IPV6的地址和mac地址后缀相同，大概率通过SLAAC分配出的IPV6地址"
        slaac_status=true
    fi
    if [[ $slaac_status == true ]] && [ ! -f /usr/local/bin/pve_slaac_status ]; then
        _blue "Since IPV6 addresses are assigned via SLAAC, the subsequent one-click script installation process needs to determine whether to use the largest subnet"
        _blue "If using the largest subnet make sure that the host is assigned an entire subnet and not just an IPV6 address"
        _blue "It is not possible to determine within the host computer how large a subnet the upstream has given to this machine, please ask the upstream technician for details."
        _green "由于是通过SLAAC分配出IPV6地址，所以后续一键脚本安装过程中需要判断是否使用最大子网"
        _green "若使用最大子网请确保宿主机被分配的是整个子网而不是仅一个IPV6地址"
        _green "无法在宿主机内部判断上游给了本机多大的子网，详情请询问上游技术人员"
        echo "" >/usr/local/bin/pve_slaac_status
    fi
fi

# 检测硬件配置
check_config

# 检查CPU是否支持硬件虚拟化
if [ "$(egrep -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    _yellow "CPU does not support hardware virtualization, cannot nest virtualized KVM servers, but can open LXC servers (CT)"
    _yellow "CPU不支持硬件虚拟化，无法嵌套虚拟化KVM服务器，但可以开LXC服务器(CT)"
    exit 1
else
    _green "The local CPU supports KVM hardware nested virtualization"
    _green "本机CPU支持KVM硬件嵌套虚拟化"
fi

# 检查虚拟化选项是否启用
if [ "$(grep -E -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    _yellow "Hardware virtualization is not enabled in BIOS, cannot nest virtualized KVM servers, but can open LXC servers (CT)"
    _yellow "BIOS中未启用硬件虚拟化，无法嵌套虚拟化KVM服务器，但可以开LXC服务器(CT)"
    exit 1
else
    _green "This machine BIOS is enabled to support KVM hardware nested virtualization"
    _green "本机BIOS已启用支持KVM硬件嵌套虚拟化"
fi

# 查询系统是否支持
if [ -e "/sys/module/kvm_intel/parameters/nested" ] && [ "$(cat /sys/module/kvm_intel/parameters/nested | tr '[:upper:]' '[:lower:]')" = "y" ]; then
    CPU_TYPE="intel"
elif [ -e "/sys/module/kvm_amd/parameters/nested" ] && [ "$(cat /sys/module/kvm_amd/parameters/nested | tr '[:upper:]' '[:lower:]')" = "1" ]; then
    CPU_TYPE="amd"
else
    _yellow "The local system configuration file identifies that KVM hardware nested virtualization is not supported, the KVM server virtualized using PVE may not be able to turn on KVM hardware virtualization in the options, if you have problems using NOVNC remember to turn it off in the open out KVM server options, subject to whether you can actually use it"
    _yellow "本机系统配置文件识别到不支持KVM硬件嵌套虚拟化，使用PVE虚拟化出来的KVM服务器可能不能在选项中开启KVM硬件虚拟化，如果使用NOVNC有问题记得在开出来的KVM服务器选项中关闭，以实际能否使用为准"
    exit 1
fi

if ! lsmod | grep -q kvm; then
    if [ "$CPU_TYPE" = "intel" ]; then
        _yellow "KVM module not loaded, can't use PVE virtualized KVM server, but can open LXC server (CT)"
        _yellow "KVM模块未加载，不能使用PVE虚拟化KVM服务器，但可以开LXC服务器(CT)"
    elif [ "$CPU_TYPE" = "amd" ]; then
        _yellow "KVM module not loaded, can't use PVE virtualized KVM server, but can open LXC server (CT)"
        _yellow "KVM模块未加载，不能使用PVE虚拟化KVM服务器，但可以开LXC服务器(CT)"
    fi
else
    _green "This machine meets the requirements: it can use PVE to virtualize the KVM server and can turn on KVM hardware virtualization in the KVM server option that is opened"
    _green "本机符合要求：可以使用PVE虚拟化KVM服务器，并可以在开出来的KVM服务器选项中开启KVM硬件虚拟化"
fi

# 如果KVM模块未加载，则加载KVM模块并将其添加到/etc/modules文件中
if ! lsmod | grep -q kvm; then
    _yellow "Trying to load KVM module ......"
    _yellow "尝试加载KVM模块……"
    modprobe kvm
    echo "kvm" >>/etc/modules
    _green "KVM module has tried to load and add to /etc/modules, you can try to use PVE virtualized KVM server, you can also open LXC server (CT)"
    _green "KVM模块已尝试加载并添加到 /etc/modules，可以尝试使用PVE虚拟化KVM服务器，也可以开LXC服务器(CT)"
fi
