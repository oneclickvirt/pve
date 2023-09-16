#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.09.16

########## 预设部分输出和部分中间变量

cd /root >/dev/null 2>&1
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    echo "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    echo "Locale set to $utf8_locale"
fi
temp_file_apt_fix="/tmp/apt_fix.txt"
command -v pct &>/dev/null
pct_status=$?
command -v qm &>/dev/null
qm_status=$?
if [ $pct_status -eq 0 ] && [ $qm_status -eq 0 ]; then
    _green "Proxmox VE is already installed and does not need to be reinstalled."
    _green "Proxmox VE已经安装，无需重复安装。"
fi

########## 备份配置文件

if [ -f /etc/network/interfaces ]; then
    if [ ! -f /etc/network/interfaces.bak ]; then
        cp /etc/network/interfaces /etc/network/interfaces.bak
    fi
fi
if [ -f /etc/network/interfaces.new ]; then
    if [ ! -f /etc/network/interfaces.new.bak ]; then
        cp /etc/network/interfaces.new /etc/network/interfaces.new.bak
    fi
fi
if [ -f "/etc/cloud/cloud.cfg" ]; then
    if [ ! -f /etc/cloud/cloud.cfg.bak ]; then
        cp /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.bak
    fi
fi
if [ -f "/etc/hosts" ]; then
    if [ ! -f /etc/hosts.bak ]; then
        cp /etc/hosts /etc/hosts.bak
    fi
