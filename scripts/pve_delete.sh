#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.12.31
# ./pve_delete.sh arg1 arg2
# arg 可填入虚拟机/容器的序号，可以有任意多个

# 输入解析
args=("$@")
num_args=${#args[@]}
declare -A ctip_array
declare -A vmip_array

# 虚拟机操作
vmids=$(qm list | awk '{if(NR>1)print $1}')
if [ -n "$vmids" ]; then
    # 遍历每个VMID的config，提取ip=到/24之间的内容
    for vmid in $vmids; do
        ip_address=$(qm config $vmid | grep -oP 'ip=\K[0-9.]+')
        if [ ! -z "$ip_address" ]; then
            vmip_array["$vmid"]=$ip_address
        fi
    done
    for key_1 in "${!vmip_array[@]}"; do
        for key_2 in "${args[@]}"; do
            if [ "$key_1" = "$key_2" ]; then
                ip_address="${vmip_array[$key_1]}"
                echo "Delete VMID $key_1 IP Address $ip_address Mapping"
                sed -i "/$ip_address:/d" /etc/iptables/rules.v4
                qm stop $key_1
                qm destroy $key_1
                rm -rf /var/lib/vz/images/$key_1*
                rm -rf vm"$key_1"
            fi
        done
    done
fi

# 容器操作
ctids=$(pct list | awk '{if(NR>1)print $1}')
if [ -n "$ctids" ]; then
    # 遍历每个CTID的config，提取ip=到/24之间的内容
    for ctid in $ctids; do
        ip_address=$(pct config $ctid | grep -oP 'ip=\K[0-9.]+')
        if [ ! -z "$ip_address" ]; then
            ctip_array["$ctid"]=$ip_address
        fi
    done
    for key_1 in "${!ctip_array[@]}"; do
        for key_2 in "${args[@]}"; do
            if [ "$key_1" = "$key_2" ]; then
                ip_address="${ctip_array[$key_1]}"
                echo "Delete CTID $key_1 IP Address $ip_address Mapping"
                sed -i "/$ip_address:/d" /etc/iptables/rules.v4
                pct stop "$key_1"
                pct destroy "$key_1"
                rm -rf ct"$key_1"
            fi
        done
    done
fi

# 其他相关操作
cat /etc/iptables/rules.v4 | iptables-restore
service networking restart
systemctl restart networking.service
if [ -f "/usr/local/bin/ndpresponder" ]; then
    systemctl restart ndpresponder.service
fi
