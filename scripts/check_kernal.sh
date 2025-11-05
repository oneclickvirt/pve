#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.11.05

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
if ! command -v rdisc6 >/dev/null 2>&1; then
    _blue "Installing ndisc6 package for IPv6 router discovery..."
    _green "正在安装 ndisc6 软件包用于 IPv6 路由器发现..."
    apt-get install ndisc6 -y
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
    fi
    if [ -z "$interface_1" ] && [ -z "$interface_2" ]; then
        interface="eth0"
        return
    fi
    local config_files=(
        "/etc/network/interfaces"
        "/etc/network/interfaces.d/50-cloud-init"
    )
    for config_file in "${config_files[@]}"; do
        if [ -f "$config_file" ]; then
            if grep -q "$interface_1" "$config_file"; then
                interface=${interface_1}
                return
            elif grep -q "$interface_2" "$config_file"; then
                interface=${interface_2}
                return
            fi
        fi
    done
    local interfaces_list=$(ip addr show | awk '/^[0-9]+: [^lo]/ {print $2}' | cut -d ':' -f 1)
    if echo "$interfaces_list" | grep -q "^${interface_1}$"; then
        interface=${interface_1}
        return
    fi
    if echo "$interfaces_list" | grep -q "^${interface_2}$"; then
        interface=${interface_2}
        return
    fi
    interface="eth0"
    if ! echo "$interfaces_list" | grep -q "^eth0$" && [ -n "$interfaces_list" ]; then
        interface=$(echo "$interfaces_list" | head -n 1)
    fi
}

# 检测系统是否支持
get_system_arch
version=$(lsb_release -cs)
if [ "$system_arch" = "arch" ]; then
    _blue "system_arch: arch"
    _green "架构：arch"
    case $version in
    stretch | buster)
        _blue "The recognized system is $version"
        _green "识别到的系统为 $version"
        _blue "Will use Pixmox for low version PVE installations"
        _green "将使用 Pixmox 进行低版本的PVE安装"
        ;;
    bullseye | bookworm | trixie)
        _blue "The recognized system is $version"
        _green "识别到的系统为 $version"
        _blue "Will use Pxvirt for PVE installation"
        _green "将使用 Pxvirt 进行低版本的PVE安装"
        ;;
    *)
        _yellow "Error: Recognized as an unsupported version of Debian, but you can force an installation attempt or use the custom partitioning method to install the PVE"
        _yellow "Error: 识别为不支持的Debian版本，但你可以强行安装尝试或使用自定义分区的方法安装PVE"
        ;;
    esac
elif [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
    _blue "system_arch: x86"
    _green "架构：x86"
    case $version in
    stretch | buster | bullseye | bookworm | trixie)
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
        # 首先尝试从接口配置获取
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
        # 尝试使用 rdisc6 工具获取路由器通告的真实前缀大小
        if command -v rdisc6 >/dev/null 2>&1; then
            _blue "Attempting to get real IPv6 prefix from router advertisement using rdisc6..."
            _green "尝试使用 rdisc6 从路由器通告中获取真实的 IPv6 前缀..."
            # 使用 rdisc6 查询路由器通告，设置超时时间为3秒
            rdisc6_output=$(timeout 3 rdisc6 ${interface} 2>/dev/null | grep -A 4 "Prefix")
            if [ -n "$rdisc6_output" ]; then
                # 提取前缀长度，例如从 "Prefix : 2406:da18:xxxx:xxxx::/64" 中提取 64
                real_prefixlen=$(echo "$rdisc6_output" | grep "Prefix" | head -n 1 | grep -oP '::?/\K\d+')
                if [ -n "$real_prefixlen" ] && [ "$real_prefixlen" -gt 0 ] && [ "$real_prefixlen" -le 128 ]; then
                    _green "Found real IPv6 prefix length from router advertisement: /$real_prefixlen"
                    _green "从路由器通告中发现真实的 IPv6 前缀长度: /$real_prefixlen"
                    # 如果接口配置的前缀长度小于路由器通告的(即配置错误/不完整)
                    if [ -n "$ipv6_prefixlen" ] && [ "$ipv6_prefixlen" -gt "$real_prefixlen" ]; then
                        _yellow "Warning: Current interface prefix /$ipv6_prefixlen is smaller than router advertised /$real_prefixlen"
                        _yellow "警告: 当前接口前缀 /$ipv6_prefixlen 小于路由器通告的 /$real_prefixlen"
                        _blue "Using the larger prefix /$real_prefixlen from router advertisement"
                        _green "将使用路由器通告的更大前缀 /$real_prefixlen"
                        ipv6_prefixlen="$real_prefixlen"
                    elif [ -z "$ipv6_prefixlen" ]; then
                        # 如果之前没有获取到前缀，直接使用路由器通告的
                        ipv6_prefixlen="$real_prefixlen"
                    fi
                    # 保存路由器通告的前缀供后续使用
                    echo "$real_prefixlen" >/usr/local/bin/pve_ipv6_real_prefixlen
                fi
            else
                _yellow "Could not get router advertisement response via rdisc6 (timeout or no response)"
                _yellow "无法通过 rdisc6 获取路由器通告响应(超时或无响应)"
            fi
        else
            _yellow "rdisc6 tool not found. Install ndisc6 package to detect real IPv6 prefix from router."
            _yellow "未找到 rdisc6 工具。安装 ndisc6 软件包可以从路由器检测真实的 IPv6 前缀。"
            _blue "You can install it with: apt-get install ndisc6 -y"
            _green "可以使用以下命令安装: apt-get install ndisc6 -y"
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
fi