fi
if [ -f "/etc/apt/sources.list" ]; then
    if [ ! -f /etc/apt/sources.list.bak ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
    fi
fi

########## 定义部分需要使用的函数

remove_duplicate_lines() {
    chattr -i "$1"
    # 预处理：去除行尾空格和制表符
    sed -i 's/[ \t]*$//' "$1"
    # 去除重复行并跳过空行和注释行
    if [ -f "$1" ]; then
        awk '{ line = $0; gsub(/^[ \t]+/, "", line); gsub(/[ \t]+/, " ", line); if (!NF || !seen[line]++) print $0 }' "$1" >"$1.tmp" && mv -f "$1.tmp" "$1"
    fi
    chattr +i "$1"
}

install_package() {
    package_name=$1
    if command -v $package_name >/dev/null 2>&1; then
        _green "$package_name already installed"
        _green "$package_name 已经安装"
    else
        apt-get install -o Dpkg::Options::="--force-confnew" -y $package_name
        if [ $? -ne 0 ]; then
            apt_output=$(apt-get install -y $package_name --fix-missing 2>&1)
        fi
        if [ $? -ne 0 ]; then
            if echo "$apt_output" | grep -qE 'DEBIAN_FRONTEND=dialog dpkg --configure grub-pc' &&
                echo "$apt_output" | grep -qE 'dpkg --configure -a' &&
                echo "$apt_output" | grep -qE 'dpkg: error processing package grub-pc \(--configure\):'; then
                # 手动选择
                # DEBIAN_FRONTEND=dialog dpkg --configure grub-pc
                # 设置debconf的选择
                echo "grub-pc grub-pc/install_devices multiselect /dev/sda" | sudo debconf-set-selections
                # 配置grub-pc并自动选择第一个选项确认
                sudo DEBIAN_FRONTEND=noninteractive dpkg --configure grub-pc
                dpkg --configure -a
                if [ $? -ne 0 ]; then
                    _green "$package_name tried to install but failed, exited the program"
                    _green "$package_name 已尝试安装但失败，退出程序"
                    exit 1
                fi
                apt-get install -y $package_name --fix-missing
            fi
        fi
        if [ $? -ne 0 ]; then
            _green "$package_name tried to install but failed, exited the program"
            _green "$package_name 已尝试安装但失败，退出程序"
            exit 1
        fi
        _green "$package_name tried to install"
        _green "$package_name 已尝试安装"
    fi
}

check_haveged() {
    _yellow "checking haveged"
    if ! command -v haveged >/dev/null 2>&1; then
        apt-get install -o Dpkg::Options::="--force-confnew" -y haveged
    fi
    if which systemctl >/dev/null 2>&1; then
        systemctl disable --now haveged
        systemctl enable --now haveged
    else
        service haveged stop
        service haveged start
    fi
}

check_time_zone() {
    _yellow "adjusting the time"
    systemctl stop ntpd
    service ntpd stop
    if ! command -v chronyd >/dev/null 2>&1; then
        apt-get install -o Dpkg::Options::="--force-confnew" -y chrony
    fi
    if which systemctl >/dev/null 2>&1; then
        systemctl stop chronyd
        chronyd -q
        systemctl start chronyd
    else
        service chronyd stop
        chronyd -q
        service chronyd start
    fi
    sleep 0.5
}

rebuild_cloud_init() {
    if [ -f "/etc/cloud/cloud.cfg" ]; then
        chattr -i /etc/cloud/cloud.cfg
        if grep -q "preserve_hostname: true" "/etc/cloud/cloud.cfg"; then
            :
        else
            sed -E -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' "/etc/cloud/cloud.cfg"
            echo "change preserve_hostname to true"
        fi
        if grep -q "disable_root: false" "/etc/cloud/cloud.cfg"; then
            :
        else
            sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' "/etc/cloud/cloud.cfg"
            echo "change disable_root to false"
        fi
        chattr -i /etc/cloud/cloud.cfg
        content=$(cat /etc/cloud/cloud.cfg)
        line_number=$(grep -n "^system_info:" "/etc/cloud/cloud.cfg" | cut -d ':' -f 1)
        if [ -n "$line_number" ]; then
            lines_after_system_info=$(echo "$content" | sed -n "$((line_number + 1)),\$p")
            if [ -n "$lines_after_system_info" ]; then
                updated_content=$(echo "$content" | sed "$((line_number + 1)),\$d")
                echo "$updated_content" >"/etc/cloud/cloud.cfg"
            fi
        fi
        sed -i '/^\s*- set-passwords/s/^/#/' /etc/cloud/cloud.cfg
        chattr +i /etc/cloud/cloud.cfg
    fi
}

remove_source_input() {
    # 去除引用
    if [ -f "/etc/network/interfaces" ]; then
        chattr -i /etc/network/interfaces
        if ! grep -q '^#source \/etc\/network\/interfaces\.d\/' "/etc/network/interfaces"; then
            sed -i '/^source \/etc\/network\/interfaces\.d\// { /^#/! s/^/#/ }' "/etc/network/interfaces"
        fi
        if ! grep -q '^#source-directory \/etc\/network\/interfaces\.d' "/etc/network/interfaces"; then
            sed -i 's/^source-directory \/etc\/network\/interfaces\.d/#source-directory \/etc\/network\/interfaces.d/' "/etc/network/interfaces"
        fi
        chattr +i /etc/network/interfaces
    fi
    if [ -f "/etc/network/interfaces.new" ]; then
        chattr -i /etc/network/interfaces.new
        if ! grep -q '^#source \/etc\/network\/interfaces\.d\/' "/etc/network/interfaces.new"; then
            sed -i '/^source \/etc\/network\/interfaces\.d\// { /^#/! s/^/#/ }' "/etc/network/interfaces.new"
        fi
        if ! grep -q '^#source-directory \/etc\/network\/interfaces\.d' "/etc/network/interfaces.new"; then
            sed -i 's/^source-directory \/etc\/network\/interfaces\.d/#source-directory \/etc\/network\/interfaces.d/' "/etc/network/interfaces.new"
        fi
        chattr +i /etc/network/interfaces.new
    fi
}

rebuild_interfaces() {
    # 修复部分网络加载没实时加载
    if [[ -f "/etc/network/interfaces.new" && -f "/etc/network/interfaces" ]]; then
        chattr -i /etc/network/interfaces
        cp -f /etc/network/interfaces.new /etc/network/interfaces
        chattr +i /etc/network/interfaces
    fi
    # 检测回环是否存在，不存在则插入文件的第一第二行
    if ! grep -q "auto lo" "/etc/network/interfaces"; then
        chattr -i /etc/network/interfaces
        # echo "auto lo" >> "/etc/network/interfaces"
        sed -i '1s/^/auto lo\n/' "/etc/network/interfaces"
        chattr +i /etc/network/interfaces
        _blue "Can not find 'auto lo' in /etc/network/interfaces, add it"
    fi
    if ! grep -q "iface lo inet loopback" "/etc/network/interfaces"; then
        chattr -i /etc/network/interfaces
        # echo "iface lo inet loopback" >> "/etc/network/interfaces"
        sed -i '2s/^/iface lo inet loopback\n/' "/etc/network/interfaces"
        chattr +i /etc/network/interfaces
        _blue "Can not find 'iface lo inet loopback' in /etc/network/interfaces, add it"
    fi
    chattr -i /etc/network/interfaces
    echo " " >>/etc/network/interfaces
    chattr +i /etc/network/interfaces
    # 合并文件
    if [ -d "/etc/network/interfaces.d/" ]; then
        if [ ! -f "/etc/network/interfaces" ]; then
            touch /etc/network/interfaces
        fi
        if grep -q '^source \/etc\/network\/interfaces\.d\/' "/etc/network/interfaces" || grep -q '^source-directory \/etc\/network\/interfaces\.d' "/etc/network/interfaces"; then
            chattr -i /etc/network/interfaces
            for file in /etc/network/interfaces.d/*; do
                if [ -f "$file" ]; then
                    cat "$file" >>/etc/network/interfaces
                    chattr -i "$file"
                    rm "$file"
                fi
            done
            chattr +i /etc/network/interfaces
        else
            for file in /etc/network/interfaces.d/*; do
                if [ -f "$file" ]; then
                    chattr -i "$file"
                    rm "$file"
                fi
            done
        fi
    fi
    if [ -d "/run/network/interfaces.d/" ]; then
        if [ ! -f "/etc/network/interfaces" ]; then
            touch /etc/network/interfaces
        fi
        if grep -q '^source \/run\/network\/interfaces\.d\/' "/etc/network/interfaces" || grep -q '^source-directory \/run\/network\/interfaces\.d' "/etc/network/interfaces"; then
            chattr -i /etc/network/interfaces
            for file in /run/network/interfaces.d/*; do
                if [ -f "$file" ]; then
                    cat "$file" >>/etc/network/interfaces
                    chattr -i "$file"
                    rm "$file"
                fi
            done
            chattr +i /etc/network/interfaces
        else
            for file in /run/network/interfaces.d/*; do
                if [ -f "$file" ]; then
                    chattr -i "$file"
                    rm "$file"
                fi
            done
        fi
    fi
    # 修复部分网络运行部分未空
    if [ ! -e /run/network/interfaces.d/* ]; then
        if [ -f "/etc/network/interfaces" ]; then
            chattr -i /etc/network/interfaces
            if ! grep -q "^#.*source-directory \/run\/network\/interfaces\.d" /etc/network/interfaces; then
                sed -i '/source-directory \/run\/network\/interfaces.d/s/^/#/' /etc/network/interfaces
            fi
            chattr +i /etc/network/interfaces
        fi
        if [ -f "/etc/network/interfaces.new" ]; then
            chattr -i /etc/network/interfaces.new
            if ! grep -q "^#.*source-directory \/run\/network\/interfaces\.d" /etc/network/interfaces.new; then
                sed -i '/source-directory \/run\/network\/interfaces.d/s/^/#/' /etc/network/interfaces.new
            fi
            chattr +i /etc/network/interfaces.new
        fi
    fi
    # 去除引用
    remove_source_input
    # 检查/etc/network/interfaces文件中是否有iface xxxx inet auto行
    if [ -f "/etc/network/interfaces" ]; then
        if grep -q "iface $interface inet auto" /etc/network/interfaces; then
            chattr -i /etc/network/interfaces
            if [[ -z "${CN}" || "${CN}" != true ]]; then
                sed -i "/iface $interface inet auto/c\
                iface $interface inet static\n\
                address $ipv4_address\n\
                netmask $ipv4_subnet\n\
                gateway $ipv4_gateway\n\
                dns-nameservers 8.8.8.8 8.8.4.4" /etc/network/interfaces
            else
                sed -i "/iface $interface inet auto/c\
                iface $interface inet static\n\
                address $ipv4_address\n\
                netmask $ipv4_subnet\n\
                gateway $ipv4_gateway\n\
                dns-nameservers 8.8.8.8 223.5.5.5" /etc/network/interfaces
            fi
        fi
        chattr +i /etc/network/interfaces
    fi
    # 检查/etc/network/interfaces文件中是否有iface xxxx inet dhcp行
    if [[ $dmidecode_output == *"Hetzner_vServer"* ]] || [[ $dmidecode_output == *"Microsoft Corporation"* ]]; then
        if [ -f "/etc/network/interfaces" ]; then
            if grep -qF "inet dhcp" /etc/network/interfaces; then
                inet_dhcp=true
            else
                inet_dhcp=false
            fi
            if grep -q "iface $interface inet dhcp" /etc/network/interfaces; then
                chattr -i /etc/network/interfaces
                if [[ -z "${CN}" || "${CN}" != true ]]; then
                    sed -i "/iface $interface inet dhcp/c\
                    iface $interface inet static\n\
                    address $ipv4_address\n\
                    netmask $ipv4_subnet\n\
                    gateway $ipv4_gateway\n\
                    dns-nameservers 8.8.8.8 8.8.4.4" /etc/network/interfaces
                else
                    sed -i "/iface $interface inet dhcp/c\
                    iface $interface inet static\n\
                    address $ipv4_address\n\
                    netmask $ipv4_subnet\n\
                    gateway $ipv4_gateway\n\
                    dns-nameservers 8.8.8.8 223.5.5.5" /etc/network/interfaces
                fi
            fi
            chattr +i /etc/network/interfaces
        fi
    fi
    # 检测物理接口是否已auto链接
    if ! grep -q "auto ${interface}" /etc/network/interfaces; then
        chattr -i /etc/network/interfaces
        echo "auto ${interface}" >>/etc/network/interfaces
        chattr +i /etc/network/interfaces
    fi
    # 反加载
    if [[ -f "/etc/network/interfaces.new" && -f "/etc/network/interfaces" ]]; then
        chattr -i /etc/network/interfaces.new
        cp -f /etc/network/interfaces /etc/network/interfaces.new
        chattr +i /etc/network/interfaces.new
    fi
}

fix_interfaces_ipv6_auto_type() {
    chattr -i /etc/network/interfaces
    while IFS= read -r line; do
        # 检测以 "iface" 开头且包含 "inet6 auto" 的行
        if [[ $line == "iface ${interface} inet6 auto" ]]; then
            output=$(ip addr)
            matches=$(echo "$output" | grep "inet6.*global dynamic")
            if [ -n "$matches" ]; then
                # SLAAC动态分配，暂不做IPV6的处理
                sed -i "/iface $interface inet6 auto/d" /etc/network/interfaces
                echo "$interface" >"/usr/local/bin/iface_auto.txt"
            else
                # 将 "auto" 替换为 "static"
                modified_line="${line/auto/static}"
                echo "$modified_line"
                # 添加静态IPv6配置信息
                echo "    address ${ipv6_address}/${ipv6_prefixlen}"
                echo "    gateway ${ipv6_gateway}"
            fi
        else
            echo "$line"
        fi
    done </etc/network/interfaces >/tmp/interfaces.modified
    chattr -i /etc/network/interfaces
    mv -f /tmp/interfaces.modified /etc/network/interfaces
    chattr +i /etc/network/interfaces
    rm -rf /tmp/interfaces.modified
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

check_ipv6() {
    IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
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

prebuild_ifupdown2() {
    if [ ! -f "/usr/local/bin/ifupdown2_installed.txt" ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/extra_scripts/install_ifupdown2.sh -O /usr/local/bin/install_ifupdown2.sh
        wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/extra_scripts/ifupdown2-install.service -O /etc/systemd/system/ifupdown2-install.service
        chmod 777 /usr/local/bin/install_ifupdown2.sh
        chmod 777 /etc/systemd/system/ifupdown2-install.service
        if [ -f "/usr/local/bin/install_ifupdown2.sh" ]; then
            # _green "This script will automatically reboot the system after 5 seconds, please wait a few minutes to log into SSH and execute this script again"
            # _green "本脚本将在5秒后自动重启系统，请待几分钟后退出SSH再次执行本脚本"
            systemctl daemon-reload
            systemctl enable ifupdown2-install.service
            # sleep 5
            # echo "1" > "/usr/local/bin/reboot_pve.txt"
            # systemctl start ifupdown2-install.service
        fi
    fi
}

is_private_ipv4() {
    local ip_address=$1
    local ip_parts
    if [[ -z $ip_address ]]; then
        return 0 # 输入为空
    fi
    IFS='.' read -r -a ip_parts <<<"$ip_address"
    # 检查IP地址是否符合内网IP地址的范围
    # 去除 回环，RFC 1918，多播，RFC 6598 地址
    if [[ ${ip_parts[0]} -eq 10 ]] ||
        [[ ${ip_parts[0]} -eq 172 && ${ip_parts[1]} -ge 16 && ${ip_parts[1]} -le 31 ]] ||
        [[ ${ip_parts[0]} -eq 192 && ${ip_parts[1]} -eq 168 ]] ||
        [[ ${ip_parts[0]} -eq 127 ]] ||
        [[ ${ip_parts[0]} -eq 0 ]] ||
        [[ ${ip_parts[0]} -eq 100 && ${ip_parts[1]} -ge 64 && ${ip_parts[1]} -le 127 ]] ||
        [[ ${ip_parts[0]} -ge 224 ]]; then
        return 0 # 是内网IP地址
    else
        return 1 # 不是内网IP地址
    fi
}

check_ipv4() {
    IPV4=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    if is_private_ipv4 "$IPV4"; then # 由于是内网IPV4地址，需要通过API获取外网地址
        IPV4=""
        local API_NET=("ipv4.ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
        for p in "${API_NET[@]}"; do
            response=$(curl -s4m8 "$p")
            sleep 1
            if [ $? -eq 0 ] && ! echo "$response" | grep -q "error"; then
                IP_API="$p"
                IPV4="$response"
                break
            fi
        done
    fi
    export IPV4
}

statistics_of_run-times() {
    COUNT=$(
        curl -4 -ksm1 "https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2FspiritLHLS%2Fpve&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=&edge_flat=true" 2>&1 ||
            curl -6 -ksm1 "https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2FspiritLHLS%2Fpve&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=&edge_flat=true" 2>&1
    ) &&
        TODAY=$(expr "$COUNT" : '.*\s\([0-9]\{1,\}\)\s/.*') && TOTAL=$(expr "$COUNT" : '.*/\s\([0-9]\{1,\}\)\s.*')
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
        system_arch="arch"
        ;;
    *)
        system_arch=""
        ;;
    esac
}

