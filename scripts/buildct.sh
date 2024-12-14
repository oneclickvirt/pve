#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2024.12.06

# ./buildct.sh CTID 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统 存储盘 独立IPV6
# ./buildct.sh 102 1234567 1 512 5 20001 20002 20003 30000 30025 debian11 local N

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

get_system_arch
check_china
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
en_system=$(echo "$system_ori" | sed 's/[0-9]*//g; s/\.$//')
num_system=$(echo "$system_ori" | sed 's/[a-zA-Z]*//g')
system="$en_system-$num_system"
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
check_cdn_file
if [ "$system_arch" = "arch" ]; then
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
        # 转换ubuntu系统的代号为对应名字
        for ((i=0; i<${#ubuntu_versions[@]}; i++)); do
            if [ "${ubuntu_versions[$i]}" = "$num_system" ]; then
                version="${ubuntu_names[$i]}"
                system_name="${en_system}_${ubuntu_versions[$i]}_${ubuntu_names[$i]}_arm64_cloud.tar.xz"
                break
            fi
        done
    elif [ "$en_system" = "debian" ]; then
        # 转换debian系统的代号为对应名字
        for ((i=0; i<${#debian_versions[@]}; i++)); do
            if [ "${debian_versions[$i]}" = "$num_system" ]; then
                version="${debian_names[$i]}"
                system_name="${en_system}_${debian_versions[$i]}_${debian_names[$i]}_arm64_cloud.tar.xz"
                break
            fi
        done
    elif [ -z $num_system ]; then
        # 适配无指定版本的系统
        for ((i=0; i<${#system_names[@]}; i++)); do
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
else
    fixed_system=false
    system="${en_system}-${num_system}"
    # 使用自动修补的镜像
    system_name=""
    system_names=()
    response=$(curl -slk -m 6 "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxc_amd64_images/main/fixed_images.txt")
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        system_names+=($(echo "$response"))
    fi
    for image_name in "${system_names[@]}"; do
        if [ -z "${num_system}" ]; then
            # 若无版本号，则仅识别系统名字匹配第一个链接，放宽系统识别
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
            # 有版本号，精确识别系统
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
    # 使用手动修补的镜像
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
                # 适配无指定版本的系统
                for ((i=0; i<${#system_names[@]}; i++)); do
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
                # 适配指定版本的系统
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
fi

# 检测CTID是否为数字
if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
    _red "Error: CTID must be a valid number."
    _red "错误：CTID 必须是有效的数字。"
    exit 1
fi
# 检测CTID是否在范围100到256之间
if [[ "$CTID" -ge 100 && "$CTID" -le 256 ]]; then
    _green "CTID is valid: $CTID"
else
    _red "Error: CTID must be in the range 100 ~ 256."
    _red "错误： CTID 需要在100到256以内。"
    exit 1
fi
num=$CTID
# 检测IPV6相关的信息
if [ "$independent_ipv6" == "y" ]; then
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

# 正式开设容器
user_ip="172.16.1.${num}"
if [ "$fixed_system" = true ]; then
    pct create $CTID /var/lib/vz/template/cache/${system_name} -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
else
    pct create $CTID ${storage}:vztmpl/${system_name} -cores $core -cpuunits 1024 -memory $memory -swap 128 -rootfs ${storage}:${disk} -onboot 1 -password $password -features nesting=1
fi
pct start $CTID
sleep 5
pct set $CTID --hostname $CTID
if [ "$independent_ipv6" == "y" ]; then
    if [ ! -z "$host_ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
        if grep -q "vmbr2" /etc/network/interfaces; then
            pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1
            pct set $CTID --net1 name=eth1,ip6="${ipv6_address_without_last_segment}${CTID}/128",bridge=vmbr2,gw6="${host_ipv6_address}"
            pct set $CTID --nameserver 1.1.1.1
            pct set $CTID --searchdomain local
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
if [ "$independent_ipv6_status" == "N" ]; then
    # if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ] || [ "$ipv6_prefixlen" -gt 112 ]; then
    pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1
    pct set $CTID --nameserver 1.1.1.1
    pct set $CTID --searchdomain local
    # else
    #     pct set $CTID --net0 name=eth0,ip=${user_ip}/24,bridge=vmbr1,gw=172.16.1.1,ip6=${ipv6_address}/${ipv6_prefixlen},gw6=${ipv6_gateway}
    #     pct set $CTID --nameserver 8.8.8.8,2001:4860:4860::8888 --nameserver 8.8.4.4,2001:4860:4860::8844
    # fi
fi
sleep 3

# 开始配置容器内部环境
if [ "$fixed_system" = true ]; then
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        sleep 1
    else
        pct exec $CTID -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
        pct exec $CTID -- chmod 777 ChangeMirrors.sh
        pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
        pct exec $CTID -- rm -rf ChangeMirrors.sh
    fi
    sleep 2
    public_network_check_res=$(pct exec $CTID -- curl -lk -m 6 ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test)
    if [[ $public_network_check_res == *"success"* ]]; then
        echo "network is public"
    else
        echo "nameserver 8.8.8.8" | pct exec $CTID -- tee -a /etc/resolv.conf
        sleep 1
        pct exec $CTID -- curl -lk -m 6 ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test
    fi
    sleep 2
    ssh_check_res=$(pct exec $CTID -- lsof -i:22)
    if [[ $ssh_check_res == *"ssh"* ]]; then
        echo "ssh config correct"
    else
        pct exec $CTID -- service ssh restart
        pct exec $CTID -- service sshd restart
        sleep 2
        pct exec $CTID -- systemctl restart sshd
        pct exec $CTID -- systemctl restart ssh
    fi
else
    if echo "$system" | grep -qiE "centos|almalinux|rockylinux" >/dev/null 2>&1; then
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            pct exec $CTID -- yum update -y
            pct exec $CTID -- yum install -y dos2unix curl
        else
            pct exec $CTID -- yum install -y curl
            pct exec $CTID -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
            pct exec $CTID -- chmod 777 ChangeMirrors.sh
            pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
            pct exec $CTID -- rm -rf ChangeMirrors.sh
            pct exec $CTID -- yum install -y dos2unix
        fi
    elif echo "$system" | grep -qiE "fedora" >/dev/null 2>&1; then
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            pct exec $CTID -- dnf update -y
            pct exec $CTID -- dnf install -y dos2unix curl
        else
            pct exec $CTID -- dnf install -y curl
            pct exec $CTID -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
            pct exec $CTID -- chmod 777 ChangeMirrors.sh
            pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
            pct exec $CTID -- rm -rf ChangeMirrors.sh
            pct exec $CTID -- dnf install -y dos2unix
        fi
    elif echo "$system" | grep -qiE "opensuse" >/dev/null 2>&1; then
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            pct exec $CTID -- zypper update -y
            pct exec $CTID -- zypper --non-interactive install dos2unix curl
        else
            pct exec $CTID -- zypper --non-interactive install curl
            pct exec $CTID -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
            pct exec $CTID -- chmod 777 ChangeMirrors.sh
            pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
            pct exec $CTID -- rm -rf ChangeMirrors.sh
            pct exec $CTID -- zypper --non-interactive install dos2unix
        fi
    elif echo "$system" | grep -qiE "alpine|archlinux" >/dev/null 2>&1; then
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            sleep 1
        else
            pct exec $CTID -- wget https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh
            pct exec $CTID -- chmod 777 ChangeMirrors.sh
            pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
            pct exec $CTID -- rm -rf ChangeMirrors.sh
        fi
    elif echo "$system" | grep -qiE "ubuntu|debian|devuan" >/dev/null 2>&1; then
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            pct exec $CTID -- apt-get update -y
            pct exec $CTID -- dpkg --configure -a
            pct exec $CTID -- apt-get update
            pct exec $CTID -- apt-get install dos2unix curl -y
        else
            pct exec $CTID -- apt-get install curl -y --fix-missing
            pct exec $CTID -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
            pct exec $CTID -- chmod 777 ChangeMirrors.sh
            pct exec $CTID -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
            pct exec $CTID -- rm -rf ChangeMirrors.sh
            pct exec $CTID -- apt-get install dos2unix -y
        fi
    fi
    if echo "$system" | grep -qiE "alpine|archlinux|gentoo|openwrt" >/dev/null 2>&1; then
        pct exec $CTID -- curl -L ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/ssh_sh.sh -o ssh_sh.sh
        pct exec $CTID -- chmod 777 ssh_sh.sh
        pct exec $CTID -- dos2unix ssh_sh.sh
        pct exec $CTID -- bash ssh_sh.sh
    else
        pct exec $CTID -- curl -L ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/ssh_bash.sh -o ssh_bash.sh
        pct exec $CTID -- chmod 777 ssh_bash.sh
        pct exec $CTID -- dos2unix ssh_bash.sh
        pct exec $CTID -- bash ssh_bash.sh
    fi
fi
if [ "$independent_ipv6_status" == "Y" ]; then
    pct exec $CTID -- echo '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb' | crontab -
fi
# 启用PVE自动修改网络接口设置
pct exec $CTID -- rm -rf /etc/network/.pve-ignore.interfaces
# 禁止PVE自动修改DNS设置
pct exec $CTID -- touch /etc/.pve-ignore.resolv.conf
# 禁止PVE自动修改主机名设置
pct exec $CTID -- touch /etc/.pve-ignore.hosts
pct exec $CTID -- touch /etc/.pve-ignore.hostname
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

iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport ${sshn} -j DNAT --to-destination ${user_ip}:22
# 仅在 web1_port 不为 0 时映射 HTTP 端口
if [ "${web1_port}" -ne 0 ]; then
    iptables -t nat -A PREROUTING -i vmbr0 -p tcp -m tcp --dport ${web1_port} -j DNAT --to-destination ${user_ip}:80
fi
# 仅在 web2_port 不为 0 时映射 HTTPS 端口
if [ "${web2_port}" -ne 0 ]; then
    iptables -t nat -A PREROUTING -i vmbr0 -p tcp -m tcp --dport ${web2_port} -j DNAT --to-destination ${user_ip}:443
fi
# 仅在 port_first 和 port_last 都不为 0 时映射 TCP 和 UDP 端口范围
if [ "${port_first}" -ne 0 ] && [ "${port_last}" -ne 0 ]; then
    iptables -t nat -A PREROUTING -i vmbr0 -p tcp -m tcp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
    iptables -t nat -A PREROUTING -i vmbr0 -p udp -m udp --dport ${port_first}:${port_last} -j DNAT --to-destination ${user_ip}:${port_first}-${port_last}
fi
if [ ! -f "/etc/iptables/rules.v4" ]; then
    touch /etc/iptables/rules.v4
fi
iptables-save | awk '{if($1=="COMMIT"){delete x}}$1=="-A"?!x[$0]++:1' | iptables-restore
iptables-save >/etc/iptables/rules.v4
service netfilter-persistent restart

# 容器的相关信息将会存储到对应的容器的NOTE中，可在WEB端查看
if [ "$independent_ipv6_status" == "Y" ]; then
    echo "$CTID $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system_ori $storage ${ipv6_address_without_last_segment}${CTID}" >>"ct${CTID}"
    data=$(echo " CTID root密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage 独立IPV6地址-ipv6_address")
else
    echo "$CTID $password $core $memory $disk $sshn $web1_port $web2_port $port_first $port_last $system_ori $storage" >>"ct${CTID}"
    data=$(echo " CTID root密码-password CPU核数-CPU 内存-memory 硬盘-disk SSH端口 80端口 443端口 外网端口起-port-start 外网端口止-port-end 系统-system 存储盘-storage")
fi
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
