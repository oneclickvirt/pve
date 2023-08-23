#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.08.23
# ./buildct_onlyv6.sh CTID 密码 CPU核数 内存 硬盘 系统 存储盘
# ./buildct_onlyv6.sh 102 1234567 1 512 5 debian11 local

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
if [ ! -f /usr/local/bin/pve_check_ipv6 ]; then
    _yellow "No ipv6 address exists to open a server with a standalone IPV6 address"
fi
if ! grep -q "vmbr2" /etc/network/interfaces; then
    _yellow "No vmbr2 exists to open a server with a standalone IPV6 address"
fi
# 检测ndppd服务是否启动了
service_status=$(systemctl is-active ndpresponder.service)
if [ "$service_status" == "active" ]; then
    _green "The ndpresponder service started successfully and is running, and the host can open a service with a separate IPV6 address."
    _green "ndpresponder服务启动成功且正在运行，宿主机可开设带独立IPV6地址的服务。"
else
    _green "The status of the ndpresponder service is abnormal and the host may not open a service with a separate IPV6 address."
    _green "ndpresponder服务状态异常，宿主机不可开设带独立IPV6地址的服务。"
    exit 1
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

check_china() {
    _yellow "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            _yellow "根据ipapi.co提供的信息，当前IP可能在中国，使用中国镜像下载"
            CN=true
        else
            if [[ $? -ne 0 ]]; then
                if [[ $(curl -m 6 -s cip.cc) =~ "中国" ]]; then
                    _yellow "根据cip.cc提供的信息，当前IP可能在中国，使用中国镜像下载"
                    CN=true
                fi
            fi
        fi
    fi
}

get_system_arch
if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
    _red "This script can only run on machines under x86_64 or arm architecture."
    exit 1
fi
cd /root >/dev/null 2>&1
CTID="${1:-102}"
password="${2:-123456}"
core="${3:-1}"
memory="${4:-512}"
disk="${5:-5}"
system_ori="${6:-debian11}"
storage="${7:-local}"
rm -rf "ct$name"
en_system=$(echo "$system_ori" | sed 's/[0-9]*//g')
num_system=$(echo "$system_ori" | sed 's/[a-zA-Z]*//g')
if [ "$system_arch" = "arch" ]; then
    if [ "$en_system" = "ubuntu" ]; then
        case "$system_ori" in
        ubuntu14)
            version="trusty"
            ;;
        ubuntu16)
            version="xenial"
            ;;
        ubuntu18)
            version="bionic"
            ;;
        ubuntu20)
            version="focal"
            ;;
        ubuntu22)
            version="jammy"
            ;;
        *)
            echo "Unsupported Ubuntu version."
            exit 1
            ;;
        esac
    elif [ "$en_system" = "debian" ]; then
        case "$system_ori" in
        debian6)
            version="squeeze"
            ;;
        debian7)
            version="wheezy"
            ;;
        debian8)
            version="jessie"
            ;;
        debian9)
            version="stretch"
            ;;
        debian10)
            version="buster"
            ;;
        debian11)
            version="bullseye"
            ;;
        debian12)
            version="bookworm"
            ;;
        *)
            echo "Unsupported Debian version."
            exit 1
            ;;
        esac
    else
        version=${num_system}
    fi
    check_china
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        curl -o "/var/lib/vz/template/cache/${en_system}-arm64-${version}-cloud.tar.xz" "https://jenkins.linuxcontainers.org/view/LXC/job/image-${en_system}/architecture=arm64,release=${version},variant=cloud/lastSuccessfulBuild/artifact/rootfs.tar.xz"
    else
        # https://mirror.tuna.tsinghua.edu.cn/lxc-images/images/
        URL="https://mirror.tuna.tsinghua.edu.cn/lxc-images/images/${en_system}/${version}/arm64/cloud/"
        HTML=$(curl -s "$URL")
        folder_links_dates=$(echo "$HTML" | grep -oE '<a href="([^"]+)".*date">([^<]+)' | sed -E 's/<a href="([^"]+)".*date">([^<]+)/\1 \2/')
        sorted_links=$(echo "$folder_links_dates" | sort -k2 -r)
        latest_folder_link=$(echo "$sorted_links" | head -n 1 | awk '{print $1}')
        latest_folder_url="${URL}${latest_folder_link}"
        curl -o "/var/lib/vz/template/cache/${en_system}-arm64-${version}-cloud.tar.xz" "${latest_folder_url}/rootfs.tar.xz"
    fi