check_china() {
    _yellow "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            _yellow "根据ipapi.co提供的信息，当前IP可能在中国"
            read -e -r -p "是否选用中国镜像完成相关组件安装? ([y]/n) " input
            case $input in
            [yY][eE][sS] | [yY])
                echo "使用中国镜像"
                CN=true
                ;;
            [nN][oO] | [nN])
                echo "不使用中国镜像"
                ;;
            *)
                echo "使用中国镜像"
                CN=true
                ;;
            esac
        else
            if [[ $? -ne 0 ]]; then
                if [[ $(curl -m 6 -s cip.cc) =~ "中国" ]]; then
                    _yellow "根据cip.cc提供的信息，当前IP可能在中国"
                    read -e -r -p "是否选用中国镜像完成相关组件安装? [Y/n] " input
                    case $input in
                    [yY][eE][sS] | [yY])
                        echo "使用中国镜像"
                        CN=true
                        ;;
                    [nN][oO] | [nN])
                        echo "不使用中国镜像"
                        ;;
                    *)
                        echo "不使用中国镜像"
                        ;;
                    esac
                fi
            fi
        fi
    fi
}

change_debian_apt_sources() {
    DEBIAN_VERSION=$(lsb_release -sr)
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        URL="http://deb.debian.org/debian"
    else
        # Use mirrors.aliyun.com sources list if IP is in China
        URL="http://mirrors.aliyun.com/debian"
    fi

    case $DEBIAN_VERSION in
    6*) DEBIAN_RELEASE="squeeze" ;;
    7*) DEBIAN_RELEASE="wheezy" ;;
    8*) DEBIAN_RELEASE="jessie" ;;
    9*) DEBIAN_RELEASE="stretch" ;;
    10*) DEBIAN_RELEASE="buster" ;;
    11*) DEBIAN_RELEASE="bullseye" ;;
    12*) DEBIAN_RELEASE="bookworm" ;;
    *) echo "The system is not Debian 6/7/8/9/10/11/12 . No changes were made to the apt-get sources." && return 1 ;;
    esac

    cat >/etc/apt/sources.list <<EOF
