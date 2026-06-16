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

is_ipv4_address() {
    local ip=$1
    local IFS=.
    local -a octets=()
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    local octet
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" -le 255 ] || return 1
    done
    return 0
}

extract_first_ipv4_from_config() {
    local config_text=$1
    local candidate=""

    while IFS= read -r candidate; do
        if is_ipv4_address "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done < <(printf '%s\n' "$config_text" | grep -oE '(^|[,[:space:]])ip=([0-9]{1,3}\.){3}[0-9]{1,3}' | sed 's/.*ip=//')

    printf ''
    return 0
}

delete_nft_ipv4_rules_for_ip() {
    local ip_address=$1
    local chain=""

    [ -n "$ip_address" ] || return 0
    for chain in prerouting postrouting; do
        nft -a list chain ip nat "$chain" 2>/dev/null |
            awk -v ip="$ip_address" '
                BEGIN {
                    escaped = ip
                    gsub(/\./, "\\.", escaped)
                    boundary_re = "(^|[^0-9.])" escaped "([^0-9.]|$)"
                }
                $0 ~ boundary_re && match($0, /# handle [0-9]+/) {
                    handle = substr($0, RSTART + 9, RLENGTH - 9)
                    print handle
                }
            ' |
            while IFS= read -r h; do
                [ -n "$h" ] && nft delete rule ip nat "$chain" handle "$h" 2>/dev/null || true
            done
    done
}

delete_iptables_ipv4_rules_for_ip() {
    local ip_address=$1
    local escaped_ip=""

    [ -n "$ip_address" ] || return 0
    [ -f /etc/iptables/rules.v4 ] || return 0
    escaped_ip="${ip_address//./\\.}"
    sed -i -E "/(^|[^0-9.])${escaped_ip}([^0-9.]|$)/d" /etc/iptables/rules.v4
}

declare -A STORAGE_VOLUMES_BY_ID

build_storage_volume_index() {
    local storages=""
    local storage=""
    local volume_rows=""
    local volid=""
    local owner_id=""

    STORAGE_VOLUMES_BY_ID=()
    storages=$(pvesm status 2>/dev/null | awk 'NR > 1 {print $1}' || true)
    while IFS= read -r storage; do
        [ -z "$storage" ] && continue
        volume_rows=$(pvesm list "$storage" 2>/dev/null | awk 'NR > 1 && $5 ~ /^[0-9]+$/ {print $1, $5}' || true)
        while read -r volid owner_id; do
            [ -z "$volid" ] && continue
            [ -z "$owner_id" ] && continue
            STORAGE_VOLUMES_BY_ID["$owner_id"]+="${volid}"$'\n'
        done <<<"$volume_rows"
    done <<<"$storages"
}

cleanup_indexed_volume_files() {
    local id=$1
    local kind=$2
    local volid=""
    local vol_path=""
    local volumes="${STORAGE_VOLUMES_BY_ID[$id]-}"

    if [ -z "$volumes" ]; then
        log "No indexed storage volumes found for ${kind} $id"
        return 0
    fi

    while IFS= read -r volid; do
        [ -z "$volid" ] && continue
        vol_path=$(pvesm path "$volid" 2>/dev/null || true)
        if [ -n "$vol_path" ]; then
            safe_remove "$vol_path"
        else
            log "Warning: Failed to resolve path for volume $volid"
        fi
    done <<<"$volumes"
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
            host_external_ipv6=$(nft list chain ip6 nat prerouting 2>/dev/null | grep -F "dnat to $vm_internal_ipv6" | sed 's/.*ip6 daddr \([^ ]*\).*/\1/' | head -1)
            if [ -n "$host_external_ipv6" ]; then
                log "Removing nftables IPv6 NAT rules: $vm_internal_ipv6 -> $host_external_ipv6"
                for chain in prerouting postrouting; do
                    nft -a list chain ip6 nat $chain 2>/dev/null | grep -F -e "$vm_internal_ipv6" -e "$host_external_ipv6" | sed 's/.*# handle //' | awk '{print $1}' | while read -r h; do
                        nft delete rule ip6 nat $chain handle "$h" 2>/dev/null || true
                    done
                done
                # 同时清除该隙道IPv6地址的ICMPv6 ping屏蔽规则
                nft -a list chain ip6 raw prerouting 2>/dev/null | grep -F "$host_external_ipv6" | sed 's/.*# handle //' | awk '{print $1}' | while read -r h; do
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
        nft -a list chain ip6 raw prerouting 2>/dev/null | grep -F "$ipv6_addr" | sed 's/.*# handle //' | awk '{print $1}' | while read -r h; do
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
    cleanup_indexed_volume_files "$vmid" "VM"
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
    cleanup_indexed_volume_files "$ctid" "CT"
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
            delete_nft_ipv4_rules_for_ip "$ip_address"
        else
            delete_iptables_ipv4_rules_for_ip "$ip_address"
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
            delete_nft_ipv4_rules_for_ip "$ip_address"
        else
            delete_iptables_ipv4_rules_for_ip "$ip_address"
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
            ip_address=$(extract_first_ipv4_from_config "$(qm config "$vmid" 2>/dev/null || true)")
            vmip_array["$vmid"]="${ip_address:-}"
        done
    fi
    # 获取CT的IP
    ctids=$(pct list | awk '{if(NR>1)print $1}')
    if [ -n "$ctids" ]; then
        for ctid in $ctids; do
            ip_address=$(extract_first_ipv4_from_config "$(pct config "$ctid" 2>/dev/null || true)")
            ctip_array["$ctid"]="${ip_address:-}"
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
    build_storage_volume_index
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
            iptables-restore < /etc/iptables/rules.v4
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
