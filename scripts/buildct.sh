#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.08.21


# ./buildct.sh CTID 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘 独立IPV6
# ./buildct.sh 102 1234567 1 512 5 20001 20002 20003 30000 30025 debian11 local N

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

check_china(){
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
sshn="${6:-20001}"
web1_port="${7:-20002}"
web2_port="${8:-20003}"
port_first="${9:-29975}"
port_last="${10:-30000}"
system_ori="${11:-debian11}"
storage="${12:-local}"
independent_ipv6="${13:-N}"
independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
rm -rf "ct$name"
en_system=$(echo "$system_ori" | sed 's/[0-9]*//g')
num_system=$(echo "$system_ori" | sed 's/[a-zA-Z]*//g')
system="$en_system-$num_system"
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
    system_name=$(pveam available --section system | grep "$system" | awk '{print $2}' | head -n1)
    if ! pveam available --section system | grep "$system" > /dev/null; then
        _red "No such system"
        exit
    else
        _green "Use $system_name"
    fi
    pveam download local $system_name
fi

check_cdn() {
    local o_url=$1
    for cdn_url in "${cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" > /dev/null 2>&1; then
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

cdn_urls=("https://cdn.spiritlhl.workers.dev/" "https://cdn3.spiritlhl.net/" "https://cdn1.spiritlhl.net/" "https://ghproxy.com/" "https://cdn2.spiritlhl.net/")
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
if [ "$independent_ipv6" == "y" ]; then
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
else
    if [ -f /usr/local/bin/pve_check_ipv6 ]; then
        ipv6_address="2001:db8:1::2"
        IFS="/" read -ra parts <<< "$ipv6_address"
        part_1="${parts[0]}"
        part_2="${parts[1]}"
        IFS=":" read -ra part_1_parts <<< "$part_1"
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
        ipv6_prefixlen="64"
    fi
    if [ -f /usr/local/bin/pve_ipv6_gateway ]; then
        ipv6_gateway="2001:db8:1::"
    fi
fi

user_ip="172.16.1.${num}"
if [ "$system_arch" = "x86" ]; then
    pct create $CTID ${storage}:vztmpl/$system_name -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
else
    temp_system_name="${en_system}-arm64-${version}-cloud.tar.xz"
    pct create $CTID ${storage}:vztmpl/${temp_system_name} -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
fi
pct start $CTID
pct set $CTID --hostname $CTID
if [ "$independent_ipv6" == "y" ]; then
    if [ "$ipv6_prefixlen" -le 64 ]; then
        if [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
            if grep -q "vmbr2" /etc/network/interfaces; then
                pct set $CTID --net0 name=eth0,ip6="${ipv6_address_without_last_segment}${CTID}/128",bridge=vmbr2,gw6="${ipv6_address_without_last_segment}1"
                pct set $CTID --net1 name=eth1,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1
                pct set $CTID --nameserver 8.8.8.8,2001:4860:4860::8888 --nameserver 8.8.4.4,2001:4860:4860::8844
                independent_ipv6_status="Y"
            else
                independent_ipv6_status="N"
            fi
        else
            independent_ipv6_status="N"
        fi
    else
        independent_ipv6_status="N"
    fi
else
    independent_ipv6_status="N"
fi
if [ "$independent_ipv6_status" == "N" ]; then
    if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ] || [ "$ipv6_prefixlen" -gt 112 ]; then
        pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1
        pct set $CTID --nameserver 8.8.8.8 --nameserver 8.8.4.4
    else
        pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1,ip6=${ipv6_address}/${ipv6_prefixlen},gw6=${ipv6_gateway}
        pct set $CTID --nameserver 8.8.8.8,2001:4860:4860::8888 --nameserver 8.8.4.4,2001:4860:4860::8844
    fi
fi
sleep 3
if echo "$system" | grep -qiE "centos|almalinux|rockylinux"; then
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

iptables -t nat -A PREROUTING -p tcp --dport ${sshn} -j DNAT --to-destination ${user_ip}:22
iptables -t nat -A PREROUTING -p tcp -m tcp --dport ${web1_port} -j DNAT --to-destination ${user_ip}:80
iptables -t nat -A PREROUTING -p tcp -m tcp --dport ${web2_port} -j DNAT --to-destination ${user_ip}:443
iptables -t nat -A PREROUTING -p tcp -m tcp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
iptables -t nat -A PREROUTING -p udp -m udp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
if [ ! -f "/etc/iptables/rules.v4" ]; then
    touch /etc/iptables/rules.v4
fi
iptables-save | awk '{if($1=="COMMIT"){delete x}}$1=="-A"?!x[$0]++:1' | iptables-restore
iptables-save > /etc/iptables/rules.v4
service netfilter-persistent restart

# 容器的相关信息将会存储到对应的容器的NOTE中，可在WEB端查看
if [ "$independent_ipv6_status" == "Y" ]; then
    echo "$CTID $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system_ori $storage ${ipv6_address_without_last_segment}${CTID}" >> "ct${CTID}"
    data=$(echo " CTID root密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage 独立IPV6地址-ipv6_address")
else
    echo "$CTID $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system_ori $storage" >> "ct${CTID}"
    data=$(echo " CTID root密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage")
fi
values=$(cat "ct${CTID}")
IFS=' ' read -ra data_array <<< "$data"
IFS=' ' read -ra values_array <<< "$values"
length=${#data_array[@]}
for ((i=0; i<$length; i++))
do
    echo "${data_array[$i]} ${values_array[$i]}"
    echo ""
done > "/tmp/temp${CTID}.txt"
sed -i 's/^/# /' "/tmp/temp${CTID}.txt"
cat "/etc/pve/lxc/${CTID}.conf" >> "/tmp/temp${CTID}.txt"
cp "/tmp/temp${CTID}.txt" "/etc/pve/lxc/${CTID}.conf"
rm -rf "/tmp/temp${CTID}.txt"
cat "ct${CTID}"