deb ${URL} ${DEBIAN_RELEASE} main contrib non-free
deb ${URL} ${DEBIAN_RELEASE}-updates main contrib non-free
deb ${URL} ${DEBIAN_RELEASE}-backports main contrib non-free
deb-src ${URL} ${DEBIAN_RELEASE} main contrib non-free
deb-src ${URL} ${DEBIAN_RELEASE}-updates main contrib non-free
deb-src ${URL} ${DEBIAN_RELEASE}-backports main contrib non-free
EOF
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

########## 前置环境检测和组件安装

# 更改网络优先级为IPV4优先
sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf

# ChinaIP检测
check_china

# cdn检测
cdn_urls=("https://cdn.spiritlhl.workers.dev/" "https://cdn3.spiritlhl.net/" "https://cdn1.spiritlhl.net/" "https://ghproxy.com/" "https://cdn2.spiritlhl.net/")
check_cdn_file

systemctl restart networking 
if [ $? -ne 0 ]; then
    # altname=$(ip addr show eth0 | grep altname | awk '{print $NF}')
    if [ -f /etc/network/interfaces ] && grep -q "eth0" /etc/network/interfaces; then
        chattr -i /etc/network/interfaces
        sed -i '/^auto ens[0-9]\+$/d' /etc/network/interfaces
        sed -i '/^allow-hotplug ens[0-9]\+$/d' /etc/network/interfaces
        sed -i '/^iface ens[0-9]\+ inet/d' /etc/network/interfaces
        chattr +i /etc/network/interfaces
    fi
