#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2024.03.12
# ./pve_delete.sh arg1 arg2
# arg 可填入虚拟机/容器的序号，可以有任意多个
# 日志 /var/log/pve_delete.log

# 启用错误检查
set -e
set -u

# 日志函数
log_file="/var/log/pve_delete.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$log_file"
}

# 检查VM状态函数
check_vm_status() {
    local id=$1
    local type=$2
    local max_attempts=5

    for ((i=1; i<=max_attempts; i++)); do
        if [ "$type" = "vm" ]; then
            if ! qm status "$id" &>/dev/null; then
                return 0
            fi
        elif [ "$type" = "ct" ]; then
            if ! pct status "$id" &>/dev/null; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# 安全删除函数
safe_remove() {
    local path=$1
    if [ -e "$path" ]; then
        log "Removing: $path"
        rm -rf "$path"
    fi
}

# 处理VM删除
handle_vm_deletion() {
    local vmid=$1
    local ip_address=$2

    log "Starting deletion process for VM $vmid (IP: $ip_address)"
    
    # 先解锁
    log "Attempting to unlock VM $vmid"
    qm unlock "$vmid" 2>/dev/null || true
    
    # 停止VM
    log "Stopping VM $vmid"
    qm stop "$vmid" 2>/dev/null || true
    
    # 检查VM是否完全停止
    if ! check_vm_status "$vmid" "vm"; then
        log "Warning: VM $vmid did not stop cleanly"
        return 1
    fi

    # 同步文件系统
    sync
    
    # 删除VM
    log "Destroying VM $vmid"
    qm destroy "$vmid"
    
    # 清理相关文件
    safe_remove "/var/lib/vz/images/$vmid*"
    safe_remove "vm$vmid"
    
    # 更新iptables规则
    if [ -n "$ip_address" ]; then
        log "Removing iptables rules for IP $ip_address"
        sed -i "/$ip_address:/d" /etc/iptables/rules.v4
    fi
}

# 处理CT删除
handle_ct_deletion() {
    local ctid=$1
    local ip_address=$2

    log "Starting deletion process for CT $ctid (IP: $ip_address)"
    
    # 停止容器
    log "Stopping CT $ctid"
    pct stop "$ctid" 2>/dev/null || true
    
    # 检查容器是否完全停止
    if ! check_vm_status "$ctid" "ct"; then
        log "Warning: CT $ctid did not stop cleanly"
        return 1
    fi

    # 同步文件系统
    sync
    
    # 删除容器
    log "Destroying CT $ctid"
    pct destroy "$ctid"
    
    # 清理相关文件
    safe_remove "ct$ctid"
    
    # 更新iptables规则
    if [ -n "$ip_address" ]; then
        log "Removing iptables rules for IP $ip_address"
        sed -i "/$ip_address:/d" /etc/iptables/rules.v4
    fi
}

# 主函数
main() {
    # 检查参数
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <VMID/CTID> [VMID/CTID...]"
        exit 1
    fi

    # 创建唯一ID数组
    declare -A unique_ids
    for arg in "$@"; do
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
            unique_ids["$arg"]=1
        else
            log "Warning: Invalid ID format: $arg"
        fi
    done

    # 获取所有VM和CT的IP信息
    declare -A vmip_array
    declare -A ctip_array

    # 获取VM的IP
    vmids=$(qm list | awk '{if(NR>1)print $1}')
    if [ -n "$vmids" ]; then
        for vmid in $vmids; do
            ip_address=$(qm config "$vmid" | grep -oP 'ip=\K[0-9.]+' || true)
            if [ -n "$ip_address" ]; then
                vmip_array["$vmid"]=$ip_address
            fi
        done
    fi

    # 获取CT的IP
    ctids=$(pct list | awk '{if(NR>1)print $1}')
    if [ -n "$ctids" ]; then
        for ctid in $ctids; do
            ip_address=$(pct config "$ctid" | grep -oP 'ip=\K[0-9.]+' || true)
            if [ -n "$ip_address" ]; then
                ctip_array["$ctid"]=$ip_address
            fi
        done
    fi

    # 处理删除操作
    for id in "${!unique_ids[@]}"; do
        if [ -n "${vmip_array[$id]+x}" ]; then
            handle_vm_deletion "$id" "${vmip_array[$id]}"
        elif [ -n "${ctip_array[$id]+x}" ]; then
            handle_ct_deletion "$id" "${ctip_array[$id]}"
        else
            log "Warning: ID $id not found in existing VMs or CTs"
        fi
    done

    # 重建iptables规则
    log "Rebuilding iptables rules..."
    if [ -f "/etc/iptables/rules.v4" ]; then
        cat /etc/iptables/rules.v4 | iptables-restore
    else
        log "Warning: iptables rules file not found"
    fi

    # 重启ndpresponder服务（如果存在）
    if [ -f "/usr/local/bin/ndpresponder" ]; then
        log "Restarting ndpresponder service..."
        systemctl restart ndpresponder.service
    fi

    log "Operation completed successfully"
    echo "Finish."
}

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    exit 1
fi

# 运行主函数
main "$@"