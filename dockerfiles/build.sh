#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2024.03.12

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

########## 定义部分需要使用的函数

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

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))  # 打乱数组顺序
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
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

is_private_ipv4() {
    local ip_address=$1
    local ip_parts
    if [[ -z $ip_address ]]; then
        return 0 # 输入为空
    fi
    IFS='.' read -r -a ip_parts <<<"$ip_address"
    # 检查IP地址是否符合内网IP地址的范围
    # 去除 回环，REC 1918，多播 地址
    if [[ ${ip_parts[0]} -eq 10 ]] ||
        [[ ${ip_parts[0]} -eq 172 && ${ip_parts[1]} -ge 16 && ${ip_parts[1]} -le 31 ]] ||
        [[ ${ip_parts[0]} -eq 192 && ${ip_parts[1]} -eq 168 ]] ||
        [[ ${ip_parts[0]} -eq 127 ]] ||
        [[ ${ip_parts[0]} -eq 0 ]] ||
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

statistics_of_run_times() {
    COUNT=$(curl -4 -ksm1 "https://hits.spiritlhl.net/pve?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null ||
        curl -6 -ksm1 "https://hits.spiritlhl.net/pve?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null)
    TODAY=$(echo "$COUNT" | grep -oP '"daily":\s*[0-9]+' | sed 's/"daily":\s*\([0-9]*\)/\1/')
    TOTAL=$(echo "$COUNT" | grep -oP '"total":\s*[0-9]+' | sed 's/"total":\s*\([0-9]*\)/\1/')
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
        fi
    fi
}

########## 前置环境检测和组件安装

# 更改网络优先级为IPV4优先
sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf && systemctl restart networking

install_package curl
install_package sudo

# cdn检测
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
check_cdn_file

if ! command -v docker >/dev/null 2>&1; then
    _yellow "Installing docker"
    curl -sSL https://get.docker.com/ | sh
fi
if ! command -v docker-compose >/dev/null 2>&1; then
    _yellow "Installing docker-compose"
    curl -Lk "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    docker-compose --version
fi

# Dockerfile_x86_64_7
# Dockerfile_aarch64_7
tag="x86_64_7"
docker_file_name="Dockerfile_x86_64_7"
curl -Lk "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/dockerfiles/${docker_file_name}" -o /root/Dockerfile
docker build -t "spiritlhl/proxmoxve:${tag}" -f /root/Dockerfile .