fi
systemctl restart networking
if [ $? -ne 0 ]; then
    if [ ! -f "/usr/local/bin/clear_interface_route_cache.sh" ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/extra_scripts/clear_interface_route_cache.sh -O /usr/local/bin/clear_interface_route_cache.sh
        wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/extra_scripts/clear_interface_route_cache.service -O /etc/systemd/system/clear_interface_route_cache.service
        chmod +x /usr/local/bin/clear_interface_route_cache.sh
        chmod +x /etc/systemd/system/clear_interface_route_cache.service
        systemctl daemon-reload
        systemctl enable clear_interface_route_cache.service
        _green "An anomaly was detected with the routing conflict, perform a reboot to reboot the machine to start the repaired daemon and try the installation again."
        _green "检测到路由冲突存在异常，请执行 reboot 重启机器以启动修复的守护进程，再次尝试安装"
        exit 1
    fi
fi

# 前置环境安装与配置
if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root"
    exit 1
fi
get_system_arch
if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
    _red "This script can only run on machines under x86_64 or arm architecture."
    exit 1
fi
if [ "$system_arch" = "arch" ]; then
    systemctl disable NetworkManager
    systemctl stop NetworkManager
fi
if [ ! -f "/usr/local/bin/check-dns.sh" ]; then
    wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/extra_scripts/check-dns.sh -O /usr/local/bin/check-dns.sh
    wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/extra_scripts/check-dns.service -O /etc/systemd/system/check-dns.service
    chmod +x /usr/local/bin/check-dns.sh
    chmod +x /etc/systemd/system/check-dns.service
    systemctl daemon-reload
    systemctl enable check-dns.service
    systemctl start check-dns.service
fi

# 确保apt没有问题
apt-get update -y
apt-get full-upgrade -y
if [ $? -ne 0 ]; then
    apt-get install debian-keyring debian-archive-keyring -y
    apt-get update -y && apt-get full-upgrade -y
fi
apt_update_output=$(apt-get update 2>&1)
echo "$apt_update_output" >"$temp_file_apt_fix"
if grep -q 'NO_PUBKEY' "$temp_file_apt_fix"; then
    public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file_apt_fix" | awk '{ print $2 }')
    joined_keys=$(echo "$public_keys" | paste -sd " ")
    _yellow "No Public Keys: ${joined_keys}"
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${joined_keys}
    apt-get update
    if [ $? -eq 0 ]; then
        _green "Fixed"
    fi
fi
rm "$temp_file_apt_fix"
apt-get update -y
if [ $? -ne 0 ]; then
    change_debian_apt_sources
    apt-get update -y
fi
systemctl daemon-reload

# 检测路径
target_paths="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
for path in $(echo $target_paths | tr ':' ' '); do
    if ! echo $PATH | grep -q "$path"; then
        echo "路径 $path 不在PATH中，将被添加."
        export PATH="$PATH:$path"
    fi
done
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi

# 部分安装包提前安装
install_package wget
install_package curl
install_package sudo
install_package bc
install_package iptables
install_package lshw
install_package net-tools
install_package service
install_package ipcalc
install_package dmidecode
install_package dnsutils
install_package ethtool
apt-get install gnupg -y
apt-get install iputils-ping -y
apt-get install iproute2 -y
apt-get install lsb-release -y
ethtool_path=$(which ethtool)
check_haveged

# 预检查
if [ ! -f /etc/debian_version ] || [ $(grep MemTotal /proc/meminfo | awk '{print $2}') -lt 2000000 ] || [ $(grep -c ^processor /proc/cpuinfo) -lt 2 ] || [ $(
    ping -c 3 google.com >/dev/null 2>&1
    echo $?
) -ne 0 ]; then
    _red "Error: This system does not meet the minimum requirements for Proxmox VE installation."
    _yellow "Do you want to continue the installation? (Enter to not continue the installation by default) (y/[n])"
    reading "是否要继续安装？(回车则默认不继续安装) (y/[n]) " confirm
    echo ""
    if [ "$confirm" != "y" ]; then
        exit 1
    fi
else
    _green "The system meets the minimum requirements for Proxmox VE installation."
fi

# 检测系统信息
_yellow "Detecting system information, will probably stay on the page for up to 1~2 minutes"
_yellow "正在检测系统信息，大概会停留在该页面最多1~2分钟"

# 检测主IPV4相关信息
if [ ! -f /usr/local/bin/pve_main_ipv4 ]; then
    main_ipv4=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    echo "$main_ipv4" >/usr/local/bin/pve_main_ipv4
fi
# 提取主IPV4地址
main_ipv4=$(cat /usr/local/bin/pve_main_ipv4)
if [ ! -f /usr/local/bin/pve_ipv4_address ]; then
    ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p')
    echo "$ipv4_address" >/usr/local/bin/pve_ipv4_address
fi
# 提取IPV4地址 含子网长度
ipv4_address=$(cat /usr/local/bin/pve_ipv4_address)
if [ ! -f /usr/local/bin/pve_ipv4_gateway ]; then
    ipv4_gateway=$(ip route | awk '/default/ {print $3}' | sed -n '1p')
    echo "$ipv4_gateway" >/usr/local/bin/pve_ipv4_gateway
fi
# 提取IPV4网关
ipv4_gateway=$(cat /usr/local/bin/pve_ipv4_gateway)
if [ ! -f /usr/local/bin/pve_ipv4_subnet ]; then
    ipv4_subnet=$(ipcalc -n "$ipv4_address" | grep -oP 'Netmask:\s+\K.*' | awk '{print $1}')
    echo "$ipv4_subnet" >/usr/local/bin/pve_ipv4_subnet
fi
# 提取Netmask
ipv4_subnet=$(cat /usr/local/bin/pve_ipv4_subnet)

# 检测物理接口和MAC地址
interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
check_interface
# if [ "$system_arch" = "arch" ]; then
#     mac_address=$(ip -o link show dev ${interface} | awk '{print $17}')
# fi

# 检测IPV6相关的信息
if [ ! -f /usr/local/bin/pve_check_ipv6 ] || [ ! -s /usr/local/bin/pve_check_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_check_ipv6)" = "" ]; then
    check_ipv6
fi
if [ ! -f /usr/local/bin/pve_ipv6_prefixlen ] || [ ! -s /usr/local/bin/pve_ipv6_prefixlen ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_ipv6_prefixlen)" = "" ]; then
    ipv6_prefixlen=$(ifconfig ${interface} | grep -oP 'prefixlen \K\d+' | head -n 1)
    echo "$ipv6_prefixlen" >/usr/local/bin/pve_ipv6_prefixlen
fi
if [ ! -f /usr/local/bin/pve_ipv6_gateway ] || [ ! -s /usr/local/bin/pve_ipv6_gateway ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_ipv6_gateway)" = "" ]; then
    ipv6_gateway=$(ip -6 route show | awk '/default via/{print $3}' | head -n1)
    # if [[ "${ipv6_gateway: -2}" == "::" ]]; then
    #     ipv6_gateway="${ipv6_gateway}0000"
    # fi
    echo "$ipv6_gateway" >/usr/local/bin/pve_ipv6_gateway
fi
ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
if ping -c 1 -6 -W 3 $ipv6_address >/dev/null 2>&1; then
    echo "IPv6 address is reachable."
else
    echo "IPv6 address is not reachable. Setting to empty."
    echo "" >/usr/local/bin/pve_check_ipv6
fi
if ping -c 1 -6 -W 3 $ipv6_gateway >/dev/null 2>&1; then
    echo "IPv6 gateway is reachable."

else
    echo "IPv6 gateway is not reachable. Setting to empty."
    echo "" >/usr/local/bin/pve_ipv6_gateway
fi
ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)

# 检查50-cloud-init是否存在特定配置
if [ -f "/etc/network/interfaces.d/50-cloud-init" ]; then
    if grep -Fxq "# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with the following:" /etc/network/interfaces.d/50-cloud-init && grep -Fxq "# network: {config: disabled}" /etc/network/interfaces.d/50-cloud-init; then
        if [ ! -f "/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" ]; then
            echo "Creating /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg."
            echo "network: {config: disabled}" >/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
        fi
    fi
fi

# 特殊化处理各虚拟化
if [ ! -f "/etc/network/interfaces" ]; then
    touch "/etc/network/interfaces"
    chattr -i /etc/network/interfaces
    echo "auto lo" >>/etc/network/interfaces
    echo "iface lo inet loopback" >>/etc/network/interfaces
    echo "iface $interface inet static" >>/etc/network/interfaces
    echo "    address $ipv4_address" >>/etc/network/interfaces
    echo "    netmask $ipv4_subnet" >>/etc/network/interfaces
    echo "    gateway $ipv4_gateway" >>/etc/network/interfaces
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        echo "    dns-nameservers 8.8.8.8 8.8.4.4" >>/etc/network/interfaces
    else
        echo "    dns-nameservers 8.8.8.8 223.5.5.5" >>/etc/network/interfaces
    fi
    chattr +i /etc/network/interfaces
