#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.02.28
# ./pve_delete.sh arg1 arg2
# arg 可填入虚拟机/容器的序号，可以有任意多个；或使用 all 删除全部
# 日志 /var/log/pve_delete.log

set -e
set -u

# 日志函数
log_file="/var/log/pve_delete.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$log_file"
}

# 检查VM/CT状态函数
check_vmct_status() {
    local id=$1
    local type=$2
    local max_attempts=5
    for ((i=1; i<=max_attempts; i++)); do
        if [ "$type" = "vm" ]; then
            # 检查VM是否已经停止
            if [ "$(qm status "$id" 2>/dev/null | grep -w "status:" | awk '{print $2}')" = "stopped" ]; then
                return 0
            fi
            elif [ "$type" = "ct" ]; then
            # 检查容器是否已经停止
            if [ "$(pct status "$id" 2>/dev/null | grep -w "status:" | awk '{print $2}')" = "stopped" ]; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# 安全删除文件/路径
safe_remove() {
    local path=$1
    if [ -e "$path" ]; then
        log "Removing: $path"
        rm -rf "$path"
    fi
}

# 防火墙后端自动识别（优先读取 interfaces 配置痕迹）
FW_BACKEND=""

get_interfaces_content() {
    {
        [ -f /etc/network/interfaces ] && cat /etc/network/interfaces
        [ -d /etc/network/interfaces.d ] && cat /etc/network/interfaces.d/* 2>/dev/null || true
    } 2>/dev/null || true
}

detect_firewall_backend() {
    local interfaces_content
    interfaces_content=$(get_interfaces_content)
    local has_nft=1
    local has_ipt=1

    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        has_nft=0
    fi
    if command -v iptables >/dev/null 2>&1; then
        has_ipt=0
    fi

    if echo "$interfaces_content" | grep -qiE '(^|[^a-z])(nft|nftables)($|[^a-z])'; then
        FW_BACKEND="nft"
    elif echo "$interfaces_content" | grep -qiE '(^|[^a-z])(iptables|ip6tables|netfilter-persistent)($|[^a-z])'; then
        FW_BACKEND="iptables"
    elif [ -f /etc/nftables.conf ] && [ $has_nft -eq 0 ]; then
        FW_BACKEND="nft"
    elif [ -f /etc/iptables/rules.v4 ] && [ $has_ipt -eq 0 ]; then
        FW_BACKEND="iptables"
    elif [ $has_nft -eq 0 ] && [ $has_ipt -ne 0 ]; then
        FW_BACKEND="nft"
    elif [ $has_ipt -eq 0 ]; then
        FW_BACKEND="iptables"
    else
        FW_BACKEND="nft"
    fi

    log "Detected firewall backend: ${FW_BACKEND}"
}

use_nft_backend() {
    [ "$FW_BACKEND" = "nft" ] && command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1
}

should_restart_ndpresponder() {
    if [ ! -f "/usr/local/bin/ndpresponder" ]; then
        return 1
    fi
    if ! systemctl list-unit-files ndpresponder.service >/dev/null 2>&1; then
        return 1
    fi
    if systemctl is-enabled --quiet ndpresponder.service 2>/dev/null || systemctl is-active --quiet ndpresponder.service 2>/dev/null; then
        return 0
    fi
    return 1
}

# 清理IPv6 NAT映射规则
cleanup_ipv6_nat_rules() {
    local vmctid=$1
    local appended_file="/usr/local/bin/pve_appended_content.txt"
    local rules_file="/usr/local/bin/ipv6_nat_rules.sh"
    local used_ips_file="/usr/local/bin/pve_used_vmbr1_ips.txt"
    if [ -s "$appended_file" ]; then
        log "Cleaning up IPv6 NAT rules for VM $vmctid"
        local vm_internal_ipv6="2001:db8:1::${vmctid}"
        local host_external_ipv6=""
        if use_nft_backend; then
            # nftables: find and remove matching rules
            host_external_ipv6=$(nft list chain ip6 nat prerouting 2>/dev/null | grep "dnat to $vm_internal_ipv6" | sed 's/.*ip6 daddr \([^ ]*\).*/\1/' | head -1)
            if [ -n "$host_external_ipv6" ]; then
                log "Removing nftables IPv6 NAT rules: $vm_internal_ipv6 -> $host_external_ipv6"
                for chain in prerouting postrouting; do
                    nft -a list chain ip6 nat $chain 2>/dev/null | grep -E "$vm_internal_ipv6|$host_external_ipv6" | sed 's/.*# handle //' | awk '{print $1}' | while read -r h; do
                        nft delete rule ip6 nat $chain handle "$h" 2>/dev/null || true
                    done
                done
                # 同时清除该隙道IPv6地址的ICMPv6 ping屏蔽规则
                nft -a list chain ip6 raw prerouting 2>/dev/null | grep "$host_external_ipv6" | sed 's/.*# handle //' | awk '{print $1}' | while read -r h; do
                    nft delete rule ip6 raw prerouting handle "$h" 2>/dev/null || true
                done
                printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf
                nft list ruleset >> /etc/nftables.conf
            fi
        else
            # iptables fallback
            if [ -f "$rules_file" ]; then
                host_external_ipv6=$(grep "DNAT --to-destination $vm_internal_ipv6" "$rules_file" | head -1 | grep -oP "(?<=-d )[^ ]+" || true)
                if [ -n "$host_external_ipv6" ]; then
                    log "Removing iptables IPv6 NAT rules: $vm_internal_ipv6 -> $host_external_ipv6"
                    ip6tables -t nat -D PREROUTING -d "$host_external_ipv6" -j DNAT --to-destination "$vm_internal_ipv6" 2>/dev/null || true
                    ip6tables -t nat -D POSTROUTING -s "$vm_internal_ipv6" -j SNAT --to-source "$host_external_ipv6" 2>/dev/null || true
                    sed -i "/DNAT --to-destination $vm_internal_ipv6/d" "$rules_file" 2>/dev/null || true
                    sed -i "/SNAT --to-source $host_external_ipv6/d" "$rules_file" 2>/dev/null || true

                    systemctl daemon-reload
                    systemctl restart ipv6nat.service 2>/dev/null || true
                fi
            fi
        fi
        if [ -n "$host_external_ipv6" ] && [ -f "$used_ips_file" ]; then
            sed -i "/^${host_external_ipv6}$/d" "$used_ips_file" 2>/dev/null || true
            log "Released IPv6 address: $host_external_ipv6"
        fi
    fi
}

# 清理vmbr2直接分配IPv6（HE隧道/原生子网）模式的ICMPv6 ping屏蔽规则
cleanup_vmbr2_icmpv6_rule() {
    local vmctid=$1
    if [ ! -f /usr/local/bin/pve_check_ipv6 ]; then
        return 0
    fi
    local host_ipv6
    host_ipv6=$(cat /usr/local/bin/pve_check_ipv6)
    local ipv6_addr="${host_ipv6%:*}:${vmctid}"
    log "Cleaning up ICMPv6 ping block rule for $ipv6_addr"
    if use_nft_backend; then
        nft -a list chain ip6 raw prerouting 2>/dev/null | grep "$ipv6_addr" | sed 's/.*# handle //' | awk '{print $1}' | while read -r h; do
            nft delete rule ip6 raw prerouting handle "$h" 2>/dev/null || true
        done
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf
        nft list ruleset >> /etc/nftables.conf
    else
        local ipv6_prefixlen_del=""
        [ -f /usr/local/bin/pve_ipv6_prefixlen ] && ipv6_prefixlen_del=$(cat /usr/local/bin/pve_ipv6_prefixlen)
        if [ -n "$ipv6_prefixlen_del" ]; then
            local local_prefix_del="${host_ipv6%:*}:/${ipv6_prefixlen_del}"
            ip6tables -t raw -D PREROUTING -d "$ipv6_addr" -s "$local_prefix_del" -p icmpv6 --icmpv6-type echo-request -j ACCEPT 2>/dev/null || true
            ip6tables -t raw -D PREROUTING -d "$ipv6_addr" -s fe80::/10 -p icmpv6 --icmpv6-type echo-request -j ACCEPT 2>/dev/null || true
        fi
        ip6tables -t raw -D PREROUTING -d "$ipv6_addr" -p icmpv6 --icmpv6-type echo-request -j DROP 2>/dev/null || true
        if command -v ip6tables-save >/dev/null 2>&1; then
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        fi
    fi
}

# 清理VM相关文件
cleanup_vm_files() {
    local vmid=$1
    log "Cleaning up files for VM $vmid"
    # 获取所有存储名称
    pvesm status | awk 'NR > 1 {print $1}' | while read -r storage; do
        # 遍历存储并列出相关的卷
        pvesm list "$storage" | awk -v vmid="$vmid" '$5 == vmid {print $1}' | while read -r volid; do
            vol_path=$(pvesm path "$volid" 2>/dev/null || true)
            if [ -n "$vol_path" ]; then
                safe_remove "$vol_path"
            else
                log "Warning: Failed to resolve path for volume $volid in storage $storage"
            fi
        done
    done
    rm -rf "/root/vm${vmid}"
    # 清理 macOS VM 专属 opencore ISO（由 buildvm_macos.sh 的 SMBIOS 注入流程生成）
    local opencore_iso="/var/lib/vz/template/iso/opencore_${vmid}.iso"
    if [ -f "$opencore_iso" ]; then
        log "Removing per-VM opencore ISO: $opencore_iso"
        rm -f "$opencore_iso"
    fi
}

# 清理CT相关文件
cleanup_ct_files() {
    local ctid=$1
    log "Cleaning up files for CT $ctid"
    # 获取所有存储名称
    pvesm status | awk 'NR > 1 {print $1}' | while read -r storage; do
        # 遍历存储并列出相关的卷
        pvesm list "$storage" | awk -v ctid="$ctid" '$5 == ctid {print $1}' | while read -r volid; do
            vol_path=$(pvesm path "$volid" 2>/dev/null || true)
            if [ -n "$vol_path" ]; then
                safe_remove "$vol_path"
            else
                log "Warning: Failed to resolve path for volume $volid in storage $storage"
            fi
        done
    done
    rm -rf "/root/ct${ctid}"
}

# 处理VM删除
handle_vm_deletion() {
    local vmid=$1
    local ip_address=$2
    log "Starting deletion process for VM $vmid (IP: $ip_address)"
    # 解锁VM
    log "Attempting to unlock VM $vmid"
    qm unlock "$vmid" 2>/dev/null || true
    # 停止VM
    log "Stopping VM $vmid"
    qm stop "$vmid" 2>/dev/null || true
    # 检查VM是否完全停止
    if ! check_vmct_status "$vmid" "vm"; then
        log "Warning: VM $vmid did not stop cleanly, attempting destroy anyway"
    fi
    # 删除VM
    log "Destroying VM $vmid"
    qm destroy "$vmid"
    # 清理IPv6 NAT映射规则
    cleanup_ipv6_nat_rules "$vmid"
    # 清理vmbr2模式 ICMPv6 屏蔽规则
    cleanup_vmbr2_icmpv6_rule "$vmid"
    # 清理相关文件
    cleanup_vm_files "$vmid"
    # 更新防火墙规则
    if [ -n "$ip_address" ]; then
        log "Removing firewall rules for IP $ip_address"
        if use_nft_backend; then
            for chain in prerouting postrouting; do
                nft -a list chain ip nat $chain 2>/dev/null | grep "$ip_address" | sed 's/.*# handle //' | awk '{print $1}' | while read -r h; do
                    nft delete rule ip nat $chain handle "$h" 2>/dev/null || true
                done
            done
        else
            [ -f /etc/iptables/rules.v4 ] && sed -i "/$ip_address:/d" /etc/iptables/rules.v4
        fi
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
    if ! check_vmct_status "$ctid" "ct"; then
        log "Warning: CT $ctid did not stop cleanly, attempting destroy anyway"
    fi
    # 删除容器
    log "Destroying CT $ctid"
    pct destroy "$ctid"
    # 清理相关文件
    cleanup_ct_files "$ctid"
    # 清理IPv6 NAT映射规则
    cleanup_ipv6_nat_rules "$ctid"
    # 清理vmbr2模式 ICMPv6 屏蔽规则
    cleanup_vmbr2_icmpv6_rule "$ctid"
    # 更新防火墙规则
    if [ -n "$ip_address" ]; then
        log "Removing firewall rules for IP $ip_address"
        if use_nft_backend; then
            for chain in prerouting postrouting; do
                nft -a list chain ip nat $chain 2>/dev/null | grep "$ip_address" | sed 's/.*# handle //' | awk '{print $1}' | while read -r h; do
                    nft delete rule ip nat $chain handle "$h" 2>/dev/null || true
                done
            done
        else
            [ -f /etc/iptables/rules.v4 ] && sed -i "/$ip_address:/d" /etc/iptables/rules.v4
        fi
    fi
}

# 主函数
main() {
    # 检查参数
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <VMID/CTID|all> [VMID/CTID...]"
        exit 1
    fi
    detect_firewall_backend
    # 创建唯一ID数组
    declare -A unique_ids
    local delete_all=false
    for arg in "$@"; do
        if [ "${arg,,}" = "all" ]; then
            delete_all=true
        elif [[ "$arg" =~ ^[0-9]+$ ]]; then
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
    if [ "$delete_all" = true ]; then
        log "Deleting all existing VMs and CTs"
        for vmid in $vmids; do
            unique_ids["$vmid"]=1
        done
        for ctid in $ctids; do
            unique_ids["$ctid"]=1
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
    # 重建防火墙规则
    log "Rebuilding firewall rules..."
    if use_nft_backend; then
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf
        nft list ruleset >> /etc/nftables.conf
    else
        if [ -f "/etc/iptables/rules.v4" ]; then
            cat /etc/iptables/rules.v4 | iptables-restore
        else
            log "Warning: iptables rules file not found"
        fi
    fi
    # 重启ndpresponder服务
    if should_restart_ndpresponder; then
        log "Restarting ndpresponder service..."
        systemctl restart ndpresponder.service 2>/dev/null || true
    else
        log "Skipping ndpresponder restart: service not in use"
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
