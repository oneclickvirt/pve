complete_ipv6_parts() {
    local ipv6_address=$1
    IFS=":" read -r -a parts <<< "$ipv6_address"
    local all_parts_full=true
    for part in "${parts[@]}"; do
        local length=${#part}
        if (( length < 4 )); then
            all_parts_full=false
            break
        fi
    done
    if $all_parts_full; then
        echo "$ipv6_address"
        return
    fi
    for i in "${!parts[@]}"; do
        local part="${parts[$i]}"
        local length=${#part}
        if (( length < 4 )); then
            local num_zeros=$(( 4 - length ))
            parts[$i]=$(printf "%0${num_zeros}d%s" 0 "$part")
        fi
    done
    local result=$(IFS=:; echo "${parts[*]}")
    echo "$result"
}

extract_origin_ipv6() {
    input_string="$1"
    num_characters="$2"
    # 拼接整体
    IFS=':' read -r -a array <<< "$input_string"
    origin=""
    for part in "${array[@]}"; do
        len=${#part}
        if ((len <= 4)); then
            origin+="$part"
        else
            for ((i = 0; i < len; i += 4)); do
                origin+="${part:$i:4}"
                if ((i + 4 < len)); then
                    origin+=":"
                fi
            done
        fi
    done
    # 是不是被4整除，不整除则多一位做子网前缀
    max_quotient=$((${num_characters} / 4))
    temp_remainder=$((${num_characters} % 4))
    if [ $temp_remainder -ne 0 ]; then
        max_quotient=$((max_quotient + 1))
    fi
    temp_result=$(echo "${origin:0:$max_quotient}")
    # 非4整除补全
    length=${#temp_result}
    remainder=$((length % 4))
    zeros_to_add=$((4 - remainder))
    if [ $remainder -ne 0 ]; then
        for ((i = 0; i < $zeros_to_add; i++)); do
            temp_result+="0"
        done
    fi
    # 插入:符号
    result=$(echo $temp_result | sed 's/.\{4\}/&:/g;s/:$//')
    colon_count=$(grep -o ":" <<< "$result" | wc -l)
    if [ "$colon_count" -lt 7 ]; then
        additional_colons=$((7 - colon_count))
        for ((i=0; i<additional_colons; i++)); do
            result+=":"
        done
    fi
    echo "$result"
}

check_interface(){
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

# 查找最佳ARM镜像源
find_best_arm_mirror() {
    arch_pve_urls=(
        "https://global.mirrors.apqa.cn"
        "https://mirrors.apqa.cn"
        "https://hk.mirrors.apqa.cn"
        "https://mirrors.lierfang.com"
        "https://de.mirrors.apqa.cn"
    )
    min_ping=9999
    min_ping_url=""
    for url in "${arch_pve_urls[@]}"; do
        url_without_protocol="${url#https://}"
        ping_result=$(ping -c 3 -q "$url_without_protocol" | grep -oP '(?<=min/avg/max/mdev = )[0-9.]+')
        avg_ping=$(echo "$ping_result" | cut -d '/' -f 2)
        if [ ! -z "$avg_ping" ]; then
            echo "Ping [$url_without_protocol]: $avg_ping ms"
            if (($(echo "$avg_ping < $min_ping" | bc -l))); then
                min_ping="$avg_ping"
                min_ping_url="$url"
            fi
        else
            _yellow "Unable to get ping [$url_without_protocol]"
        fi
    done
    # 验证最佳镜像源连接是否正常
    if [ -n "$min_ping_url" ]; then
        echo "Trying to fetch the page using curl from: $min_ping_url"
        if curl -s -o /dev/null "$min_ping_url"; then
            echo "curl succeeded, using the URL: $min_ping_url"
        else
            echo "curl failed with URL: $min_ping_url"
            # 尝试其他镜像源
            for url in "${arch_pve_urls[@]}"; do
                if [ "$url" != "$min_ping_url" ]; then
                    echo "Trying the next URL: $url"
                    if curl -s -o /dev/null "$url"; then
                        echo "curl succeeded, using the URL: $url"
                        min_ping_url="$url"
                        break
                    else
                        echo "curl failed with URL: $url"
                    fi
                fi
            done
        fi
    fi
}

# 提取物理网卡名字
interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
check_interface

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

user_ip="172.16.1.${num}"

# 通过官方地址获取镜像源
# if [[ -z "${CN}" || "${CN}" != true ]]; then
#     if [ ! -f "/var/lib/vz/template/cache/${en_system}-arm64-${version}-cloud.tar.xz" ]; then
#         # curl -o "/var/lib/vz/template/cache/${en_system}-arm64-${version}-cloud.tar.xz" "https://jenkins.linuxcontainers.org/view/LXC/job/image-${en_system}/architecture=arm64,release=${version},variant=cloud/lastSuccessfulBuild/artifact/rootfs.tar.xz"
#     fi
# else
#     # https://mirror.tuna.tsinghua.edu.cn/lxc-images/images/
#     URL="https://mirror.tuna.tsinghua.edu.cn/lxc-images/images/${en_system}/${version}/arm64/cloud/"
#     HTML=$(curl -s "$URL")
#     folder_links_dates=$(echo "$HTML" | grep -oE '<a href="([^"]+)".*date">([^<]+)' | sed -E 's/<a href="([^"]+)".*date">([^<]+)/\1 \2/')
#     sorted_links=$(echo "$folder_links_dates" | sort -k2 -r)
#     latest_folder_link=$(echo "$sorted_links" | head -n 1 | awk '{print $1}')
#     latest_folder_url="${URL}${latest_folder_link}"
#     if [ ! -f "/var/lib/vz/template/cache/${en_system}-arm64-${version}-cloud.tar.xz" ]; then
#         curl -o "/var/lib/vz/template/cache/${en_system}-arm64-${version}-cloud.tar.xz" "${latest_folder_url}/rootfs.tar.xz"
#     fi
# fi

# LXC容器通过API获取镜像地址
# response=$(curl -sSL -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/oneclickvirt/pve_lxc_images/releases/tags/${en_system}" | grep -oP '"name": "\K[^"]+\.zst' | awk 'NR%2==1')
# # 如果 https://api.github.com/ 请求失败，则使用 https://githubapi.spiritlhl.workers.dev/ ，此时可能宿主机无IPV4网络
# if [ -z "$response" ]; then
#     response=$(curl -sSL -H "Accept: application/vnd.github.v3+json" "https://githubapi.spiritlhl.workers.dev/repos/oneclickvirt/pve_lxc_images/releases/tags/${en_system}" | grep -oP '"name": "\K[^"]+\.zst' | awk 'NR%2==1')
# fi
# # 如果 https://githubapi.spiritlhl.workers.dev/ 请求失败，则使用 https://githubapi.spiritlhl.top/ ，此时可能宿主机在国内
# if [ -z "$response" ]; then
#     response=$(curl -sSL -H "Accept: application/vnd.github.v3+json" "https://githubapi.spiritlhl.top/repos/oneclickvirt/pve_lxc_images/releases/tags/${en_system}" | grep -oP '"name": "\K[^"]+\.zst' | awk 'NR%2==1')
# fi