fi

# 网络配置修改
dmidecode_output=$(dmidecode -t system)
rebuild_interfaces
# 去除空行之外的重复行
remove_duplicate_lines "/etc/network/interfaces"
if [ -f "/etc/network/interfaces.new" ]; then
    remove_duplicate_lines "/etc/network/interfaces.new"
fi
# 删除可能的多个dns-nameservers的行只保留一行
dns_lines=$(grep -c "dns-nameservers" /etc/network/interfaces)
if [ $dns_lines -gt 1 ]; then
    rm -rf /tmp/interfaces.tmp
    original_lines=$(wc -l </etc/network/interfaces)
    current_dns_lines=0
    while read -r line; do
        if echo "$line" | grep -q "dns-nameservers"; then
            current_dns_lines=$((current_dns_lines + 1))
            if [ $current_dns_lines -lt $dns_lines ]; then
                continue
            fi
        fi
        echo "$line" >>/tmp/interfaces.tmp
    done </etc/network/interfaces
    chattr -i /etc/network/interfaces
    mv /tmp/interfaces.tmp /etc/network/interfaces
    chattr +i /etc/network/interfaces
    rm -rf /tmp/interfaces.tmp
fi

# 当v6是共存的类型时删除v6
if grep -q "iface ${interface} inet6 manual" /etc/network/interfaces && grep -q "try_dhcp 1" /etc/network/interfaces; then
    chattr -i /etc/network/interfaces
    # sed -i 's/iface ${interface} inet6 manual/iface ${interface} inet6 dhcp/' /etc/network/interfaces
    sed -i '/iface ${interface} inet6 manual/d' /etc/network/interfaces
    sed -i '/try_dhcp 1/d' /etc/network/interfaces
    chattr +i /etc/network/interfaces
fi

# cloudinit 重构
rebuild_cloud_init
fix_interfaces_ipv6_auto_type

# 统计运行次数
statistics_of_run-times

# 检测是否已重启过
if [ ! -f "/usr/local/bin/reboot_pve.txt" ]; then
    # 确保时间没问题
    check_time_zone
    # 特殊处理Azure
    if [[ $dmidecode_output == *"Microsoft Corporation"* ]]; then
        sed -i 's#http://debian-archive.trafficmanager.net/debian#http://deb.debian.org/debian#g' /etc/apt/sources.list
        sed -i 's#http://debian-archive.trafficmanager.net/debian-security#http://security.debian.org/debian-security#g' /etc/apt/sources.list
        sed -i 's#http://debian-archive.trafficmanager.net/debian bullseye-updates#http://deb.debian.org/debian bullseye-updates#g' /etc/apt/sources.list
        sed -i 's#http://debian-archive.trafficmanager.net/debian bullseye-backports#http://deb.debian.org/debian bullseye-backports#g' /etc/apt/sources.list
        # if [[ "${inet_dhcp}" == true ]]; then
        #     # 特殊处理原有配置是dhcp的情况
        #     prebuild_ifupdown2
        # fi
    fi
    if [[ $dmidecode_output == *"Hetzner_vServer"* ]] || [[ $dmidecode_output == *"Exoscale Compute Platform"* ]] || ! dpkg -S ifupdown; then
        prebuild_ifupdown2
    fi
    # # 特殊处理OVH
    # if dig -x $main_ipv4 | grep -q "vps.ovh"; then
    #     prebuild_ifupdown2
    # fi
    echo "1" >"/usr/local/bin/reboot_pve.txt"
    _green "Please execute reboot to reboot the system and then execute this script again"
    _green "Please wait for at least 20 seconds without automatically rebooting the system before executing this script."
    _green "请执行 reboot 重启系统后再次执行本脚本，再次使用SSH登录后请等待至少20秒未自动重启系统再执行本脚本"
    exit 1
fi

########## 正式开始PVE相关配置文件修改

# 如果是CN的IP则增加DNS先
if [[ "${CN}" == true ]]; then
    echo "nameserver 223.5.5.5" >>/etc/resolv.conf
fi

# cloud-init文件修改
rebuild_cloud_init

# /etc/hosts文件修改
hostname=$(hostname)
if [ "${hostname}" != "pve" ]; then
    chattr -i /etc/hosts
    hosts=$(grep -E "^[^#]*\s+${hostname}\s+${hostname}\$" /etc/hosts | grep -v "${main_ipv4}")
    if [ -n "${hosts}" ]; then
        # 注释掉查询到的行
        sudo sed -i "s/^$(echo ${hosts} | sed 's/\//\\\//g')/# &/" /etc/hosts
        # 添加新行
        # echo "${main_ipv4} ${hostname} ${hostname}" | sudo tee -a /etc/hosts > /dev/null
        # _green "已将 ${main_ipv4} ${hostname} ${hostname} 添加到 /etc/hosts 文件中"
    else
        _blue "A record for ${main_ipv4} ${hostname} ${hostname} already exists, no need to add it"
        _blue "已存在 ${main_ipv4} ${hostname} ${hostname} 的记录，无需添加"
    fi
    chattr -i /etc/hostname
    hostnamectl set-hostname pve
    chattr +i /etc/hostname
    hostname=$(hostname)
    if ! grep -q "::1 localhost" /etc/hosts; then
        echo "::1 localhost" >>/etc/hosts
        echo "Added ::1 localhost to /etc/hosts"
    fi
    if grep -q "^127\.0\.1\.1" /etc/hosts; then
        sed -i '/^127\.0\.1\.1/s/^/#/' /etc/hosts
        echo "Commented out lines starting with 127.0.1.1 in /etc/hosts"
    fi
    if ! grep -q "^127\.0\.0\.1 localhost\.localdomain localhost$" /etc/hosts; then
        # 127.0.1.1
        echo "${main_ipv4} ${hostname}.localdomain ${hostname}" >>/etc/hosts
        echo "Added ${main_ipv4} ${hostname}.localdomain ${hostname} to /etc/hosts"
    fi
    chattr +i /etc/hosts
fi