# 检测硬件配置
check_config

# 检查 CPU 是否支持硬件虚拟化指令集
if [ "$(egrep -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    _yellow "CPU does not support hardware virtualization (vmx/svm); nested KVM virtualization is not possible. You can still run LXC containers or QEMU with software emulation (TCG)."
    _yellow "CPU 不支持硬件虚拟化（缺少 vmx/svm 指令），无法进行嵌套 KVM 虚拟化。但仍可使用 LXC 容器或 QEMU 软件仿真（TCG）运行虚拟机。"
    exit 1
else
    _green "CPU supports hardware virtualization (vmx/svm); nested KVM virtualization is possible."
    _green "CPU 支持硬件虚拟化（支持 vmx/svm 指令），可用于嵌套 KVM 虚拟化。"
fi

# 检查虚拟化是否已在 BIOS/UEFI 中启用
if [ "$(grep -E -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    _yellow "Hardware virtualization is disabled in BIOS/UEFI; nested KVM virtualization will not work."
    _yellow "BIOS/UEFI 中未启用硬件虚拟化，嵌套 KVM 虚拟化将无法使用。"
    exit 1
else
    _green "Hardware virtualization is enabled in BIOS/UEFI; nested KVM virtualization is supported."
    _green "BIOS/UEFI 中已启用硬件虚拟化，支持嵌套 KVM 虚拟化。"
fi

# 检查宿主机是否启用了嵌套虚拟化
if [ -e "/sys/module/kvm_intel/parameters/nested" ]; then
    NESTED=$(cat /sys/module/kvm_intel/parameters/nested | tr '[:upper:]' '[:lower:]')
    if [ "$NESTED" = "y" ]; then
        CPU_TYPE="intel"
    else
        _yellow "Nested virtualization is supported by the Intel KVM module but currently disabled (nested=0)."
        _yellow "已加载 Intel KVM 模块，但嵌套虚拟化当前未启用（nested=0）。"
        exit 1
    fi
elif [ -e "/sys/module/kvm_amd/parameters/nested" ]; then
    NESTED=$(cat /sys/module/kvm_amd/parameters/nested | tr '[:upper:]' '[:lower:]')
    if [ "$NESTED" = "1" ]; then
        CPU_TYPE="amd"
    else
        _yellow "Nested virtualization is supported by the AMD KVM module but currently disabled (nested=0)."
        _yellow "已加载 AMD KVM 模块，但嵌套虚拟化当前未启用（nested=0）。"
        exit 1
    fi
else
    _yellow "KVM kernel module with nested virtualization support is not loaded or not available in this environment."
    _yellow "未检测到启用嵌套虚拟化支持的 KVM 内核模块，可能是当前系统运行在虚拟机中且未开启嵌套虚拟化，或内核未加载 kvm_intel/kvm_amd 模块。"
    _yellow "请确保宿主机已启用嵌套虚拟化，并通过 modprobe 或 grub 参数启用 nested=1，再重启生效。"
    exit 1
fi

# 检查 kvm 模块是否已加载
if ! lsmod | grep -q kvm; then
    _yellow "KVM module is not currently loaded. KVM-based acceleration (hardware virtualization) will not be available."
    _yellow "当前未加载 KVM 模块，无法使用基于 KVM 的加速（硬件虚拟化）。"
    _yellow "You can still run virtual machines using QEMU TCG (software emulation), but performance may be poor."
    _yellow "仍可通过 QEMU TCG（软件仿真）运行虚拟机，但性能可能较差。"
    _yellow "Attempting to load the KVM module..."
    _yellow "正在尝试加载 KVM 模块……"
    if modprobe kvm; then
        echo "kvm" >> /etc/modules
        _green "Successfully loaded the KVM module and added it to /etc/modules."
        _green "KVM 模块已成功加载，并添加至 /etc/modules。"
    else
        _yellow "Failed to load the KVM module, continuing without hardware virtualization support."
        _yellow "KVM 模块加载失败，将继续使用软件虚拟化。"
    fi
else
    _green "KVM module is already loaded. Hardware virtualization is available for better performance."
    _green "KVM 模块已加载，可使用硬件虚拟化以获得更好性能。"
fi

# 检查并尝试加载 CPU 对应的嵌套模块（Intel 或 AMD）
if [ "$CPU_TYPE" = "intel" ] && ! lsmod | grep -q kvm_intel; then
    _yellow "Attempting to load Intel KVM module (kvm_intel)..."
    _yellow "正在尝试加载 Intel 的 KVM 模块（kvm_intel）……"
    if modprobe kvm_intel nested=1; then
        echo "kvm_intel" >> /etc/modules
        _green "Loaded kvm_intel module with nested virtualization enabled."
        _green "已加载 kvm_intel 模块并启用嵌套虚拟化。"
    fi
elif [ "$CPU_TYPE" = "amd" ] && ! lsmod | grep -q kvm_amd; then
    _yellow "Attempting to load AMD KVM module (kvm_amd)..."
    _yellow "正在尝试加载 AMD 的 KVM 模块（kvm_amd）……"
    if modprobe kvm_amd nested=1; then
        echo "kvm_amd" >> /etc/modules
        _green "Loaded kvm_amd module with nested virtualization enabled."
        _green "已加载 kvm_amd 模块并启用嵌套虚拟化。"
    fi
fi
