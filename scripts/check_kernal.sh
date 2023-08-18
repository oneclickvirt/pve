#!/bin/bash
# from 
# https://github.com/spiritLHLS/pve
# 2023.08.18

# 用颜色输出信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }
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

check_config(){
    _green "The machine configuration should meet the minimum requirements of at least 2 cores 2G RAM 20G hard drive"
    _green "本机配置应当满足至少2核2G内存20G硬盘的最低要求"
    
    # 检查硬盘大小
    total_disk=$(df -h / | awk '/\//{print $2}')
    total_disk_num=$(echo $total_disk | sed -E 's/([0-9.]+)([GT])/\1 \2/')
    total_disk_num=$(awk '{printf "%.0f", $1 * ($2 == "T" ? 1024 : 1)}' <<< "$total_disk_num")
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
    if [ "$total_mem" -lt 2048 ]; then
        _red "The machine configuration does not meet the minimum requirements: at least 2G RAM"
        _red "The local memory configuration cannot install PVE (SWAP is not calculated, if the virtual memory of SWAP plus the actual memory of the local machine is greater than 2G please ignore this prompt)"
        _red "本机配置不满足最低要求：至少2G内存"
        _red "本机内存配置无法安装PVE (未计算SWAP，如若SWAP的虚拟内存加上本机实际内存大于2G请忽略本提示)"
    fi
}

is_private_ipv6() {
    local address=$1
    # 输入不含:符号
    if [[ $ip_address != *":"* ]]; then
        return 0
    fi
    # 输入为空
    if [[ -z $ip_address ]]; then
        return 0
    fi
    # 检查IPv6地址是否以fe80开头（链接本地地址）
    if [[ $address == fe80:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以fc00或fd00开头（唯一本地地址）
    if [[ $address == fc00:* || $address == fd00:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以2001:db8开头（文档前缀）
    if [[ $address == 2001:db8* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以::1开头（环回地址）
    if [[ $address == ::1 ]]; then
        return 0
    fi
    # 检查IPv6地址是否以::ffff:开头（IPv4映射地址）
    if [[ $address == ::ffff:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以2002:开头（6to4隧道地址）
    if [[ $address == 2002:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以2001:开头（Teredo隧道地址）
    if [[ $address == 2001:* ]]; then
        return 0
    fi
    # 其他情况为公网地址
    return 1
}

check_ipv6(){
    IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    local response
    if is_private_ipv6 "$IPV6"; then # 由于是内网IPV4地址，需要通过API获取外网地址
        IPV6=""
        local API_NET=("ipv6.ip.sb" "https://ipget.net" "ipv6.ping0.cc" "https://api.my-ip.io/ip" "https://ipv6.icanhazip.com")
        for p in "${API_NET[@]}"; do
            response=$(curl -sLk6m8 "$p" | tr -d '[:space:]')
            if [ $? -eq 0 ] && ! echo "$response" | grep -q "error"; then
                IPV6="$response"
                break
            fi
            sleep 1
        done
    fi
    echo $IPV6 > /usr/local/bin/pve_check_ipv6
}

# 检测IPV6网络配置
if ! command -v lshw > /dev/null 2>&1 ; then
    apt-get install lshw -y
fi
if ! command -v ifconfig > /dev/null 2>&1 ; then
  apt-get install net-tools -y
fi
if command -v lshw > /dev/null 2>&1 ; then
    # 检测物理接口
    interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
    interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
    # 检测IPV6相关的信息
    if [ ! -f /usr/local/bin/pve_check_ipv6 ]; then
        check_ipv6
    fi
    if [ ! -f /usr/local/bin/pve_ipv6_prefixlen ]; then
        ipv6_prefixlen=$(ifconfig ${interface_1} | grep -oP 'prefixlen \K\d+' | head -n 1)
        if [ -z "$ipv6_prefixlen" ]; then
            ipv6_prefixlen=$(ifconfig ${interface_2} | grep -oP 'prefixlen \K\d+' | head -n 1)
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
        echo "$ipv6_prefixlen" > /usr/local/bin/pve_ipv6_prefixlen
    fi
    if [ ! -f /usr/local/bin/pve_ipv6_gateway ]; then
        ipv6_gateway=$(ip -6 route show | awk '/default via/{print $3}' | head -n1)
        echo "$ipv6_gateway" > /usr/local/bin/pve_ipv6_gateway
    fi
    ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
    ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
    ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
    if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
        :
    else
        _green "The following IPV6 information is detected for this machine:"
        _green "检测到本机的IPV6信息如下："
        _green "ipv6_address: ${ipv6_address}"
        _green "ipv6_prefixlen: ${ipv6_prefixlen}"
        _green "ipv6_gateway: ${ipv6_gateway}"
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
    echo "kvm" >> /etc/modules
    _green "KVM module has tried to load and add to /etc/modules, you can try to use PVE virtualized KVM server, you can also open LXC server (CT)"
    _green "KVM模块已尝试加载并添加到 /etc/modules，可以尝试使用PVE虚拟化KVM服务器，也可以开LXC服务器(CT)"
fi