# 新增pve源
version=$(lsb_release -cs)
# 如果是CN的IP则修改apt源先
if [[ "${CN}" == true ]]; then
    rm /etc/apt/sources.list
    echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${version} main contrib non-free" >>/etc/apt/sources.list
    echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${version}-updates main contrib non-free" >>/etc/apt/sources.list
    echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${version}-backports main contrib non-free" >>/etc/apt/sources.list
    echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian-security ${version}-security main contrib non-free" >>/etc/apt/sources.list
fi
if [ "$system_arch" = "x86" ]; then
    case $version in
    stretch | buster | bullseye | bookworm)
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            repo_url="deb http://download.proxmox.com/debian/pve ${version} pve-no-subscription"
        else
            repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve ${version} pve-no-subscription"
        fi
        ;;
    # bookworm)
    #   repo_url="deb http://download.proxmox.com/debian/pve ${version} pvetest"
    #   if [[ -n "${CN}" ]]; then
    #     repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve ${version} pvetest"
    #   fi
    #   ;;
    *)
        _red "Error: Unsupported Debian version"
        _yellow "Do you want to continue the installation? (Enter to not continue the installation by default) (y/[n])"
        reading "是否要继续安装(识别到不是Debian9~Debian12的范围)？(回车则默认不继续安装) (y/[n]) " confirm
        echo ""
        if [ "$confirm" != "y" ]; then
            exit 1
        fi
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            repo_url="deb http://download.proxmox.com/debian/pve bullseye pve-no-subscription"
        else
            repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve bullseye pve-no-subscription"
        fi
        ;;
    esac
    case $version in
    stretch)
        if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-4.x.gpg" ]; then
            wget http://download.proxmox.com/debian/proxmox-ve-release-4.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-4.x.gpg
            chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-4.x.gpg
        fi
        if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg" ]; then
            wget http://download.proxmox.com/debian/proxmox-ve-release-6.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
            chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
        fi
        ;;
    buster)
        if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-5.x.gpg" ]; then
            wget http://download.proxmox.com/debian/proxmox-ve-release-5.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-5.x.gpg
            chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-5.x.gpg
        fi
        if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg" ]; then
            wget http://download.proxmox.com/debian/proxmox-ve-release-6.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
            chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
        fi
        ;;
    bullseye)
        if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg" ]; then
            wget http://download.proxmox.com/debian/proxmox-ve-release-6.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
            chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
        fi
        if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg" ]; then
            wget http://download.proxmox.com/debian/proxmox-release-bullseye.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
            chmod +r /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
        fi
        ;;
    bookworm)
        if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg" ]; then
            wget http://download.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
            chmod +r /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
        fi
        ;;
    *)
        _red "Error: Unsupported Debian version"
        _yellow "Do you want to continue the installation? (Enter to not continue the installation by default) (y/[n])"
        reading "是否要继续安装(识别到不是Debian9~Debian12的范围)？(回车则默认不继续安装) (y/[n]) " confirm
        echo ""
        if [ "$confirm" != "y" ]; then
            exit 1
        fi
        ;;
    esac
    if ! grep -q "^deb.*pve-no-subscription" /etc/apt/sources.list; then
        echo "$repo_url" >>/etc/apt/sources.list
    fi
elif [ "$system_arch" = "arch" ]; then
    case $version in
    stretch | buster | bullseye)
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            echo "deb https://global.mirrors.apqa.cn/proxmox/debian/pve bullseye port" >/etc/apt/sources.list.d/pveport.list
        else
            echo "deb https://mirrors.apqa.cn/proxmox/debian/pve bullseye port" >/etc/apt/sources.list.d/pveport.list
        fi
        ;;
    bookworm)
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            echo "deb https://global.mirrors.apqa.cn/proxmox/debian/pve bookworm port" >/etc/apt/sources.list.d/pveport.list
        else
            echo "deb https://mirrors.apqa.cn/proxmox/debian/pve bookworm port" >/etc/apt/sources.list.d/pveport.list
        fi
        ;;
    *)
        _red "Error: Unsupported Debian version"
        _yellow "Do you want to continue the installation? (Enter to not continue the installation by default) (y/[n])"
        reading "是否要继续安装(识别到不是Debian9~Debian12的范围)？(回车则默认不继续安装) (y/[n]) " confirm
        echo ""
        if [ "$confirm" != "y" ]; then
            exit 1
        fi
        echo "deb https://global.mirrors.apqa.cn/proxmox/debian/pve bullseye port" >/etc/apt/sources.list.d/pveport.list
        ;;
    esac
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        curl https://global.mirrors.apqa.cn/proxmox/debian/pveport.gpg -o /etc/apt/trusted.gpg.d/pveport.gpg
    else
        curl https://mirrors.apqa.cn/proxmox/debian/pveport.gpg -o /etc/apt/trusted.gpg.d/pveport.gpg
    fi
fi
rebuild_interfaces

# 确保apt没有问题
apt-get update -y && apt-get full-upgrade -y
if [ $? -ne 0 ]; then
    apt-get install debian-keyring debian-archive-keyring -y
    apt-get update -y && apt-get full-upgrade -y
fi
apt_update_output=$(apt-get update 2>&1)
echo "$apt_update_output" >"$temp_file_apt_fix"
if grep -q 'NO_PUBKEY' "$temp_file_apt_fix"; then
    public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file_apt_fix" | awk '{ print $2 }')
    joined_keys=$(echo "$public_keys" | paste -sd " ")
    _yellow "No Public Keys: ${joined_keys}"
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${joined_keys}
    apt-get update
    if [ $? -eq 0 ]; then
        _green "Fixed"
    fi
fi
rm "$temp_file_apt_fix"
output=$(apt-get update 2>&1)
if echo $output | grep -q "NO_PUBKEY"; then
    _yellow "try sudo apt-key adv --keyserver keyserver.ubuntu.com --recvrebuild_interface-keys missing key"
    exit 1
fi

# 修复网卡可能存在的auto类型
rebuild_interfaces
fix_interfaces_ipv6_auto_type

# 特殊处理Hetzner和Azure的情况
if [[ $dmidecode_output == *"Hetzner_vServer"* ]] || [[ $dmidecode_output == *"Microsoft Corporation"* ]] || [[ $dmidecode_output == *"Exoscale Compute Platform"* ]]; then
    auto_interface=$(grep '^auto ' /etc/network/interfaces | grep -v '^auto lo' | awk '{print $2}' | head -n 1)
    if ! grep -q "^post-up ${ethtool_path}" /etc/network/interfaces; then
        chattr -i /etc/network/interfaces
        echo "post-up ${ethtool_path} -K $auto_interface tx off rx off" >>/etc/network/interfaces
        chattr +i /etc/network/interfaces
    fi
