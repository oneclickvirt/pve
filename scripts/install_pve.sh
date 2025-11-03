#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.11.03

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
    exit 1
fi
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi

########## 备份配置文件

if [ -f "/etc/resolv.conf" ]; then
    if [ ! -f /etc/resolv.conf.bak ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
    fi
fi
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
if [ -f "/etc/hostname" ]; then
    if [ ! -f /etc/hostname.bak ]; then
        cp /etc/hostname /etc/hostname.bak
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
# 删除无效别名网卡
if [ -d "/run/network/interfaces.d/" ]; then
    directory="/run/network/interfaces.d/"
    file=$(ls -1 $directory | grep -v "cloud-init" | head -n 1)
    if [ -n "$file" ]; then
        awk_condition='/^[0-9]+:/ {interface=$2; gsub(/:/, "", interface)} /^[[:space:]]+altname/ {next} /^[[:space:]]+link/ {if (interface == file) exit 0} END {exit 1}'
        if ip addr show | awk -v file="$file" "$awk_condition"; then
            :
        else
            rm "$directory$file"
        fi
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
                apt_output=$(apt-get install -y $package_name --fix-missing 2>&1)
            fi
        fi
        if [ $? -ne 0 ]; then
            if echo "$apt_output" | grep -qE 'apt --fix-broken install' &&
                echo "$apt_output" | grep -qE 'Unmet dependencies.' &&
                echo "$apt_output" | grep -qE 'with no packages'; then
                apt-get --fix-broken install -y
                sleep 1
                dpkg --configure -a
                if [ $? -ne 0 ]; then
                    _green "$package_name tried to install but failed, exited the program"
                    _green "$package_name 已尝试安装但失败，退出程序"
                    exit 1
                fi
            fi
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
    touch /etc/cloud/cloud-init.disabled
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
        sed -i '1s/^/auto lo\n/' "/etc/network/interfaces"
        chattr +i /etc/network/interfaces
        _blue "Can not find 'auto lo' in /etc/network/interfaces, add it"
    fi
    if ! grep -q "iface lo inet loopback" "/etc/network/interfaces"; then
        chattr -i /etc/network/interfaces
        sed -i '2s/^/iface lo inet loopback\n/' "/etc/network/interfaces"
        chattr +i /etc/network/interfaces
        _blue "Can not find 'iface lo inet loopback' in /etc/network/interfaces, add it"
    fi
    # 检查是否存在网络接口配置
    interface_configured=false
    # 检查主接口是否已配置（包括 auto 和 allow-hotplug）
    if (grep -q "auto ${interface}" /etc/network/interfaces || grep -q "allow-hotplug ${interface}" /etc/network/interfaces) && \
       (grep -q "iface ${interface} inet static" /etc/network/interfaces || \
        grep -q "iface ${interface} inet dhcp" /etc/network/interfaces || \
        grep -q "iface ${interface} inet auto" /etc/network/interfaces); then
        interface_configured=true
    fi
    # 检查interfaces.d目录中是否有配置
    if [ -d "/etc/network/interfaces.d/" ]; then
        for file in /etc/network/interfaces.d/*; do
            if [ -f "$file" ] && (grep -q "auto ${interface}" "$file" || grep -q "allow-hotplug ${interface}" "$file" || grep -q "iface ${interface}" "$file"); then
                interface_configured=true
                break
            fi
        done
    fi
    # 如果没有找到接口配置，说明可能是从NetworkManager切换过来的
    if [ "$interface_configured" = false ]; then
        _blue "No network interface configuration found, possibly switched from NetworkManager"
        _blue "Adding static configuration for interface ${interface}"
        chattr -i /etc/network/interfaces
        echo "" >>/etc/network/interfaces
        echo "# Network interface ${interface}" >>/etc/network/interfaces
        echo "auto ${interface}" >>/etc/network/interfaces
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            echo "iface ${interface} inet static" >>/etc/network/interfaces
            echo "    address ${ipv4_address}" >>/etc/network/interfaces
            echo "    netmask ${ipv4_subnet}" >>/etc/network/interfaces
            echo "    gateway ${ipv4_gateway}" >>/etc/network/interfaces
            echo "    dns-nameservers 8.8.8.8 8.8.4.4" >>/etc/network/interfaces
        else
            echo "iface ${interface} inet static" >>/etc/network/interfaces
            echo "    address ${ipv4_address}" >>/etc/network/interfaces
            echo "    netmask ${ipv4_subnet}" >>/etc/network/interfaces
            echo "    gateway ${ipv4_gateway}" >>/etc/network/interfaces
            echo "    dns-nameservers 8.8.8.8 223.5.5.5" >>/etc/network/interfaces
        fi
        chattr +i /etc/network/interfaces
        # 标记已配置，跳过后续的接口检查
        interface_configured=true
    fi
    # 只有在接口已配置的情况下才进行后续处理
    if [ "$interface_configured" = true ]; then
        chattr -i /etc/network/interfaces
        echo " " >>/etc/network/interfaces
        chattr +i /etc/network/interfaces
        # 合并interfaces.d目录中的文件
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
        # 处理/run/network/interfaces.d/目录
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
        # 检测物理接口是否已auto或allow-hotplug链接
        if ! grep -q "auto ${interface}" /etc/network/interfaces && ! grep -q "allow-hotplug ${interface}" /etc/network/interfaces; then
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
    else
        _red "Warning: No network interface configuration found and unable to create one"
        _red "Please check if the network interface variables are properly set"
    fi
}

fix_interfaces_ipv6_auto_type() {
    chattr -i /etc/network/interfaces
    while IFS= read -r line; do
        # 检测以 "iface" 开头且包含 "inet6 auto" 的行
        if [[ $line == *"inet6 auto"* ]]; then
            modified_line="${line/auto/static}"
            echo "$modified_line"
            # 添加静态IPv6配置信息
            echo "    address ${ipv6_address}/${ipv6_prefixlen}"
            echo "    gateway ${ipv6_gateway}"
        else
            echo "$line"
        fi
    done </etc/network/interfaces >/tmp/interfaces.modified
    chattr -i /etc/network/interfaces
    mv -f /tmp/interfaces.modified /etc/network/interfaces
    chattr +i /etc/network/interfaces
    rm -rf /tmp/interfaces.modified
}

clean_control_alias_blocks() {
    local input_file="/etc/network/interfaces.d/50-cloud-init"
    local output_file="/usr/local/bin/pve_appended_content.txt"
    local tmp_file
    tmp_file=$(mktemp)
    local control_alias_total
    control_alias_total=$(grep -c "^# control-alias" "$input_file")
    if (( control_alias_total <= 2 )); then
        return 0
    fi
    local control_alias_count=0
    local in_control_alias_block=false
    local buffer=""
    > "$tmp_file"
    > "$output_file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^#\ control-alias\ eth0 ]]; then
            in_control_alias_block=true
            buffer="$line"$'\n'
            continue
        fi
        if $in_control_alias_block; then
            buffer+="$line"$'\n'
            if [[ "$line" =~ ^[[:space:]]*address ]]; then
                ((control_alias_count++))
                if (( control_alias_count <= 2 )); then
                    echo -n "$buffer" >> "$tmp_file"
                else
                    echo -n "$buffer" >> "$output_file"
                fi
                in_control_alias_block=false
                buffer=""
            fi
        else
            echo "$line" >> "$tmp_file"
        fi
    done < "$input_file"
    mv "$tmp_file" "$input_file"
    chmod 644 "$output_file"
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
            _green "The local machine is bound to more than one IPV6 address"
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

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}")) # 打乱数组顺序
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
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
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/install_ifupdown2.sh -O /usr/local/bin/install_ifupdown2.sh
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/ifupdown2-install.service -O /etc/systemd/system/ifupdown2-install.service
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
        echo "0" # 输入为空
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
        echo "0" # 是内网IP地址
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
        system_arch="arm"
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

# 配置网络优先级和环境检测
configure_network_priority() {
    # 更改网络优先级为IPV4优先
    sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf
}

# 运行前置检查
run_preliminary_checks() {
    # ChinaIP检测
    check_china
    # cdn检测
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
}

# 检查运行环境并配置
check_and_configure_environment() {
    if [ "$(id -u)" != "0" ]; then
        _red "This script must be run as root"
        exit 1
    fi
    get_system_arch
    if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
        _red "This script can only run on machines under x86_64 or arm architecture."
        exit 1
    fi
    if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
        systemctl disable NetworkManager
        systemctl stop NetworkManager
    fi
    clean_control_alias_blocks
}

# 设置DNS检查服务
setup_dns_check_service() {
    if [ ! -f "/usr/local/bin/check-dns.sh" ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/check-dns.sh -O /usr/local/bin/check-dns.sh
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/check-dns.service -O /etc/systemd/system/check-dns.service
        chmod +x /usr/local/bin/check-dns.sh
        chmod +x /etc/systemd/system/check-dns.service
        systemctl daemon-reload
        systemctl enable check-dns.service
        systemctl start check-dns.service
    fi
}

# 修复APT源问题
fix_apt_issues1() {
    # 确保apt没有问题
    /usr/local/bin/check-dns.sh
    apt-get update -y
    apt-get full-upgrade -y
    if [ $? -ne 0 ]; then
        apt-get install debian-keyring debian-archive-keyring -y
        apt-get update -y && apt-get full-upgrade -y
    fi
    # 处理缺失的公钥
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
        switch_mirrors
    fi
    systemctl daemon-reload
}

# 切换镜像源
switch_mirrors() {
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        curl -lk https://raw.githubusercontent.com/SuperManito/LinuxMirrors/main/ChangeMirrors.sh -o ChangeMirrors.sh
        chmod 777 ChangeMirrors.sh
        ./ChangeMirrors.sh --use-official-source --web-protocol http --intranet false --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null
    else
        curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
        chmod 777 ChangeMirrors.sh
        ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null
    fi
    rm -rf ChangeMirrors.sh
    apt-get update -y
    # 如果仍然报错，切换到阿里云镜像源
    if [ $? -ne 0 ]; then
        curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
        chmod 777 ChangeMirrors.sh
        ./ChangeMirrors.sh --source mirrors.aliyun.com --web-protocol http --intranet false --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null
        rm -rf ChangeMirrors.sh
        apt-get update -y
    fi
}

# 确保系统路径完整
ensure_system_paths() {
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
}

# 安装必要的基础软件包
install_base_packages() {
    install_package wget
    install_package curl
    install_package sudo
    install_package ping
    install_package bc
    install_package iptables
    install_package lshw
    install_package net-tools
    install_package service
    install_package ipcalc
    install_package sipcalc
    install_package dmidecode
    install_package dnsutils
    install_package ethtool
    install_package gnupg
    install_package iputils-ping
    install_package iproute2
    install_package lsb-release
    # 获取ethtool路径
    ethtool_path=$(which ethtool)
    check_haveged
}

# 特殊系统环境处理
handle_special_environments() {
    dmidecode_output=$(dmidecode -t system)
    # 特殊处理DigitalOcean的Debian12，需要抢先安装ifupdown2
    if grep -q '^VERSION_ID="12"$' /etc/os-release &&
        grep -q '^NAME="Debian GNU/Linux"$' /etc/os-release &&
        [[ $dmidecode_output == *"DigitalOcean"* ]] &&
        ! dpkg -l ifupdown2 | grep -q '^ii'; then
        install_package ifupdown2
    elif [[ $dmidecode_output == *"Hetzner_vServer"* ]] || [[ $dmidecode_output == *"Exoscale Compute Platform"* ]] || ! dpkg -l ifupdown | grep -q '^ii'; then
        # 特殊处理Hetzner
        prebuild_ifupdown2
    # elif dig -x $main_ipv4 | grep -q "vps.ovh"; then
    #     # 特殊处理OVH
    #     prebuild_ifupdown2
    fi
}

# 系统最低要求检查
check_system_requirements() {
    if [ ! -f /etc/debian_version ] || [ $(grep MemTotal /proc/meminfo | awk '{print $2}') -lt 2000000 ] || [ $(grep -c ^processor /proc/cpuinfo) -lt 2 ] || [ $(
        if [[ "${CN}" == true ]]; then
            ping -c 3 baidu.com >/dev/null 2>&1
        else
            ping -c 3 google.com >/dev/null 2>&1
        fi
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
}

# 检测系统信息
detect_system_info() {
    _yellow "Detecting system information, will probably stay on the page for up to 1~2 minutes at most"
    _yellow "正在检测系统信息，最多会停留在该页面 1~2 分钟"
    # 重启网络服务
    restart_network_service
    # 收集IP地址信息
    collect_ip_info
}

# 重启网络服务
restart_network_service() {
    systemctl restart networking
    if [ $? -ne 0 ] && [ -e "/etc/systemd/system/networking.service" ]; then
        # 尝试修复网络接口配置
        if [ -f /etc/network/interfaces ] && grep -q "eth0" /etc/network/interfaces; then
            chattr -i /etc/network/interfaces
            sed -i '/^auto ens[0-9]\+$/d' /etc/network/interfaces
            sed -i '/^allow-hotplug ens[0-9]\+$/d' /etc/network/interfaces
            sed -i '/^iface ens[0-9]\+ inet/d' /etc/network/interfaces
            chattr +i /etc/network/interfaces
        fi
    fi

    systemctl restart networking
    if [ $? -ne 0 ] && [ -e "/etc/systemd/system/networking.service" ]; then
        # 安装路由缓存清理脚本
        setup_interface_route_cache_cleaner
    fi
}

# 设置接口路由缓存清理
setup_interface_route_cache_cleaner() {
    if [ ! -f "/usr/local/bin/clear_interface_route_cache.sh" ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/clear_interface_route_cache.sh -O /usr/local/bin/clear_interface_route_cache.sh
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/clear_interface_route_cache.service -O /etc/systemd/system/clear_interface_route_cache.service
        chmod +x /usr/local/bin/clear_interface_route_cache.sh
        chmod +x /etc/systemd/system/clear_interface_route_cache.service
        systemctl daemon-reload
        systemctl enable clear_interface_route_cache.service
        _green "An anomaly was detected with the routing conflict, perform a reboot to reboot the machine to start the repaired daemon and try the installation again."
        _green "检测到路由冲突存在异常，请执行 reboot 重启机器以启动修复的守护进程，再次尝试安装"
        exit 1
    fi
}

# 收集IP地址信息
collect_ip_info() {
    # 收集主IPV4地址
    if [ ! -f /usr/local/bin/pve_main_ipv4 ]; then
        main_ipv4=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
        if is_private_ipv4 "$main_ipv4"; then
            _green "Detected that the main IP is a private IPv4 address: $main_ipv4"
            _green "检测到主 IP 是私有 IPv4 地址：$main_ipv4"
            echo
            _green "The detected IP is private. If your host is a cloud VPS/cloud dedicated server, please use a public IPv4 address as the main PVE IP."
            _green "If your host is a local physical machine without a fixed public IP, you can use the current private IP."
            _green "当前检测到的是私有地址。如果你的宿主机是云服务器/云独立服务器，请选择公网 IPv4 作为 PVE 的主 IP。"
            _green "如果你的宿主机是本地物理机，且没有固定公网 IPv4，可以使用当前私有地址。"
            echo
            reading "Use the current private IPv4 address as the main PVE IP? (y/n) [Default: n]: " use_private
            _green "是否使用当前私有 IPv4 地址作为 PVE 的主 IP？(y/n) [默认: n]: "
            use_private=${use_private:-n}
            if [[ "$use_private" =~ ^[Yy]$ ]]; then
                _green "Using private IP: $main_ipv4"
                _green "使用私有 IP：$main_ipv4"
            else
                check_ipv4
                main_ipv4="$IPV4"
                _green "Using public IP: $main_ipv4"
                _green "使用公网 IP：$main_ipv4"
            fi
        fi
        echo "$main_ipv4" >/usr/local/bin/pve_main_ipv4
    fi
    # 提取主IPV4地址
    main_ipv4=$(cat /usr/local/bin/pve_main_ipv4)
    # 收集IPV4地址(含子网长度)
    if [ ! -f /usr/local/bin/pve_ipv4_address ]; then
        ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p')
        echo "$ipv4_address" >/usr/local/bin/pve_ipv4_address
    fi
    # 提取IPV4地址 含子网长度
    ipv4_address=$(cat /usr/local/bin/pve_ipv4_address)
    # 收集IPV4网关
    if [ ! -f /usr/local/bin/pve_ipv4_gateway ]; then
        ipv4_gateway=$(ip route | awk '/default/ {print $3}' | sed -n '1p')
        echo "$ipv4_gateway" >/usr/local/bin/pve_ipv4_gateway
    fi
    # 提取IPV4网关
    ipv4_gateway=$(cat /usr/local/bin/pve_ipv4_gateway)
    # 收集IPV4子网掩码
    if [ ! -f /usr/local/bin/pve_ipv4_subnet ]; then
        ipv4_subnet=$(ipcalc -n "$ipv4_address" | grep -oP 'Netmask:\s+\K.*' | awk '{print $1}')
        echo "$ipv4_subnet" >/usr/local/bin/pve_ipv4_subnet
    fi
    # 提取Netmask
    ipv4_subnet=$(cat /usr/local/bin/pve_ipv4_subnet)
}

# 检测网络接口和MAC地址
detect_network_interfaces() {
    # 检测物理接口
    interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
    interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
    check_interface

    # 收集MAC地址
    if [ ! -f /usr/local/bin/pve_mac_address ] || [ ! -s /usr/local/bin/pve_mac_address ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_mac_address)" = "" ]; then
        mac_address=$(ip -o link show dev ${interface} | awk '{print $17}')
        echo "$mac_address" >/usr/local/bin/pve_mac_address
    fi
    mac_address=$(cat /usr/local/bin/pve_mac_address)

    # 配置持久化网络接口名称
    setup_persistent_network_interface
}

# 设置持久化网络接口名称
setup_persistent_network_interface() {
    if [ ! -f /etc/systemd/network/10-persistent-net.link ]; then
        echo '[Match]' >/etc/systemd/network/10-persistent-net.link
        echo "MACAddress=${mac_address}" >>/etc/systemd/network/10-persistent-net.link
        echo "" >>/etc/systemd/network/10-persistent-net.link
        echo '[Link]' >>/etc/systemd/network/10-persistent-net.link
        echo "Name=${interface}" >>/etc/systemd/network/10-persistent-net.link
        /etc/init.d/udev force-reload
    fi
}

# 获取IPV6网关信息
get_ipv6_gateway() {
    if [ ! -f /usr/local/bin/pve_ipv6_gateway ] || [ ! -s /usr/local/bin/pve_ipv6_gateway ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_ipv6_gateway)" = "" ]; then
        ipv6_gateway=$(ip -6 route show | awk '/default via/{print $3}' | head -n1)
        echo "$ipv6_gateway" >/usr/local/bin/pve_ipv6_gateway
    fi
    ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
}

# 获取fe80地址
get_fe80_address() {
    if [ ! -f /usr/local/bin/pve_fe80_address ] || [ ! -s /usr/local/bin/pve_fe80_address ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_fe80_address)" = "" ]; then
        fe80_address=$(ip -6 addr show dev $interface | awk '/inet6 fe80/ {print $2}')
        echo "$fe80_address" >/usr/local/bin/pve_fe80_address
    fi
    fe80_address=$(cat /usr/local/bin/pve_fe80_address)
}

# 获取IPV6前缀长度
get_ipv6_prefixlen() {
    if [ ! -f /usr/local/bin/pve_ipv6_prefixlen ] || [ ! -s /usr/local/bin/pve_ipv6_prefixlen ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_ipv6_prefixlen)" = "" ]; then
        ipv6_prefixlen=""
        output=$(ifconfig ${interface} | grep -oP 'inet6 (?!fe80:).*prefixlen \K\d+')
        num_lines=$(echo "$output" | wc -l)
        if [ $num_lines -ge 2 ]; then
            ipv6_prefixlen=$(echo "$output" | sort -n | head -n 1)
        else
            ipv6_prefixlen=$(echo "$output" | head -n 1)
        fi
        echo "$ipv6_prefixlen" >/usr/local/bin/pve_ipv6_prefixlen
    fi
    ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
}

# 检查IPV6是否使用SLAAC分配
check_slaac_status() {
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
}

# 询问是否使用最大子网
ask_maximum_subnet() {
    if [ -f /usr/local/bin/pve_slaac_status ] && [ ! -f /usr/local/bin/pve_maximum_subset ] && [ ! -f /usr/local/bin/fix_interfaces_ipv6_auto_type ]; then
        _blue "It is detected that IPV6 addresses are most likely to be dynamically assigned by SLAAC, and if there is no subsequent need to assign separate IPV6 addresses to VMs/containers, the following option is best selected n"
        _green "检测到IPV6地址大概率由SLAAC动态分配，若后续不需要分配独立的IPV6地址给虚拟机/容器，则下面选项最好选 n"
        _blue "Is the maximum subnet range feasible with IPV6 used?([n]/y)"
        reading "是否使用IPV6可行的最大子网范围？([n]/y)" select_maximum_subset
        if [ "$select_maximum_subset" = "y" ] || [ "$select_maximum_subset" = "Y" ]; then
            echo "true" >/usr/local/bin/pve_maximum_subset
        else
            echo "false" >/usr/local/bin/pve_maximum_subset
        fi
        echo "" >/usr/local/bin/fix_interfaces_ipv6_auto_type
    fi
}

# 重构IPV6地址
rebuild_ipv6_address() {
    if [ ! -f /usr/local/bin/pve_maximum_subset ] || [ $(cat /usr/local/bin/pve_maximum_subset) = true ]; then
        ipv6_address_without_last_segment="${ipv6_address%:*}:"
        if [[ $ipv6_address != *:: && $ipv6_address_without_last_segment != *:: ]]; then
            ipv6_address=$(sipcalc -i ${ipv6_address}/${ipv6_prefixlen} | grep "Subnet prefix (masked)" | cut -d ' ' -f 4 | cut -d '/' -f 1 | sed 's/:0:0:0:0:/::/' | sed 's/:0:0:0:/::/')
            ipv6_address="${ipv6_address%:*}:1"
            if [ "$ipv6_address" == "$ipv6_gateway" ]; then
                ipv6_address="${ipv6_address%:*}:2"
            fi
            ipv6_address_without_last_segment="${ipv6_address%:*}:"
            if ping -c 1 -6 -W 3 $ipv6_address >/dev/null 2>&1; then
                check_ipv6
                ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
                echo "${ipv6_address}" >/usr/local/bin/pve_check_ipv6
            fi
        elif [[ $ipv6_address == *:: ]]; then
            ipv6_address="${ipv6_address}1"
            if [ "$ipv6_address" == "$ipv6_gateway" ]; then
                ipv6_address="${ipv6_address%:*}:2"
            fi
            echo "${ipv6_address}" >/usr/local/bin/pve_check_ipv6
        fi
    fi
}

# 检查并配置cloud-init
configure_cloud_init() {
    if [ -f "/etc/network/interfaces.d/50-cloud-init" ]; then
        if grep -Fxq "# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with the following:" /etc/network/interfaces.d/50-cloud-init && grep -Fxq "# network: {config: disabled}" /etc/network/interfaces.d/50-cloud-init; then
            if [ ! -f "/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" ]; then
                echo "Creating /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg."
                echo "network: {config: disabled}" >/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
            fi
        fi
    fi
}

# 创建网络接口配置文件
create_network_interfaces() {
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
}

# 清理DNS配置行
clean_dns_config() {
    # 检查是否有多个 dns-nameservers 行（只统计独立的配置行，不包括注释）
    dns_lines=$(grep -c "^\s*dns-nameservers" /etc/network/interfaces)
    if [ $dns_lines -gt 1 ]; then
        _blue "Found $dns_lines dns-nameservers lines, keeping only the last one"
        chattr -i /etc/network/interfaces
        # 创建临时文件
        temp_file=$(mktemp)
        # 标记是否已经保留了一个 dns-nameservers
        found=0
        # 从后往前读取文件
        tac /etc/network/interfaces | while IFS= read -r line; do
            # 检查是否是 dns-nameservers 行（不包括注释）
            if echo "$line" | grep -q "^\s*dns-nameservers"; then
                if [ $found -eq 0 ]; then
                    # 保留第一个遇到的（即原文件的最后一个）
                    echo "$line"
                    found=1
                fi
                # 跳过其他的 dns-nameservers 行
            else
                # 保留其他所有行
                echo "$line"
            fi
        done > "$temp_file"
        # 再次反转回正常顺序
        tac "$temp_file" > /etc/network/interfaces
        chattr +i /etc/network/interfaces
        rm -f "$temp_file"
    fi
}

# 清理手动IPv6配置
clean_manual_ipv6() {
    if grep -q "iface ${interface} inet6 manual" /etc/network/interfaces && grep -q "try_dhcp 1" /etc/network/interfaces; then
        chattr -i /etc/network/interfaces
        sed -i '/iface ${interface} inet6 manual/d' /etc/network/interfaces
        sed -i '/try_dhcp 1/d' /etc/network/interfaces
        chattr +i /etc/network/interfaces
    fi
}

# 配置fe80地址白名单
configure_fe80_whitelist() {
    if [[ "${ipv6_gateway_fe80}" == "N" ]]; then
        chattr -i /etc/network/interfaces
        echo "        up ip addr del $fe80_address dev $interface" >>/etc/network/interfaces
        remove_duplicate_lines "/etc/network/interfaces"
        chattr +i /etc/network/interfaces
    fi
}

# 系统重启检查
check_reboot_status() {
    if [ ! -f "/usr/local/bin/reboot_pve.txt" ]; then
        check_time_zone
        if [[ $dmidecode_output == *"Microsoft Corporation"* ]]; then
            sed -i 's#http://debian-archive.trafficmanager.net/debian#http://deb.debian.org/debian#g' /etc/apt/sources.list
            sed -i 's#http://debian-archive.trafficmanager.net/debian-security#http://security.debian.org/debian-security#g' /etc/apt/sources.list
            sed -i 's#http://debian-archive.trafficmanager.net/debian bullseye-updates#http://deb.debian.org/debian bullseye-updates#g' /etc/apt/sources.list
            sed -i 's#http://debian-archive.trafficmanager.net/debian bullseye-backports#http://deb.debian.org/debian bullseye-backports#g' /etc/apt/sources.list
        fi
        echo "1" >"/usr/local/bin/reboot_pve.txt"
        _green "Please execute reboot to reboot the system and then execute this script again"
        _green "Please wait for at least 20 seconds without automatically rebooting the system before executing this script."
        _green "请执行 reboot 重启系统后再次执行本脚本，再次使用SSH登录后请等待至少20秒未自动重启系统再执行本脚本"
        exit 1
    fi
}

configure_network_priority
run_preliminary_checks
check_and_configure_environment
setup_dns_check_service
fix_apt_issues1
ensure_system_paths
install_base_packages
handle_special_environments
check_system_requirements
detect_system_info
detect_network_interfaces
get_ipv6_gateway
if [ ! -f /usr/local/bin/pve_check_ipv6 ] || [ ! -s /usr/local/bin/pve_check_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_check_ipv6)" = "" ]; then
    check_ipv6
fi
get_fe80_address
if [[ $ipv6_gateway == fe80* ]]; then
    ipv6_gateway_fe80="Y"
else
    ipv6_gateway_fe80="N"
fi
ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
get_ipv6_prefixlen
ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
    echo "" >/usr/local/bin/pve_slaac_status
    echo "" >/usr/local/bin/fix_interfaces_ipv6_auto_type
else
    check_slaac_status
    ask_maximum_subnet
    rebuild_ipv6_address
fi
configure_cloud_init
create_network_interfaces
rebuild_interfaces
remove_duplicate_lines "/etc/network/interfaces"
if [ -f "/etc/network/interfaces.new" ]; then
    remove_duplicate_lines "/etc/network/interfaces.new"
fi
clean_dns_config
clean_manual_ipv6
rebuild_cloud_init
fix_interfaces_ipv6_auto_type
configure_fe80_whitelist
statistics_of_run_times
check_reboot_status

########## 正式开始PVE相关配置文件修改

# 处理中国IP的DNS配置
setup_cn_dns() {
    if [[ "${CN}" == true ]]; then
        echo "\nnameserver 223.5.5.5" >>/etc/resolv.conf
    fi
}

# 设置新的主机名
setup_hostname() {
    # 获取用户输入的新主机名
    local new_hostname=""
    while true; do
        _green "Please enter a new host name (can only contain English letters and numbers, not pure numbers or special characters, enter the default pve):"
        reading "请输入新的主机名(只能包含英文字母和数字,不能是纯数字或特殊字符,回车默认为pve):" new_hostname
        if [ -z "$new_hostname" ]; then
            new_hostname="pve"
            break
        elif ! [[ "$new_hostname" =~ ^[a-zA-Z0-9]+$ ]]; then
            _yellow "The hostname entered can only contain English letters and numbers, please re-enter it."
            _yellow "输入的主机名只能包含英文字母和数字,请重新输入。"
        else
            break
        fi
    done
    # 仅在主机名不同时进行更改
    hostname=$(hostname)
    if [ "${hostname}" != "$new_hostname" ]; then
        update_hosts_file "$new_hostname"
        update_hostname "$new_hostname"
    fi
}

# 更新hosts文件
update_hosts_file() {
    local new_hostname="$1"
    local hostname=$(hostname)
    chattr -i /etc/hosts
    hosts=$(grep -E "^[^#]*\s+${hostname}\s+${hostname}\$" /etc/hosts | grep -v "${main_ipv4}")
    if [ -n "${hosts}" ]; then
        sudo sed -i "s/^$(echo ${hosts} | sed 's/\//\\\//g')/# &/" /etc/hosts
    else
        echo "A record for ${main_ipv4} ${new_hostname} ${new_hostname} already exists, no need to add it"
        echo "已存在 ${main_ipv4} ${new_hostname} ${new_hostname} 的记录，无需添加"
    fi
    if ! grep -q "::1 localhost" /etc/hosts; then
        echo "::1 localhost" >>/etc/hosts
        echo "Added ::1 localhost to /etc/hosts"
        echo "已添加 ::1 localhost 到 /etc/hosts"
    fi
    if grep -q "^127\.0\.1\.1" /etc/hosts; then
        sed -i '/^127\.0\.1\.1/s/^/#/' /etc/hosts
        echo "Commented out lines starting with 127.0.1.1 in /etc/hosts"
        echo "已注释掉 /etc/hosts 中以 127.0.1.1 开头的行"
    fi
    hostname_bak=$(cat /etc/hostname.bak)
    if grep -q "^127\.0\.0\.1 ${hostname_bak}\.localdomain ${hostname_bak}$" /etc/hosts; then
        sed -i "s/^127\.0\.0\.1 ${hostname_bak}\.localdomain ${hostname_bak}/&\n${main_ipv4} ${new_hostname}.localdomain ${new_hostname}/" /etc/hosts
        echo "Replaced the line for ${hostname_bak} in /etc/hosts"
        echo "已替换 /etc/hosts 中 ${hostname_bak} 的记录"
    elif ! grep -q "^127\.0\.0\.1 localhost\.localdomain localhost$" /etc/hosts; then
        echo "${main_ipv4} ${new_hostname}.localdomain ${new_hostname}" >>/etc/hosts
        echo "Added ${main_ipv4} ${new_hostname}.localdomain ${new_hostname} to /etc/hosts"
        echo "已添加 ${main_ipv4} ${new_hostname}.localdomain ${new_hostname} 到 /etc/hosts"
    fi
    if ! grep -q "$new_hostname$" /etc/hosts; then
        echo "${main_ipv4} ${new_hostname}.localdomain ${new_hostname}" >>/etc/hosts
        echo "Added ${main_ipv4} ${new_hostname}.localdomain ${new_hostname} to /etc/hosts (fallback)"
        echo "已回退添加 ${main_ipv4} ${new_hostname}.localdomain ${new_hostname} 到 /etc/hosts"
    fi
    sleep 1
    if ! ping -c 1 -W 3 $(hostname) >/dev/null 2>&1; then
        _yellow "Hostname resolution failed, attempting to fix..."
        _yellow "主机名解析失败，正在修复..."
        current_hostname=$(hostname)
        if ! grep -q "^${main_ipv4}.*${current_hostname}$" /etc/hosts; then
            echo "${main_ipv4} ${current_hostname}" >> /etc/hosts
            _green "Added hostname resolution record: ${main_ipv4} ${current_hostname}"
            _green "已添加主机名解析记录: ${main_ipv4} ${current_hostname}"
        fi
        sleep 1
        if ping -c 1 -W 3 $(hostname) >/dev/null 2>&1; then
            _green "Hostname resolution successfully fixed"
            _green "主机名解析修复成功"
        else
            _red "Warning: Hostname resolution still failing, this may cause PVE SSL certificate creation to fail"
            _red "警告：主机名解析仍然失败，这可能导致 PVE SSL 证书创建失败"
        fi
    fi
    chattr +i /etc/hosts
}

# 更新系统主机名
update_hostname() {
    local new_hostname="$1"
    chattr -i /etc/hostname
    hostnamectl set-hostname "$new_hostname"
    chattr +i /etc/hostname
}

# 添加PVE GPG密钥
add_pve_gpg_key() {
    local version="$1"
    local keyfile
    case $version in
    stretch)
        keyfile="/etc/apt/trusted.gpg.d/proxmox-ve-release-4.x.gpg"
        [ ! -f "$keyfile" ] && wget -q http://download.proxmox.com/debian/proxmox-ve-release-4.x.gpg -O "$keyfile" && chmod +r "$keyfile"
        keyfile="/etc/apt/trusted.gpg.d/proxmox-ve-release-5.x.gpg"
        [ ! -f "$keyfile" ] && wget -q http://download.proxmox.com/debian/proxmox-ve-release-5.x.gpg -O "$keyfile" && chmod +r "$keyfile"
        ;;
    buster)
        keyfile="/etc/apt/trusted.gpg.d/proxmox-ve-release-5.x.gpg"
        [ ! -f "$keyfile" ] && wget -q http://download.proxmox.com/debian/proxmox-ve-release-5.x.gpg -O "$keyfile" && chmod +r "$keyfile"
        keyfile="/etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg"
        [ ! -f "$keyfile" ] && wget -q http://download.proxmox.com/debian/proxmox-ve-release-6.x.gpg -O "$keyfile" && chmod +r "$keyfile"
        ;;
    bullseye)
        keyfile="/etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg"
        [ ! -f "$keyfile" ] && wget -q http://download.proxmox.com/debian/proxmox-release-bullseye.gpg -O "$keyfile" && chmod +r "$keyfile"
        ;;
    bookworm)
        keyfile="/etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg"
        [ ! -f "$keyfile" ] && wget -q http://download.proxmox.com/debian/proxmox-release-bookworm.gpg -O "$keyfile" && chmod +r "$keyfile"
        ;;
    trixie)
        keyfile="/etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg"
        [ ! -f "$keyfile" ] && wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -O "$keyfile" && chmod +r "$keyfile"
        ;;
    *)
        echo "Unsupported Debian version: $version"
        return 1
        ;;
    esac
    echo "$keyfile"
}

# 添加PVE源(x86架构)
setup_x86_pve_repo() {
    local version="$1"
    local repo_url=""
    local keyfile
    keyfile=$(add_pve_gpg_key "$version") || return 1
    # 根据Debian版本选择仓库URL
    case $version in
    stretch|buster|bullseye|bookworm|trixie)
        repo_url="http://download.proxmox.com/debian/pve"
        ;;
    *)
        echo "Unsupported Debian version: $version, fallback to bullseye"
        version="bullseye"
        repo_url="http://download.proxmox.com/debian/pve"
        ;;
    esac
    # 判断是否需要使用CN镜像
    if [[ "${CN}" == true ]]; then
        repo_url="https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve"
    fi
    # Debian13及以上版本的系统使用 .sources 文件
    if [[ "$version" == "trixie" ]]; then
        yes Y | apt modernize-sources
        local sources_file="/etc/apt/sources.list.d/proxmox-trixie.sources"
        if [ ! -f "$sources_file" ]; then
            cat >"$sources_file" <<EOF
Types: deb
URIs: $repo_url
Suites: $version
Components: pve-test
Signed-By: $keyfile
EOF
            echo "Proxmox $version source written to $sources_file"
        fi
    else
        # 老系统直接写入 sources.list 无需转换
        if ! grep -q "^deb.*pve-no-subscription" /etc/apt/sources.list; then
            echo "deb $repo_url $version pve-no-subscription" >>/etc/apt/sources.list
            echo "Proxmox $version source appended to /etc/apt/sources.list"
        fi
    fi
}

# 测试和切换镜像源
test_and_switch_mirrors() {
    local version="$1"
    # 尝试运行apt-get update
    if ! apt-get update >/dev/null 2>&1; then
        _yellow "当前镜像源连接失败，将尝试切换其他镜像源..."
        # 定义备选镜像源数组
        mirrors=(
            "https://mirrors.bfsu.edu.cn/proxmox/debian/pve"          # 北京外国语大学镜像源
            "https://mirrors.nju.edu.cn/proxmox/debian/pve"           # 南京大学镜像源
            "https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve" # 清华大学镜像源
        )
        # 标记是否找到可用镜像源
        success=false
        # 遍历所有备选镜像源进行测试
        for mirror in "${mirrors[@]}"; do
            _green "正在测试镜像源: $mirror"
            # 替换sources.list中的仓库地址
            sed -i "s|^deb.*pve-no-subscription|deb $mirror $version pve-no-subscription|" /etc/apt/sources.list
            # 测试新镜像源
            if apt-get update >/dev/null 2>&1; then
                _green "成功切换到镜像源: $mirror"
                success=true
                break
            else
                _red "镜像源 $mirror 连接失败，尝试下一个..."
            fi
        done
        # 如果所有镜像源都失败，询问用户是否继续
        if [[ "$success" != true ]]; then
            _red "所有镜像源均连接失败。请检查网络连接或稍后重试。"
            if ! confirm_continue "是否仍然继续？"; then
                exit 1
            fi
        fi
    fi
}

# 设置ARM架构的PVE源
setup_arm_pve_repo() {
    local version="$1"
    case $version in
    stretch)
        # https://gitlab.com/minkebox/pimox
        curl https://gitlab.com/minkebox/pimox/-/raw/master/dev/KEY.gpg | apt-key add -
        curl https://gitlab.com/minkebox/pimox/-/raw/master/dev/pimox.list >/etc/apt/sources.list.d/pimox.list
        ;;
    buster|bullseye|bookworm)
        echo "deb  https://mirrors.lierfang.com/pxcloud/pxvirt bookworm main">/etc/apt/sources.list.d/pxvirt-sources.list
        curl -L https://mirrors.lierfang.com/pxcloud/lierfang.gpg -o /etc/apt/trusted.gpg.d/lierfang.gpg
        ;;
    trixie)
        echo "deb  https://mirrors.lierfang.com/pxcloud/pxvirt trixie main">/etc/apt/sources.list.d/pxvirt-sources.list
        curl -L https://mirrors.lierfang.com/pxcloud/lierfang.gpg -o /etc/apt/trusted.gpg.d/lierfang.gpg
        ;;
    *)
        _red "Error: Unsupported Debian version"
        if ! confirm_continue "是否要继续安装(识别到不是Debian9~Debian13的范围)？"; then
            exit 1
        fi
        echo "deb  https://mirrors.lierfang.com/pxcloud/pxvirt trixie main">/etc/apt/sources.list.d/pxvirt-sources.list
        curl -L https://mirrors.lierfang.com/pxcloud/lierfang.gpg -o /etc/apt/trusted.gpg.d/lierfang.gpg
        ;;
    esac
}

# 用户确认是否继续
confirm_continue() {
    local prompt_text="$1"
    local confirm=""
    _yellow "Do you want to continue the installation? (Enter to not continue the installation by default) (y/[n])"
    reading "$prompt_text(回车则默认不继续安装) (y/[n]) " confirm
    echo ""
    [ "$confirm" == "y" ]
}

# 修复APT问题函数
fix_apt_issues2() {
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
}

# 修复网络接口配置
fix_network_configs() {
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
}

# 检查并修复IPV6配置
fix_ipv6_configs() {
    # 检测IPV6是不是启用了dhcp但未分配IPV6地址
    if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
        if [ -f /etc/network/if-pre-up.d/cloud_inet6 ]; then
            rm -rf /etc/network/if-pre-up.d/cloud_inet6
        fi
        chattr -i /etc/network/interfaces
        sed -i '/iface ens4 inet6 \(manual\|dhcp\)/d' /etc/network/interfaces
        chattr +i /etc/network/interfaces
    fi
}

# 安装必需包
install_proxmox_packages() {
    # 部分机器中途service丢失了，尝试修复
    install_package service
    # esxi 开设的部分机器中含有冲突组件 firmware-ath9k-htc ，需要预先卸载
    if dpkg -S firmware-ath9k-htc >/dev/null 2>&1; then
        dpkg --remove --force-remove-reinstreq firmware-ath9k-htc
        apt --fix-broken install
        dpkg --configure -a
    fi
    # 正式安装PVE
    install_package proxmox-ve
    install_package postfix
    install_package open-iscsi
    rebuild_interfaces
}

# 配置vmbr0桥接接口
configure_vmbr0_bridge() {
    chattr -i /etc/network/interfaces
    if grep -q "vmbr0" "/etc/network/interfaces"; then
        _blue "vmbr0 already exists in /etc/network/interfaces"
        _blue "vmbr0 已存在在 /etc/network/interfaces"
    else
        # 没有IPV6地址，不存在slaac机制
        if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ] && [ ! -f /usr/local/bin/pve_last_ipv6 ]; then
            cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    address $ipv4_address
    gateway $ipv4_gateway
    bridge_ports $interface
    bridge_stp off
    bridge_fd 0
EOF
        # 有IPV6地址，只有一个IPV6地址，且后续仅使用一个IPV6地址，存在slaac机制
        elif [ -f /usr/local/bin/pve_slaac_status ] && [ $(cat /usr/local/bin/pve_maximum_subset) = false ] && [ ! -f /usr/local/bin/pve_last_ipv6 ]; then
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
        # 有IPV6地址，不只一个IPV6地址，一个用作网关，一个用作实际地址，二者不在同一子网内，不存在slaac机制
        elif [ -f /usr/local/bin/pve_last_ipv6 ]; then
            last_ipv6=$(cat /usr/local/bin/pve_last_ipv6)
            cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    address $ipv4_address
    gateway $ipv4_gateway
    bridge_ports $interface
    bridge_stp off
    bridge_fd 0

iface vmbr0 inet6 static
    address ${last_ipv6}
    gateway ${ipv6_gateway}

iface vmbr0 inet6 static
    address ${ipv6_address}/128
EOF
        # 有IPV6地址，只有一个IPV6地址，但后续使用最大IPV6子网范围，不存在slaac机制
        else
            cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    address $ipv4_address
    gateway $ipv4_gateway
    bridge_ports $interface
    bridge_stp off
    bridge_fd 0

iface vmbr0 inet6 static
    address ${ipv6_address}/128
    gateway ${ipv6_gateway}
EOF
        fi
    fi
    chattr +i /etc/network/interfaces
}

# 配置CT源和订阅
configure_pve_sources() {
    # 如果是国内服务器则替换CT源为国内镜像源
    if [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
        if [[ "${CN}" == true ]]; then
            cp -rf /usr/share/perl5/PVE/APLInfo.pm /usr/share/perl5/PVE/APLInfo.pm.bak
            sed -i 's|http://download.proxmox.com|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
            sed -i 's|http://mirrors.ustc.edu.cn/proxmox|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
        fi
    fi
    # 删除apt源中的无效订阅
    [ -f "/etc/apt/sources.list.d/pve-enterprise.list" ] && rm -f "/etc/apt/sources.list.d/pve-enterprise.list"
    [ -f "/etc/apt/sources.list.d/ceph.list" ] && rm -f "/etc/apt/sources.list.d/ceph.list"
    [ -f "/etc/apt/sources.list.d/pve-enterprise.sources" ] && rm -f "/etc/apt/sources.list.d/pve-enterprise.sources"
    [ -f "/etc/apt/sources.list.d/ceph.sources" ] && rm -f "/etc/apt/sources.list.d/ceph.sources"
}

# 确保DNS配置有效
configure_dns() {
    /usr/local/bin/check-dns.sh
    if [ ! -s "/etc/resolv.conf" ] || [ -z "$(grep -vE '^\s*#' /etc/resolv.conf)" ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
        if [[ "${CN}" == true ]]; then
            if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
                echo -e "\nnameserver 8.8.8.8\nnameserver 223.5.5.5\n" >/etc/resolv.conf
            else
                echo -e "\nnameserver 8.8.8.8\nnameserver 223.5.5.5\nnameserver 2001:4860:4860::8888\nnameserver 2001:4860:4860::8844" >/etc/resolv.conf
            fi
        else
            if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
                echo -e "\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n" >/etc/resolv.conf
            else
                echo -e "\nnameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 2001:4860:4860::8888\nnameserver 2001:4860:4860::8844" >/etc/resolv.conf
            fi
        fi
    fi
}

# 清理原有网卡配置
clean_network_interfaces() {
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
}

# 安装额外软件包
install_additional_packages() {
    /usr/local/bin/check-dns.sh
    apt-get update
    install_package sudo
    install_package iproute2
    case $version in
    stretch)
        install_package ifupdown
        ;;
    buster | bullseye | bookworm | trixie)
        install_package ifupdown2
        ;;
    *)
        exit 1
        ;;
    esac
    install_package novnc
    install_package cloud-init
    apt-get remove os-prober -y
    rebuild_cloud_init
    # install_package isc-dhcp-server
    chattr +i /etc/network/interfaces
}

# 配置防火墙和PVE代理
configure_firewall_and_proxy() {
    install_package ufw
    ufw disable
    echo LISTEN_IP="0.0.0.0" >/etc/default/pveproxy
}

setup_cn_dns
rebuild_cloud_init
setup_hostname
version=$(lsb_release -cs)
if [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
    setup_x86_pve_repo "$version"
elif [ "$system_arch" = "arm" ]; then
    setup_arm_pve_repo "$version"
fi
rebuild_interfaces
fix_apt_issues2
fix_network_configs
fix_ipv6_configs
configure_dns
install_proxmox_packages
configure_vmbr0_bridge
configure_pve_sources
clean_network_interfaces
install_additional_packages
configure_firewall_and_proxy

########## 打印安装成功的信息

# 打印安装后的信息
url="https://${main_ipv4}:8006/"

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
_green "If there is a problem logging in the web side is not up(Referring to the page reporting an error, it keeps loading or is normal), wait 10 seconds and restart the system to see"
_green "安装完毕，请打开HTTPS网页 $url"
_green "用户名、密码就是服务器所使用的用户名、密码(如root和root用户的密码)"
_green "如果登录无误请不要急着重启系统，去执行预配置环境的命令后再重启系统"
_green "如果登录有问题web端没起来(指的是网页报错，一直在加载还是正常的)，等待10秒后重启系统看看"
rm -rf /usr/local/bin/reboot_pve.txt
rm -rf /usr/local/bin/ifupdown2_installed.txt
rm -rf /usr/local/bin/fix_interfaces_ipv6_auto_type
