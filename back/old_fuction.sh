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

# 提取物理网卡名字
interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
check_interface