fi

# 检测IPV6是不是启用了dhcp但未分配IPV6地址
if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
    if [ -f /etc/network/if-pre-up.d/cloud_inet6 ]; then
        rm -rf /etc/network/if-pre-up.d/cloud_inet6
    fi
    chattr -i /etc/network/interfaces
    sed -i '/iface ens4 inet6 \(manual\|dhcp\)/d' /etc/network/interfaces
    chattr +i /etc/network/interfaces
fi

# 部分机器中途service丢失了，尝试修复
install_package service

# 正式安装PVE
install_package proxmox-ve
install_package postfix
install_package open-iscsi
rebuild_interfaces

# 配置vmbr0
chattr -i /etc/network/interfaces
if grep -q "vmbr0" "/etc/network/interfaces"; then
    _blue "vmbr0 already exists in /etc/network/interfaces"
    _blue "vmbr0 已存在在 /etc/network/interfaces"
else
    if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
        cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    address $ipv4_address
    gateway $ipv4_gateway
    bridge_ports $interface
    bridge_stp off
    bridge_fd 0
EOF
    elif [ -f "/usr/local/bin/iface_auto.txt" ]; then
        cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    address $ipv4_address
    gateway $ipv4_gateway
    bridge_ports $interface
    bridge_stp off
    bridge_fd 0

iface vmbr0 inet6 auto
    bridge_ports $interface
EOF
    else
        ipv6_address_without_last_segment="${ipv6_address%:*}:"
        cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    address $ipv4_address
    gateway $ipv4_gateway
    bridge_ports $interface
    bridge_stp off
    bridge_fd 0

iface vmbr0 inet6 static
        address ${ipv6_address_without_last_segment}1/128
        gateway ${ipv6_gateway}
EOF
    fi
fi
chattr +i /etc/network/interfaces

# 如果是国内服务器则替换CT源为国内镜像源
if [ "$system_arch" = "x86" ]; then
    if [[ "${CN}" == true ]]; then
        cp -rf /usr/share/perl5/PVE/APLInfo.pm /usr/share/perl5/PVE/APLInfo.pm.bak
        sed -i 's|http://download.proxmox.com|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
        sed -i 's|http://mirrors.ustc.edu.cn/proxmox|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
    fi
fi

# 确保DNS有效
if [ ! -s "/etc/resolv.conf" ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak
    if [[ "${CN}" == true ]]; then
        if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
            echo -e "nameserver 8.8.8.8\nnameserver 223.5.5.5\n" >/etc/resolv.conf
        else
            echo -e "nameserver 8.8.8.8\nnameserver 223.5.5.5\nnameserver 2001:4860:4860::8888\nnameserver 2001:4860:4860::8844" >/etc/resolv.conf
        fi
    else
        if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
            echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" >/etc/resolv.conf
        else
            echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 2001:4860:4860::8888\nnameserver 2001:4860:4860::8844" >/etc/resolv.conf
        fi
    fi
fi

# 删除可能存在的原有的网卡配置
cp /etc/network/interfaces /etc/network/interfaces_nat.bak
chattr -i /etc/network/interfaces
input_file="/etc/network/interfaces"
output_file="/etc/network/interfaces.tmp"
start_pattern="iface lo inet loopback"
end_pattern="auto vmbr0"
delete_lines=0
while IFS= read -r line; do
    if [[ $line == *"$start_pattern"* ]]; then
        delete_lines=1
    fi
    if [ $delete_lines -eq 0 ] || [[ $line == *"$start_pattern"* ]] || [[ $line == *"$end_pattern"* ]]; then
        echo "$line" >>"$output_file"
    fi
    if [[ $line == *"$end_pattern"* ]]; then
        delete_lines=0
    fi
done <"$input_file"
mv "$output_file" "$input_file"
chattr +i /etc/network/interfaces

# 安装必备模块并替换apt源中的无效订阅
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak
# echo "deb http://download.proxmox.com/debian/pve $(lsb_release -sc) pve-no-subscription" > /etc/apt/sources.list.d/pve-enterprise.list
rm -rf /etc/apt/sources.list.d/pve-enterprise.list
apt-get update
install_package sudo
install_package iproute2
case $version in
stretch)
    install_package ifupdown
    ;;
buster)
    install_package ifupdown2
    ;;
bullseye)
    install_package ifupdown2
    ;;
bookworm)
    install_package ifupdown2
    ;;
*)
    exit 1
    ;;
esac
install_package novnc
install_package cloud-init
rebuild_cloud_init
# install_package isc-dhcp-server
chattr +i /etc/network/interfaces

# 清除防火墙
install_package ufw
ufw disable

########## 打印安装成功的信息

# 查询公网IPV4
check_ipv4

# 打印安装后的信息
url="https://${IPV4}:8006/"

# 打印内核
running_kernel=$(uname -r)
_green "Running kernel: $(pveversion)"
installed_kernels=($(dpkg -l 'pve-kernel-*' | awk '/^ii/ {print $2}' | cut -d'-' -f3- | sort -V))
if [ ${#installed_kernels[@]} -gt 0 ]; then
    latest_kernel=${installed_kernels[-1]}
    _green "PVE latest kernel: $latest_kernel"
fi

_green "Installation complete, please open HTTPS web page $url"
_green "The username and password are the username and password used by the server (e.g. root and root user's password)"
_green "If the login is correct please do not rush to reboot the system, go to execute the commands of the pre-configured environment and then reboot the system"
_green "If there is a problem logging in the web side is not up, wait 10 seconds and restart the system to see"
_green "安装完毕，请打开HTTPS网页 $url"
_green "用户名、密码就是服务器所使用的用户名、密码(如root和root用户的密码)"
_green "如果登录无误请不要急着重启系统，去执行预配置环境的命令后再重启系统"
_green "如果登录有问题web端没起来，等待10秒后重启系统看看"
rm -rf /usr/local/bin/reboot_pve.txt
rm -rf /usr/local/bin/ifupdown2_installed.txt