else
    system="${en_system}-${num_system}"
    system_name=$(pveam available --section system | grep "$system" | awk '{print $2}' | head -n1)
    if ! pveam available --section system | grep "$system" >/dev/null; then
        _red "No such system"
        exit 1
    else
        _green "Use $system_name"
    fi
    pveam download local $system_name
fi

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

cdn_urls=("https://cdn.spiritlhl.workers.dev/" "https://cdn3.spiritlhl.net/" "https://cdn1.spiritlhl.net/" "https://cdn2.spiritlhl.net/")
check_cdn_file
first_digit=${CTID:0:1}
second_digit=${CTID:1:1}
third_digit=${CTID:2:1}
if [ $first_digit -le 2 ]; then
    if [ $second_digit -eq 0 ]; then
        num=$third_digit
    else
        num=$second_digit$third_digit
    fi
else
    num=$((first_digit - 2))$second_digit$third_digit
fi
# 检测IPV6相关的信息
if [ -f /usr/local/bin/pve_check_ipv6 ]; then
    ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
    ipv6_address_without_last_segment="${ipv6_address%:*}:"
fi
if [ -f /usr/local/bin/pve_ipv6_prefixlen ]; then
    ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
fi
if [ -f /usr/local/bin/pve_ipv6_gateway ]; then
    ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
fi
if [ "$system_arch" = "x86" ]; then
    pct create $CTID ${storage}:vztmpl/$system_name -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
else
    temp_system_name="${en_system}-arm64-${version}-cloud.tar.xz"
    pct create $CTID ${storage}:vztmpl/${temp_system_name} -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
fi
pct start $CTID
pct set $CTID --hostname $CTID
user_ip="172.16.1.${num}"
pct set $CTID --net0 name=eth0,ip6="${ipv6_address_without_last_segment}${CTID}/128",bridge=vmbr2,gw6="${ipv6_address_without_last_segment}1"
pct set $CTID --net1 name=eth1,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1
pct set $CTID --nameserver 8.8.8.8,2001:4860:4860::8888 --nameserver 8.8.4.4,2001:4860:4860::8844
sleep 3
if echo "$system" | grep -qiE "centos|almalinux|rockylinux" >/dev/null 2>&1; then
    pct exec $CTID -- yum update -y
    pct exec $CTID -- yum update
    pct exec $CTID -- yum install -y dos2unix curl
else
    pct exec $CTID -- apt-get update -y
    pct exec $CTID -- dpkg --configure -a
    pct exec $CTID -- apt-get update
    pct exec $CTID -- apt-get install dos2unix curl -y
fi
pct exec $CTID -- curl -L ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/ssh.sh -o ssh.sh
pct exec $CTID -- chmod 777 ssh.sh
pct exec $CTID -- dos2unix ssh.sh
pct exec $CTID -- bash ssh.sh
# pct exec $CTID -- curl -L ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/lxc/main/config.sh -o config.sh
# pct exec $CTID -- chmod +x config.sh
# pct exec $CTID -- bash config.sh

# if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ] || [ "$ipv6_prefixlen" -gt 112 ]; then
#     :
# else
#     sleep 3
#     pct exec $CTID -- systemctl restart networking
#     pct reboot $CTID
# fi

echo "$CTID $password $core $memory $disk $system_ori $storage ${ipv6_address_without_last_segment}${CTID}" >>"ct${CTID}"
# 容器的相关信息将会存储到对应的容器的NOTE中，可在WEB端查看
data=$(echo " CTID root密码-password CPU核数-CPU 内存-memory 硬盘-disk 系统-system 存储盘-storage 外网IPV6-ipv6")
values=$(cat "ct${CTID}")
IFS=' ' read -ra data_array <<<"$data"
IFS=' ' read -ra values_array <<<"$values"
length=${#data_array[@]}
for ((i = 0; i < $length; i++)); do
    echo "${data_array[$i]} ${values_array[$i]}"
    echo ""
done >"/tmp/temp${CTID}.txt"
sed -i 's/^/# /' "/tmp/temp${CTID}.txt"
cat "/etc/pve/lxc/${CTID}.conf" >>"/tmp/temp${CTID}.txt"
cp "/tmp/temp${CTID}.txt" "/etc/pve/lxc/${CTID}.conf"
rm -rf "/tmp/temp${CTID}.txt"
cat "ct${CTID}"
