#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.08.27

########## 预设部分输出和部分中间变量

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }
is_noninteractive() {
    case "${noninteractive:-}" in
    true | TRUE | True | 1 | yes | YES | Yes | y | Y)
        return 0
        ;;
    esac
    case "${NONINTERACTIVE:-}" in
    true | TRUE | True | 1 | yes | YES | Yes | y | Y)
        return 0
        ;;
    esac
    return 1
}
reading() {
    local prompt="$1"
    local var_name="$2"
    local default_value="${3:-}"
    if is_noninteractive; then
        printf -v "$var_name" '%s' "$default_value"
        _yellow "noninteractive=true, using default for ${var_name}: ${default_value:-<empty>}"
    else
        read -rp "$(_green "$prompt")" "$var_name"
    fi
}
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    echo "No UTF-8 locale found"
    echo "未找到 UTF-8 区域设置"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    echo "Locale set to $utf8_locale"
    echo "区域设置已切换为 $utf8_locale"
fi
rm -rf /usr/local/bin/build_backend_pve.txt

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
    if [ "${WITHOUTCDN^^}" = "TRUE" ]; then
        export cdn_success_url=""
        _yellow "WITHOUTCDN=TRUE, skip CDN acceleration"
        _yellow "WITHOUTCDN=TRUE，跳过 CDN 加速"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
        _yellow "检测到可用 CDN，使用 CDN 加速"
    else
        _yellow "No CDN available, no use CDN"
        _yellow "未检测到可用 CDN，不使用 CDN 加速"
    fi
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
    "riscv64")
        system_arch="riscv64"
        ;;
    *)
        system_arch=""
        ;;
    esac
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
            interfaces_list=$(pve_ipv6_json_probe interfaces) || return 1
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

update_sysctl() {
    sysctl_config="$1"  # 格式: key=value
    key="${sysctl_config%%=*}"
    value="${sysctl_config#*=}"
    local legacy_conf="${PVE_SYSCTL_LEGACY_FILE:-/etc/sysctl.conf}"
    # 目标配置文件（systemd 方式）
    if [[ "$key" == net.ipv6.conf.* ]]; then
        # Own these keys separately so uninstall can remove forwarding without
        # editing the host's pre-existing sysctl configuration.
        custom_conf="${PVE_IPV6_SYSCTL_CONFIG_FILE:-/etc/sysctl.d/99-oneclickvirt-pve-ipv6.conf}"
    else
        custom_conf="${PVE_SYSCTL_CONFIG_FILE:-/etc/sysctl.d/99-custom.conf}"
    fi
    mkdir -p "$(dirname "$custom_conf")"
    # 检查 /etc/sysctl.conf 是否存在并且在系统加载路径中
    use_etc_sysctl_conf=false
    if [[ "$key" != net.ipv6.conf.* ]] && [ -f "$legacy_conf" ]; then
        if grep -q "/etc/sysctl.conf" /etc/sysctl.d/README* 2>/dev/null || \
           grep -q "/etc/sysctl.conf" /lib/systemd/system/sysctl.service 2>/dev/null; then
            use_etc_sysctl_conf=true
        fi
    fi
    # 更新 /etc/sysctl.d/99-custom.conf
    if grep -q "^$sysctl_config" "$custom_conf" 2>/dev/null; then
        : # 已经有正确配置，跳过
    elif grep -q "^#$sysctl_config" "$custom_conf" 2>/dev/null; then
        sed -i "s/^#$sysctl_config/$sysctl_config/" "$custom_conf"
    elif grep -q "^$key" "$custom_conf" 2>/dev/null; then
        sed -i "s|^$key.*|$sysctl_config|" "$custom_conf"
    else
        echo "$sysctl_config" >> "$custom_conf"
    fi
    # 如果系统还在用 /etc/sysctl.conf，也同步更新
    if [ "$use_etc_sysctl_conf" = true ]; then
        if grep -q "^$sysctl_config" "$legacy_conf"; then
            : # 已经有正确配置
        elif grep -q "^#$sysctl_config" "$legacy_conf"; then
            sed -i "s/^#$sysctl_config/$sysctl_config/" "$legacy_conf"
        elif grep -q "^$key" "$legacy_conf"; then
            sed -i "s|^$key.*|$sysctl_config|" "$legacy_conf"
        else
            echo "$sysctl_config" >> "$legacy_conf"
        fi
    fi
    # ifupdown may not have created the new bridge yet. Keep its value in the
    # config and let the if-up hook apply it as soon as the interface exists.
    if [[ "$key" =~ ^net\.ipv6\.conf\.([A-Za-z0-9_.:-]+)\.(accept_ra|proxy_ndp)$ ]]; then
        local sysctl_interface="${BASH_REMATCH[1]}" sysctl_setting="${BASH_REMATCH[2]}"
        if [ ! -e "${PVE_IPV6_PROC_CONF_ROOT:-/proc/sys/net/ipv6/conf}/${sysctl_interface}/${sysctl_setting}" ]; then
            pve_network_bridge_exists "$sysctl_interface" || return 1
            return 0
        fi
    fi
    sysctl -w "$key=$value" >/dev/null 2>&1
}

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

is_public_ipv6() {
    local address="${1:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$address" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

global_unicast = ipaddress.IPv6Network("2000::/3")
non_public = (
    ipaddress.IPv6Network("2001::/32"),       # Teredo
    ipaddress.IPv6Network("2001:2::/48"),     # benchmarking
    ipaddress.IPv6Network("2001:10::/28"),    # ORCHID
    ipaddress.IPv6Network("2001:20::/28"),    # ORCHIDv2
    ipaddress.IPv6Network("2001:db8::/32"),   # documentation
    ipaddress.IPv6Network("2002::/16"),       # 6to4
    ipaddress.IPv6Network("3fff::/20"),       # documentation
)
usable = (
    address in global_unicast
    and address.is_global
    and not address.is_private
    and not address.is_multicast
    and not any(address in prefix for prefix in non_public)
)
raise SystemExit(0 if usable else 1)
PY
}

is_private_ipv6() {
    ! is_public_ipv6 "${1:-}"
}

# Keep machine-readable network state isolated from terminal status output.
is_single_network_value() {
    local value="${1-}"
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\033'* ]]
}

validate_prefixlen_value() {
    local value="${1-}"
    local maximum="${2:-128}"
    is_single_network_value "$value" && [[ "$value" =~ ^[0-9]+$ ]] &&
        [ "$value" -ge 0 ] && [ "$value" -le "$maximum" ]
}

validate_ipv6_prefixlen_value() {
    validate_prefixlen_value "${1-}" 128
}

validate_interface_value() {
    local value="${1-}"
    is_single_network_value "$value" && [ "${#value}" -le 15 ] && [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]]
}

validate_ipv4_value() {
    local value="${1-}"
    local address="$value"
    local prefix=""
    local first second third fourth extra octet
    is_single_network_value "$value" || return 1
    if [[ "$value" == */* ]]; then
        address="${value%%/*}"
        prefix="${value#*/}"
        [[ "$prefix" != */* ]] && validate_prefixlen_value "$prefix" 32 || return 1
    fi
    IFS=. read -r first second third fourth extra <<<"$address"
    [ -z "$extra" ] && [ -n "$fourth" ] || return 1
    for octet in "$first" "$second" "$third" "$fourth"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$octet))" -le 255 ] || return 1
    done
}

validate_ipv4_network24_value() {
    local value="${1-}"
    validate_ipv4_value "$value" && [[ "$value" =~ ^([0-9]{1,3}\.){3}0/24$ ]]
}

validate_ipv6_value() {
    local value="${1-}"
    local address="$value"
    local prefix=""
    local remainder part
    local count=0
    local compressed=false
    local -a ipv6_parts
    is_single_network_value "$value" || return 1
    if [[ "$value" == */* ]]; then
        address="${value%%/*}"
        prefix="${value#*/}"
        [[ "$prefix" != */* ]] && validate_prefixlen_value "$prefix" 128 || return 1
    fi
    [[ "$address" == *:* && "$address" =~ ^[0-9A-Fa-f:]+$ && "$address" != *:::* ]] || return 1
    if [[ "$address" == *::* ]]; then
        compressed=true
        remainder="${address#*::}"
        [[ "$remainder" != *::* ]] || return 1
    else
        [[ "$address" != :* && "$address" != *: ]] || return 1
    fi
    IFS=: read -ra ipv6_parts <<<"$address"
    for part in "${ipv6_parts[@]}"; do
        [ -z "$part" ] && continue
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        count=$((count + 1))
    done
    if [ "$compressed" = true ]; then
        [ "$count" -lt 8 ]
    else
        [ "$count" -eq 8 ]
    fi
}

validate_ipv6_network_value() {
    local value="${1-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$value" <<'PY' >/dev/null 2>&1
import ipaddress
import sys
try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if network.prefixlen == 64 and network.subnet_of(ipaddress.IPv6Network("fc00::/7")) else 1)
PY
}

validate_pve_direct_ipv6_bridge_value() {
    local value="${1-}"
    is_single_network_value "$value" && [ "${#value}" -le 15 ] && [[ "$value" =~ ^[A-Za-z0-9_.:-]+$ ]]
}

validate_pve_direct_ipv6_mode_value() {
    case "${1-}" in
    ndp | routed) return 0 ;;
    *) return 1 ;;
    esac
}

validate_pve_direct_ipv6_transport_value() {
    case "${1-}" in
    bridge | tunnel) return 0 ;;
    *) return 1 ;;
    esac
}

# Normalize explicitly delegated IPv6 configuration.  A host's SLAAC address
# is deliberately not an input here: it proves reachability, not that a whole
# prefix can be handed to guests.
pve_direct_ipv6_normalize() {
    local prefix="${1:-}" upstream_gateway="${2:-}" mode="${3:-ndp}" bridge_gateway="${4:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$prefix" "$upstream_gateway" "$mode" "$bridge_gateway" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
    upstream_gateway = ipaddress.IPv6Address(sys.argv[2].split('/', 1)[0].strip())
    preferred_bridge_gateway = (
        ipaddress.IPv6Address(sys.argv[4].split('/', 1)[0].strip())
        if sys.argv[4].strip()
        else None
    )
except ValueError:
    raise SystemExit(1)

mode = sys.argv[3].lower()
global_unicast = ipaddress.IPv6Network("2000::/3")
if network.prefixlen > 120 or not network.subnet_of(global_unicast) or mode not in {"ndp", "routed"}:
    raise SystemExit(1)

if mode == "ndp":
    if not upstream_gateway.is_global or upstream_gateway not in network:
        raise SystemExit(1)
    bridge_gateway = upstream_gateway
else:
    if not (upstream_gateway.is_global or upstream_gateway.is_link_local):
        raise SystemExit(1)
    if preferred_bridge_gateway is not None:
        if (
            not preferred_bridge_gateway.is_global
            or preferred_bridge_gateway not in network
            or preferred_bridge_gateway == network.network_address
        ):
            raise SystemExit(1)
        bridge_gateway = preferred_bridge_gateway
    elif upstream_gateway.is_global and upstream_gateway in network and upstream_gateway != network.network_address:
        bridge_gateway = upstream_gateway
    else:
        bridge_gateway = ipaddress.IPv6Address(int(network.network_address) + 1)

print(network.with_prefixlen)
print(bridge_gateway.compressed)
print(mode)
print(upstream_gateway.compressed)
PY
}

pve_direct_ipv6_env_config() {
    local prefix="${PVE_IPV6_ROUTED_PREFIX:-}" upstream_gateway="${PVE_IPV6_DIRECT_GATEWAY:-}"
    local mode="${PVE_IPV6_DIRECT_MODE:-ndp}" bridge_gateway="${PVE_IPV6_BRIDGE_GATEWAY:-}"
    local bridge="${PVE_IPV6_DIRECT_BRIDGE:-vmbr2}" transport="${PVE_IPV6_DIRECT_TRANSPORT:-bridge}"

    [ -n "$prefix" ] && [ -n "$upstream_gateway" ] || return 1
    validate_pve_direct_ipv6_bridge_value "$bridge" || return 1
    validate_pve_direct_ipv6_transport_value "$transport" || return 1
    pve_direct_ipv6_normalize "$prefix" "$upstream_gateway" "$mode" "$bridge_gateway" || return 1
    printf '%s\n' "$bridge" "$transport"
}

pve_direct_ipv6_requested() {
    [ -n "${PVE_IPV6_ROUTED_PREFIX:-}" ] || [ -n "${PVE_IPV6_DIRECT_GATEWAY:-}" ] || [ -n "${PVE_IPV6_DIRECT_MODE:-}" ] ||
        [ -n "${PVE_IPV6_BRIDGE_GATEWAY:-}" ] || [ -n "${PVE_IPV6_DIRECT_BRIDGE:-}" ] || [ -n "${PVE_IPV6_DIRECT_TRANSPORT:-}" ]
}

pve_direct_ipv6_state_file() {
    printf '%s/%s\n' "${PVE_STATE_DIR:-/usr/local/bin}" "$1"
}

pve_save_direct_ipv6_config() {
    local prefix="$1" bridge_gateway="$2" mode="$3" upstream_gateway="$4" bridge="$5" transport="$6" normalized_output
    local -a normalized_values
    validate_pve_direct_ipv6_bridge_value "$bridge" || return 1
    validate_pve_direct_ipv6_transport_value "$transport" || return 1
    normalized_output="$(pve_direct_ipv6_normalize "$prefix" "$upstream_gateway" "$mode" "$bridge_gateway")" || return 1
    mapfile -t normalized_values <<<"$normalized_output"
    [ "${#normalized_values[@]}" -eq 4 ] || return 1
    write_network_state_atomic "$(pve_direct_ipv6_state_file pve_direct_ipv6_prefix)" "${normalized_values[0]}" is_single_network_value || return 1
    write_network_state_atomic "$(pve_direct_ipv6_state_file pve_direct_ipv6_gateway)" "${normalized_values[1]}" is_single_network_value || return 1
    write_network_state_atomic "$(pve_direct_ipv6_state_file pve_direct_ipv6_mode)" "${normalized_values[2]}" validate_pve_direct_ipv6_mode_value || return 1
    write_network_state_atomic "$(pve_direct_ipv6_state_file pve_direct_ipv6_upstream_gateway)" "${normalized_values[3]}" is_single_network_value || return 1
    write_network_state_atomic "$(pve_direct_ipv6_state_file pve_direct_ipv6_bridge)" "$bridge" validate_pve_direct_ipv6_bridge_value || return 1
    write_network_state_atomic "$(pve_direct_ipv6_state_file pve_direct_ipv6_transport)" "$transport" validate_pve_direct_ipv6_transport_value
}

pve_network_bridge_exists() {
    local bridge="$1" interfaces_file="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}"
    validate_pve_direct_ipv6_bridge_value "$bridge" || return 1
    ip link show "$bridge" >/dev/null 2>&1 && return 0
    [ -r "$interfaces_file" ] || return 1
    awk -v bridge="$bridge" '
        $1 == "auto" {
            for (i = 2; i <= NF; i++) if ($i == bridge) found = 1
        }
        $1 == "iface" && $2 == bridge { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$interfaces_file"
}

# A PVE installation may still have its IPv6 default route on a physical NIC
# while it is writing that NIC into vmbr0. Persisting RA/NDP on the physical
# port in that transition would break after the next reload or reboot.
pve_vmbr0_owns_interface() {
    local candidate="$1" interfaces_file
    validate_interface_value "$candidate" || return 1
    interfaces_file="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}"
    [ -r "$interfaces_file" ] || return 1
    awk -v candidate="$candidate" '
        $1 == "iface" {
            in_vmbr0 = ($2 == "vmbr0")
            next
        }
        in_vmbr0 && $1 == "bridge_ports" {
            for (i = 2; i <= NF; i++) {
                if ($i == candidate) {
                    found = 1
                    exit
                }
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$interfaces_file"
}

# The IPv6 uplink is not necessarily vmbr0. Bare-metal hosts, cloud guests,
# and custom PVE bridge layouts may receive router advertisements on another
# interface. Prefer the IPv6 default route, but map an in-progress PVE bridge
# migration to vmbr0 so the persisted setting survives the next reboot.
pve_ipv6_uplink_interface() {
    local candidate
    candidate=$(pve_ipv6_json_probe default_interface 2>/dev/null || true)
    if validate_interface_value "$candidate" && ip link show dev "$candidate" >/dev/null 2>&1; then
        if [ "$candidate" != vmbr0 ] && pve_vmbr0_owns_interface "$candidate"; then
            printf '%s\n' vmbr0
            return 0
        fi
        printf '%s\n' "$candidate"
        return 0
    fi
    for candidate in vmbr0 eth0; do
        if validate_interface_value "$candidate" && ip link show dev "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Keep the explicit override and HE tunnel behavior, but otherwise put NDP on
# the interface that actually receives the IPv6 default route.
pve_direct_ndp_interface() {
    local transport="${1:-bridge}" requested="${PVE_IPV6_DIRECT_NDP_INTERFACE:-}"
    if [ -n "$requested" ]; then
        validate_pve_direct_ipv6_bridge_value "$requested" || return 1
        printf '%s\n' "$requested"
        return 0
    fi
    if [ "$transport" = tunnel ]; then
        printf '%s\n' he-ipv6
        return 0
    fi
    pve_ipv6_uplink_interface || printf '%s\n' vmbr0
}

disable_ndpresponder() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now ndpresponder.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/ndpresponder.service
}

write_network_state_atomic() {
    local path="$1"
    local value="$2"
    local validator="$3"
    local tmp_file
    "$validator" "$value" || return 1
    mkdir -p -- "$(dirname "$path")" || return 1
    tmp_file=$(mktemp "${path}.tmp.XXXXXX") || return 1
    if [ -e "$path" ]; then
        chmod --reference="$path" "$tmp_file" 2>/dev/null || chmod 0644 "$tmp_file"
    else
        chmod 0644 "$tmp_file"
    fi
    if ! printf '%s\n' "$value" >"$tmp_file" || ! mv -f -- "$tmp_file" "$path"; then
        rm -f -- "$tmp_file"
        return 1
    fi
}

read_network_state() {
    local path="$1"
    local validator="$2"
    local value
    [ -s "$path" ] || return 1
    value=$(cat -- "$path")
    "$validator" "$value" || return 1
    printf '%s\n' "$value"
}

pve_ipv6_json_probe() {
    local mode="$1" selected_interface="${2:-}" replacement_interface="${3:-}" payload
    case "$mode" in
        addresses|address_bindings|linklocal)
            if [ "${PVE_IPV6_ADDRESS_JSON_OVERRIDE+x}" = x ]; then
                payload="$PVE_IPV6_ADDRESS_JSON_OVERRIDE"
            else
                payload=$(LC_ALL=C NO_COLOR=1 ip -j -6 addr show) || return 1
            fi
            ;;
        gateway|default_interface|default_routes_restore)
            if [ "${PVE_IPV6_ROUTE_JSON_OVERRIDE+x}" = x ]; then
                payload="$PVE_IPV6_ROUTE_JSON_OVERRIDE"
            else
                payload=$(LC_ALL=C NO_COLOR=1 ip -j -6 route show default) || return 1
            fi
            ;;
        interfaces) payload=$(LC_ALL=C NO_COLOR=1 ip -d -j link show) || return 1 ;;
        *) return 1 ;;
    esac
    PVE_IPV6_PROBE_JSON="$payload" python3 - "$mode" "$selected_interface" "$replacement_interface" <<'PY'
import ipaddress
import json
import os
import re
import sys

mode, selected, replacement = sys.argv[1:]
raw = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', os.environ['PVE_IPV6_PROBE_JSON'])
interface_pattern = re.compile(r'[A-Za-z0-9_.:-]{1,15}')

def route_hops(row):
    hops = row.get('nexthops') or row.get('multipath')
    if hops is None:
        return [row]
    if not isinstance(hops, list) or not hops:
        raise ValueError('invalid default route nexthops')
    return hops

try:
    rows = json.loads(raw)
    if not isinstance(rows, list):
        raise ValueError('invalid iproute2 JSON')
    if mode in ('gateway', 'default_interface', 'default_routes_restore'):
        candidates = [row for row in rows if row.get('dst') in (None, '', 'default')]
        candidates.sort(key=lambda row: row.get('dev') != selected if selected else False)
        for row in candidates:
            if mode == 'default_interface':
                devices = [row.get('dev', '')]
                devices.extend(hop.get('dev', '') for hop in route_hops(row))
                device = next((value for value in devices if interface_pattern.fullmatch(value or '')), '')
                if device:
                    print(device)
                    break
            elif mode == 'gateway':
                for hop in route_hops(row):
                    device = hop.get('dev') or row.get('dev', '')
                    gateway = hop.get('gateway') or row.get('gateway', '')
                    if selected and device and device != selected:
                        continue
                    if gateway:
                        print(ipaddress.IPv6Address(gateway))
                        raise SystemExit(0)
            else:
                if row.get('type') not in (None, '', 'unicast'):
                    continue
                metric = row.get('metric')
                if metric is not None and (not isinstance(metric, int) or metric < 0):
                    raise ValueError('invalid default route metric')
                hops = route_hops(row)
                tokens = ['-6', 'route', 'replace', 'default']
                if len(hops) > 1 and metric is not None:
                    tokens.extend(['metric', str(metric)])
                for hop in hops:
                    device = hop.get('dev') or row.get('dev') or selected
                    if not interface_pattern.fullmatch(device or ''):
                        raise ValueError('invalid default route interface')
                    if device == selected and replacement:
                        device = replacement
                    if len(hops) > 1:
                        tokens.append('nexthop')
                    gateway = hop.get('gateway') or row.get('gateway', '')
                    gateway_address = ipaddress.IPv6Address(gateway) if gateway else None
                    if gateway:
                        tokens.extend(['via', gateway_address.compressed])
                    tokens.extend(['dev', device])
                    flags = hop.get('flags') or row.get('flags') or []
                    if isinstance(flags, str):
                        flags = [flags]
                    if len(hops) > 1:
                        weight = hop.get('weight', 1)
                        if not isinstance(weight, int) or not 1 <= weight <= 256:
                            raise ValueError('invalid default route nexthop weight')
                        tokens.extend(['weight', str(weight)])
                    if 'onlink' in flags or (gateway_address and gateway_address.is_link_local):
                        tokens.append('onlink')
                if len(hops) == 1 and metric is not None:
                    tokens.extend(['metric', str(metric)])
                print(' '.join(tokens))
    elif mode == 'interfaces':
        for row in rows:
            device = row.get('ifname', '')
            kind = (row.get('linkinfo') or {}).get('info_kind', '')
            if kind in {'bridge', 'veth', 'dummy', 'macvlan', 'ipvlan', 'sit', 'tun', 'tap'}:
                continue
            if device != 'lo' and interface_pattern.fullmatch(device):
                print(device)
    else:
        for row in rows:
            device = row.get('ifname', '')
            if selected and device != selected:
                continue
            for info in row.get('addr_info', []):
                if info.get('family') != 'inet6' or info.get('tentative') or info.get('dadfailed'):
                    continue
                if {'tentative', 'dadfailed'} & set(info.get('flags') or []):
                    continue
                address = ipaddress.IPv6Address(info['local'])
                prefix = info['prefixlen']
                if not isinstance(prefix, int) or not 0 <= prefix <= 128:
                    raise ValueError('invalid IPv6 prefix')
                if mode == 'addresses' and info.get('scope') == 'global' and address.is_global:
                    print(f'{address}/{prefix}')
                if mode == 'address_bindings' and info.get('scope') == 'global' and address.is_global:
                    if not interface_pattern.fullmatch(device):
                        raise ValueError('invalid interface for global IPv6 address')
                    print(f'{device}\t{address}/{prefix}')
                if mode == 'linklocal' and address.is_link_local:
                    print(f'{address}/{prefix}')
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

pve_ipv6_configured_alias_addresses() {
    local config_file="${1:-}"
    [ -r "$config_file" ] || return 1
    python3 - "$config_file" <<'PY'
import ipaddress
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(errors='replace').splitlines()
for index, line in enumerate(lines):
    fields = line.split()
    if len(fields) < 2 or fields[:2] != ['#', 'control-alias']:
        continue
    if index + 2 >= len(lines):
        continue
    interface = lines[index + 1].split()
    address = lines[index + 2].split()
    if len(interface) < 4 or interface[0] != 'iface' or interface[2:4] != ['inet6', 'static']:
        continue
    if len(address) != 2 or address[0] != 'address':
        continue
    try:
        candidate = ipaddress.IPv6Interface(address[1]).ip
    except ValueError:
        continue
    if candidate.is_global:
        print(candidate.compressed)
PY
}

# Snapshot the routed host interface before bridge migration or HE handling
# mutates the script's IPv6 allocation variables.
pve_capture_host_ipv6_runtime() {
    local default_interface addresses address_bindings gateway route_json address_json route_commands
    route_json=$(LC_ALL=C NO_COLOR=1 ip -j -6 route show default) || return 1
    address_json=$(LC_ALL=C NO_COLOR=1 ip -j -6 addr show) || return 1
    default_interface=$(PVE_IPV6_ROUTE_JSON_OVERRIDE="$route_json" pve_ipv6_json_probe default_interface) || return 1
    host_ipv6_runtime_interface="$default_interface"
    host_ipv6_runtime_has_default_route=false
    host_ipv6_runtime_cidrs=""
    host_ipv6_runtime_address_bindings=""
    host_ipv6_runtime_gateway=""
    host_ipv6_runtime_route_json=""
    addresses=$(PVE_IPV6_ADDRESS_JSON_OVERRIDE="$address_json" pve_ipv6_json_probe addresses) || return 1
    address_bindings=$(PVE_IPV6_ADDRESS_JSON_OVERRIDE="$address_json" pve_ipv6_json_probe address_bindings) || return 1
    host_ipv6_runtime_route_json="$route_json"
    route_commands=$(PVE_IPV6_ROUTE_JSON_OVERRIDE="$route_json" pve_ipv6_json_probe default_routes_restore "$default_interface" "$default_interface") || return 1
    if [ -n "$route_commands" ]; then
        host_ipv6_runtime_has_default_route=true
        gateway=$(PVE_IPV6_ROUTE_JSON_OVERRIDE="$route_json" pve_ipv6_json_probe gateway "$default_interface") || return 1
        host_ipv6_runtime_gateway="$gateway"
    fi
    host_ipv6_runtime_cidrs="$addresses"
    host_ipv6_runtime_address_bindings="$address_bindings"
}

check_ipv6() {
    local preferred_interface rows
    preferred_interface=$(pve_ipv6_json_probe default_interface) || return 1
    rows=$(pve_ipv6_json_probe addresses "$preferred_interface") || return 1
    if [ -z "$rows" ]; then
        rows=$(pve_ipv6_json_probe addresses) || return 1
    fi
    IPV6="${rows%%/*}"
    IPV6="${IPV6%%$'\n'*}"
    if [ -n "$IPV6" ]; then
        validate_ipv6_value "$IPV6" || return 1
        write_network_state_atomic /usr/local/bin/pve_check_ipv6 "$IPV6" validate_ipv6_value || return 1
    else
        rm -f /usr/local/bin/pve_check_ipv6
    fi
}

########## 查询信息

# 安装必要工具
install_required_tools() {
    local tools=("lshw" "ipcalc" "sipcalc" "ovs-vsctl:openvswitch-switch" "crontab:cron" "python3")
    for tool in "${tools[@]}"; do
        local cmd="${tool%%:*}"
        local pkg="${tool#*:}"
        if [[ "$pkg" == "$cmd" ]]; then pkg="$cmd"; fi

        if ! command -v "$cmd" >/dev/null 2>&1; then
            apt-get install -y "$pkg"
        fi
    done
    apt-get install -y net-tools
}

# 请求IPV6网络以加载配置
request_ipv6() {
    curl -m 5 ipv6.ip.sb || curl -m 5 ipv6.ip.sb
}

# 检测物理接口和MAC地址
detect_network_interfaces() {
    local detected_interfaces preferred_interface candidate
    detected_interfaces=$(pve_ipv6_json_probe interfaces) || return 1
    preferred_interface=$(pve_ipv6_json_probe default_interface 2>/dev/null || true)
    if [ -n "$preferred_interface" ] && ! grep -Fxq "$preferred_interface" <<<"$detected_interfaces"; then
        preferred_interface=""
    fi
    interface_1="${preferred_interface:-$(printf '%s\n' "$detected_interfaces" | head -n 1)}"
    interface_2=""
    while IFS= read -r candidate; do
        if [ -n "$candidate" ] && [ "$candidate" != "$interface_1" ]; then
            interface_2="$candidate"
            break
        fi
    done <<<"$detected_interfaces"
    check_interface

    if ! validate_interface_value "$interface" || [ ! -d "/sys/class/net/$interface" ]; then
        _red "Detected network interface output is invalid: ${interface@Q}"
        _red "检测到的网口输出无效：${interface@Q}"
        return 1
    fi
    write_network_state_atomic /usr/local/bin/pve_main_interface "$interface" validate_interface_value || return 1

    if [ ! -f /usr/local/bin/pve_mac_address ] || [ ! -s /usr/local/bin/pve_mac_address ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_mac_address)" = "" ]; then
        mac_address=$(cat "/sys/class/net/${interface}/address" 2>/dev/null || true)
        echo "$mac_address" >/usr/local/bin/pve_mac_address
    fi
    mac_address=$(cat /usr/local/bin/pve_mac_address)

    setup_persistent_net_link
}

# 设置持久化网络接口名称
setup_persistent_net_link() {
    if [ ! -f /etc/systemd/network/10-persistent-net.link ]; then
        echo '[Match]' >/etc/systemd/network/10-persistent-net.link
        echo "MACAddress=${mac_address}" >>/etc/systemd/network/10-persistent-net.link
        echo "" >>/etc/systemd/network/10-persistent-net.link
        echo '[Link]' >>/etc/systemd/network/10-persistent-net.link
        echo "Name=${interface}" >>/etc/systemd/network/10-persistent-net.link
        /etc/init.d/udev force-reload
    fi
}

# 检测HE隧道配置
pve_he_bridge_cidr() {
    local tunnel_cidr="$1" tunnel_gateway="$2" host_cidrs="$3" route_json="$4"
    python3 - "$tunnel_cidr" "$tunnel_gateway" "$host_cidrs" "$route_json" <<'PY'
import ipaddress
import json
import re
import sys

try:
    tunnel = ipaddress.IPv6Interface(sys.argv[1])
    gateway = ipaddress.IPv6Address(sys.argv[2])
    host_addresses = {
        ipaddress.IPv6Interface(row).ip
        for row in sys.argv[3].splitlines() if row.strip()
    }
    raw_routes = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', sys.argv[4])
    routes = json.loads(raw_routes)
    if not isinstance(routes, list) or not tunnel.ip.is_global:
        raise ValueError('invalid tunnel state')
    parent = tunnel.network
    # The guest allocator needs at least a /120; a /120 or narrower tunnel
    # has no disjoint child large enough for that allocator.
    target = ((parent.prefixlen + 7) // 8) * 8
    if target <= parent.prefixlen:
        target += 8
    if target > 120:
        raise ValueError('tunnel prefix too narrow')
    occupied = host_addresses | {gateway}
    other_routes = []
    for row in routes:
        destination = row.get('dst', 'default')
        if not destination or destination == 'default':
            continue
        try:
            route = ipaddress.IPv6Network(destination, strict=False)
        except ValueError:
            # `ip -j route show table all` may include route-kind labels
            # such as local/multicast alongside real IPv6 destinations.
            if isinstance(destination, str) and destination.split(None, 1)[0] in {
                'local', 'broadcast', 'multicast', 'unreachable', 'prohibit',
                'blackhole', 'throw', 'nat', 'cache',
            }:
                continue
            raise
        if route == parent and row.get('dev') == 'he-ipv6':
            continue
        other_routes.append(route)
    for child in parent.subnets(new_prefix=target):
        if any(address in child for address in occupied):
            continue
        if any(child.overlaps(route) for route in other_routes):
            continue
        print(f'{ipaddress.IPv6Address(int(child.network_address) + 1)}/{target}')
        break
    else:
        raise ValueError('no unused tunnel child')
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

detect_he_tunnel() {
    status_he=false
    pve_capture_host_ipv6_runtime || return 1
    if grep -q "he-ipv6" /etc/network/interfaces; then
        local covert_tmp
        covert_tmp=$(mktemp /root/covert.sh.tmp.XXXXXX) || return 1
        if ! wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/6in4/main/covert.sh" -O "$covert_tmp" || [ ! -s "$covert_tmp" ] || ! chmod 755 "$covert_tmp" || ! mv -f -- "$covert_tmp" /root/covert.sh; then
            rm -f -- "$covert_tmp"
            _red "Failed to download HE tunnel helper"
            _red "下载 HE 隧道辅助脚本失败"
            return 1
        fi
        /root/covert.sh
        sleep 1
        temp_config=$(awk '/auto he-ipv6/{flag=1; print $0; next} flag && flag++<10' /etc/network/interfaces)
        local tunnel_cidr host_cidrs route_json
        tunnel_cidr=$(pve_ipv6_json_probe addresses he-ipv6 | head -n 1) || return 1
        [ -n "$tunnel_cidr" ] || return 1
        ipv6_address="${tunnel_cidr%/*}"
        ipv6_prefixlen="${tunnel_cidr##*/}"
        ipv6_gateway=$(printf '%s\n' "$temp_config" | awk '$1 == "gateway" {print $2; exit}')
        validate_ipv6_value "$ipv6_address" || return 1
        validate_ipv6_value "$ipv6_gateway" && [[ "$ipv6_gateway" != */* ]] || return 1
        validate_ipv6_prefixlen_value "$ipv6_prefixlen" || return 1
        host_cidrs=$(pve_ipv6_json_probe addresses) || return 1
        route_json=$(LC_ALL=C NO_COLOR=1 ip -j -6 route show table all) || return 1
        # Keep the tunnel stanza and use NAT66 when no safe child exists.
        if ! new_subnet=$(pve_he_bridge_cidr "$tunnel_cidr" "$ipv6_gateway" "$host_cidrs" "$route_json"); then
            status_he=false
            _yellow "No disjoint HE tunnel prefix is available for a direct IPv6 bridge; using NAT66"
            detect_existing_ipv6_config || return 1
            check_fe80_gateway
            return
        fi
        target_mask="${new_subnet##*/}"
        write_network_state_atomic /usr/local/bin/pve_ipv6_prefixlen "$target_mask" validate_ipv6_prefixlen_value || return 1
        write_network_state_atomic /usr/local/bin/pve_check_ipv6 "$ipv6_address" validate_ipv6_value || return 1
        write_network_state_atomic /usr/local/bin/pve_ipv6_gateway "$ipv6_gateway" validate_ipv6_value || return 1
        chattr -i /etc/network/interfaces
        sed -i '/^auto he-ipv6/,/^$/d' /etc/network/interfaces
        chattr +i /etc/network/interfaces
        status_he=true
    else
        detect_existing_ipv6_config
    fi

    check_fe80_gateway
}

# 检测已有的IPV6配置
detect_existing_ipv6_config() {
    local preferred_interface live_cidrs persisted_cidr candidate
    pve_capture_host_ipv6_runtime || return 1
    preferred_interface="$host_ipv6_runtime_interface"
    live_cidrs="$host_ipv6_runtime_cidrs"
    if [ -n "$preferred_interface" ] && [ -z "$live_cidrs" ]; then
        live_cidrs=$(pve_ipv6_json_probe addresses "$preferred_interface") || return 1
    fi
    if [ -z "$live_cidrs" ]; then
        live_cidrs=$(pve_ipv6_json_probe addresses) || return 1
    fi
    ipv6_address=$(read_network_state /usr/local/bin/pve_check_ipv6 validate_ipv6_value 2>/dev/null || true)
    persisted_cidr=""
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if [ "${candidate%/*}" = "$ipv6_address" ]; then
            persisted_cidr="$candidate"
            break
        fi
    done <<<"$live_cidrs"
    if [ -z "$persisted_cidr" ]; then
        persisted_cidr="${live_cidrs%%$'\n'*}"
    fi
    if [ -n "$persisted_cidr" ]; then
        ipv6_address="${persisted_cidr%/*}"
        ipv6_prefixlen="${persisted_cidr##*/}"
        validate_ipv6_value "$ipv6_address" || return 1
        validate_ipv6_prefixlen_value "$ipv6_prefixlen" || return 1
        write_network_state_atomic /usr/local/bin/pve_check_ipv6 "$ipv6_address" validate_ipv6_value || return 1
        write_network_state_atomic /usr/local/bin/pve_ipv6_prefixlen "$ipv6_prefixlen" validate_ipv6_prefixlen_value || return 1
        rm -f /usr/local/bin/pve_ipv6_real_prefixlen
    else
        ipv6_address=""
        ipv6_prefixlen=""
    fi
    ipv6_gateway="$host_ipv6_runtime_gateway"
    if [ -n "$ipv6_gateway" ]; then
        validate_ipv6_value "$ipv6_gateway" || return 1
        write_network_state_atomic /usr/local/bin/pve_ipv6_gateway "$ipv6_gateway" validate_ipv6_value || return 1
    fi
}

# 重新配置IPV6地址
reconfigure_ipv6_address() {
    # Retain the address that is actually bound to the host. A guessed ::1
    # inside the same prefix could belong to another host.
    validate_ipv6_value "$ipv6_address"
}

# 检查fe80类型网关
check_fe80_gateway() {
    if [[ $ipv6_gateway == fe80* ]]; then
        ipv6_gateway_fe80="Y"
    else
        ipv6_gateway_fe80="N"
    fi
    fe80_address=$(read_network_state /usr/local/bin/pve_fe80_address validate_ipv6_value 2>/dev/null || true)
}

# 配置文件重试下载，优先使用CDN，CDN全部失败后降级使用原始链接
download_with_retry() {
    local original_url="$1"
    local output="$2"
    local max_attempts=5
    local attempt=1
    local delay=1
    # 优先尝试CDN
    if [ -n "$cdn_success_url" ]; then
        local cdn_url="${cdn_success_url}${original_url}"
        while [ $attempt -le $max_attempts ]; do
            wget -q "$cdn_url" -O "$output" && return 0
            echo "Download failed: $cdn_url, try $attempt, wait $delay seconds and retry..."
            echo "下载失败：$cdn_url，尝试第 $attempt 次，等待 $delay 秒后重试..."
            sleep $delay
            attempt=$((attempt + 1))
            delay=$((delay * 2))
            [ $delay -gt 30 ] && delay=30
        done
        _yellow "CDN download failed, trying original URL..."
        _yellow "CDN下载均失败，改用原始链接重试..."
        attempt=1
        delay=1
    fi
    # 降级到原始链接
    while [ $attempt -le $max_attempts ]; do
        wget -q "$original_url" -O "$output" && return 0
        echo "Download failed: $original_url, try $attempt, wait $delay seconds and retry..."
        echo "下载失败：$original_url，尝试第 $attempt 次，等待 $delay 秒后重试..."
        sleep $delay
        attempt=$((attempt + 1))
        delay=$((delay * 2))
        [ $delay -gt 30 ] && delay=30
    done
    _red "Download failed: $original_url, maximum number of attempts exceeded ($max_attempts)"
    _red "下载失败：$original_url，超过最大尝试次数 ($max_attempts)"
    return 1
}

# 配置ndpresponder守护进程
install_ndpresponder() {
    appended_file="/usr/local/bin/pve_appended_content.txt"
    if [ -n "$ipv6_address" ] && [ -n "$ipv6_prefixlen" ] && [ -n "$ipv6_gateway" ] && [ ! -s "$appended_file" ]; then
        if [ -f /usr/local/bin/pve_maximum_subset ] && [ "$(cat /usr/local/bin/pve_maximum_subset)" = false ]; then
            _blue "No install ndpresponder"
        elif [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
            # 若服务已在运行，先停止以避免 "Text file busy" 错误
            if systemctl is-active --quiet ndpresponder.service 2>/dev/null; then
                systemctl stop ndpresponder.service 2>/dev/null || true
            fi
            if ! download_with_retry "https://github.com/oneclickvirt/pve/releases/download/ndpresponder_x86/ndpresponder" "/usr/local/bin/ndpresponder"; then
                _yellow "ndpresponder download failed, continuing without IPv6 direct-assignment support"
                _yellow "ndpresponder 下载失败，将以无独立IPv6地址的模式继续部署"
                rm -f /usr/local/bin/ndpresponder
                return 0
            fi
            if ! download_with_retry "https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/ndpresponder.service" "/etc/systemd/system/ndpresponder.service"; then
                _yellow "ndpresponder service file download failed, continuing without IPv6 direct-assignment support"
                _yellow "ndpresponder service文件下载失败，将以无独立IPv6地址的模式继续部署"
                rm -f /usr/local/bin/ndpresponder
                return 0
            fi
            chmod 755 /usr/local/bin/ndpresponder
            chmod 644 /etc/systemd/system/ndpresponder.service
        elif [ "$system_arch" = "arm" ]; then
            # 若服务已在运行，先停止以避免 "Text file busy" 错误
            if systemctl is-active --quiet ndpresponder.service 2>/dev/null; then
                systemctl stop ndpresponder.service 2>/dev/null || true
            fi
            if ! download_with_retry "https://github.com/oneclickvirt/pve/releases/download/ndpresponder_aarch64/ndpresponder" "/usr/local/bin/ndpresponder"; then
                _yellow "ndpresponder download failed, continuing without IPv6 direct-assignment support"
                _yellow "ndpresponder 下载失败，将以无独立IPv6地址的模式继续部署"
                rm -f /usr/local/bin/ndpresponder
                return 0
            fi
            if ! download_with_retry "https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/ndpresponder.service" "/etc/systemd/system/ndpresponder.service"; then
                _yellow "ndpresponder service file download failed, continuing without IPv6 direct-assignment support"
                _yellow "ndpresponder service文件下载失败，将以无独立IPv6地址的模式继续部署"
                rm -f /usr/local/bin/ndpresponder
                return 0
            fi
            chmod 755 /usr/local/bin/ndpresponder
            chmod 644 /etc/systemd/system/ndpresponder.service
        elif [ "$system_arch" = "riscv64" ]; then
            _yellow "ndpresponder binary is not packaged for riscv64 in this project yet, continuing without IPv6 direct-assignment support"
            _yellow "本项目暂未提供 riscv64 的 ndpresponder 二进制，将在无独立 IPv6 地址模式下继续部署"
            return 0
        fi
    fi
}

# 检测IPV4相关信息
detect_ipv4_info() {
    if ! ipv4_address=$(read_network_state /usr/local/bin/pve_ipv4_address validate_ipv4_value 2>/dev/null); then
        ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p')
        validate_ipv4_value "$ipv4_address" || return 1
        write_network_state_atomic /usr/local/bin/pve_ipv4_address "$ipv4_address" validate_ipv4_value || return 1
    fi

    if ! ipv4_gateway=$(read_network_state /usr/local/bin/pve_ipv4_gateway validate_ipv4_value 2>/dev/null) || [[ "$ipv4_gateway" == */* ]]; then
        ipv4_gateway=$(ip route | awk '/default/ {print $3}' | sed -n '1p')
        validate_ipv4_value "$ipv4_gateway" && [[ "$ipv4_gateway" != */* ]] || return 1
        write_network_state_atomic /usr/local/bin/pve_ipv4_gateway "$ipv4_gateway" validate_ipv4_value || return 1
    fi

    if ! ipv4_subnet=$(read_network_state /usr/local/bin/pve_ipv4_subnet validate_ipv4_value 2>/dev/null) || [[ "$ipv4_subnet" == */* ]]; then
        ipv4_subnet=$(ipcalc -n "$ipv4_address" | grep -oP 'Netmask:\s+\K.*' | awk '{print $1}')
        validate_ipv4_value "$ipv4_subnet" && [[ "$ipv4_subnet" != */* ]] || return 1
        write_network_state_atomic /usr/local/bin/pve_ipv4_subnet "$ipv4_subnet" validate_ipv4_value || return 1
    fi
}

# 备份和修复网络配置文件
prepare_network_interfaces() {
    if [ ! -f /etc/network/interfaces.bak ]; then
        cp /etc/network/interfaces /etc/network/interfaces.bak
    fi
    # 修正部分网络设置重复的错误
    if [[ -f "/etc/network/interfaces.d/50-cloud-init" && -f "/etc/network/interfaces" ]]; then
        if grep -q "auto lo" "/etc/network/interfaces.d/50-cloud-init" && grep -q "iface lo inet loopback" "/etc/network/interfaces.d/50-cloud-init" && grep -q "auto lo" "/etc/network/interfaces" && grep -q "iface lo inet loopback" "/etc/network/interfaces"; then
            chattr -i /etc/network/interfaces.d/50-cloud-init
            sed -i '/auto lo/d' "/etc/network/interfaces.d/50-cloud-init"
            sed -i '/iface lo inet loopback/d' "/etc/network/interfaces.d/50-cloud-init"
            chattr +i /etc/network/interfaces.d/50-cloud-init
        fi
    fi
    if [ -f "/etc/network/interfaces.new" ]; then
        chattr -i /etc/network/interfaces.new
        rm -rf /etc/network/interfaces.new
    fi
    chattr -i /etc/network/interfaces
    check_loopback_config
}

# 检查回环接口配置
check_loopback_config() {
    if ! grep -q "auto lo" /etc/network/interfaces; then
        _blue "Can not find 'auto lo' in /etc/network/interfaces"
        exit 1
    fi
    if ! grep -q "iface lo inet loopback" /etc/network/interfaces; then
        _blue "Can not find 'iface lo inet loopback' in /etc/network/interfaces"
        exit 1
    fi
}

# 配置vmbr0网桥
configure_vmbr0() {
    chattr -i /etc/network/interfaces
    if grep -q "vmbr0" "/etc/network/interfaces"; then
        _blue "vmbr0 already exists in /etc/network/interfaces"
        _blue "vmbr0 已存在在 /etc/network/interfaces"
    else
        # 根据不同情况添加vmbr0配置
        if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ] && [ ! -f /usr/local/bin/pve_last_ipv6 ]; then
            # 无IPV6地址情况
            add_vmbr0_ipv4_only
        elif [ -f /usr/local/bin/pve_slaac_status ] && [ $(cat /usr/local/bin/pve_maximum_subset) = false ] && [ ! -f /usr/local/bin/pve_last_ipv6 ]; then
            # 有IPV6地址，只有一个IPV6地址且后续仅使用一个IPV6地址，存在slaac机制
            add_vmbr0_with_slaac
        elif [ -f /usr/local/bin/pve_last_ipv6 ]; then
            # 有IPV6地址，不只一个IPV6地址，一个用作网关，一个用作实际地址
            add_vmbr0_with_dual_ipv6
        else
            # 有IPV6地址，只有一个IPV6地址，但后续使用最大IPV6子网范围
            add_vmbr0_with_single_ipv6
        fi
    fi
    # 如果不是fe80类型网关，添加fe80地址删除命令
    if [[ "${ipv6_gateway_fe80}" == "N" ]]; then
        chattr -i /etc/network/interfaces
        echo "    up ip addr del $fe80_address dev $interface" >>/etc/network/interfaces
        remove_duplicate_lines "/etc/network/interfaces"
        chattr +i /etc/network/interfaces
    fi
    # 如果IPV6地址是写死附加上的，这块附加回vmbr0，方便后续使用ip6tables进行转发
    appended_file="/usr/local/bin/pve_appended_content.txt"
    if [ -s "$appended_file" ]; then
        chattr -i /etc/network/interfaces
        sed -E 's/(# control-alias) [^[:space:]]+/\1 vmbr0/g; s/(iface) [^[:space:]]+/\1 vmbr0/g' "$appended_file" | sudo tee -a /etc/network/interfaces > /dev/null
        # 如果需要配DNAT/SNAT的V6转发，那么fe80加白就没必要了，需要注释掉
        sed -i '/^[[:space:]]*up ip addr del fe80/s/^/#/' /etc/network/interfaces
        grep -Fxq 'post-up echo 1 > /proc/sys/net/ipv6/conf/vmbr0/proxy_ndp' /etc/network/interfaces || echo 'post-up echo 1 > /proc/sys/net/ipv6/conf/vmbr0/proxy_ndp' >> /etc/network/interfaces
    fi
}

# 仅添加IPV4配置的vmbr0
add_vmbr0_ipv4_only() {
    cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr0
iface vmbr0 inet static
    address $ipv4_address
    gateway $ipv4_gateway
    bridge_ports $interface
    bridge_stp off
    bridge_fd 0
EOF
}

# 添加带SLAAC的vmbr0
add_vmbr0_with_slaac() {
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
}

# 添加带双IPV6地址的vmbr0
add_vmbr0_with_dual_ipv6() {
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
}

# 添加带单IPV6地址的vmbr0
add_vmbr0_with_single_ipv6() {
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
}

# Select a /24 which is not already attached to or routed by the host.  Cloud
# providers commonly attach an RFC1918 management NIC, and using the same
# subnet for vmbr1 makes guest traffic leave through that physical NIC.
select_nat_ipv4_subnet() {
    local requested="${PVE_NAT_SUBNET:-}"
    local candidate gateway route
    local candidates=()
    local state_dir="${PVE_STATE_DIR:-/usr/local/bin}"
    local subnet_state="${state_dir}/pve_nat_subnet"
    local gateway_state="${state_dir}/pve_nat_gateway"

    if [ -z "$requested" ]; then
        requested="$(read_network_state "$subnet_state" validate_ipv4_network24_value 2>/dev/null || true)"
    fi
    [ -n "$requested" ] && candidates+=("$requested")
    candidates+=("172.16.1.0/24" "10.250.0.0/24" "192.168.250.0/24" "10.251.0.0/24")

    for candidate in "${candidates[@]}"; do
        if ! validate_ipv4_network24_value "$candidate"; then
            [ "$candidate" = "$requested" ] && {
                _red "PVE_NAT_SUBNET must be an IPv4 /24 network ending in .0: ${candidate}"
                _red "PVE_NAT_SUBNET 必须是以 .0 结尾的 IPv4 /24 网段：${candidate}"
                return 1
            }
            continue
        fi
        if ! ipcalc -c "$candidate" >/dev/null 2>&1; then
            [ "$candidate" = "$requested" ] && {
                _red "PVE_NAT_SUBNET is not a valid IPv4 network: ${candidate}"
                _red "PVE_NAT_SUBNET 不是有效的 IPv4 网段：${candidate}"
                return 1
            }
            continue
        fi
        gateway="${candidate%0/24}1"
        if ip -o -4 addr show dev vmbr1 2>/dev/null | grep -Fq " ${gateway}/24 "; then
            nat_ipv4_subnet="$candidate"
            nat_ipv4_gateway="$gateway"
            nat_ipv4_prefix="${gateway%.*}"
            write_network_state_atomic "$subnet_state" "$nat_ipv4_subnet" validate_ipv4_network24_value || return 1
            write_network_state_atomic "$gateway_state" "$nat_ipv4_gateway" validate_ipv4_value || return 1
            return 0
        fi
        route="$(ip -4 route get "$gateway" 2>/dev/null || true)"
        if [ -n "$route" ] && ! grep -q ' via ' <<<"$route" && ! grep -q ' dev vmbr1 ' <<<" $route "; then
            [ "$candidate" = "$requested" ] && {
                _red "Requested PVE NAT subnet conflicts with an existing host route: ${candidate} (${route})"
                _red "请求的 PVE NAT 网段与宿主机现有路由冲突：${candidate}（${route}）"
                return 1
            }
            continue
        fi
        nat_ipv4_subnet="$candidate"
        nat_ipv4_gateway="$gateway"
        nat_ipv4_prefix="${gateway%.*}"
        write_network_state_atomic "$subnet_state" "$nat_ipv4_subnet" validate_ipv4_network24_value || return 1
        write_network_state_atomic "$gateway_state" "$nat_ipv4_gateway" validate_ipv4_value || return 1
        _green "Selected PVE NAT subnet: ${nat_ipv4_subnet} (gateway ${nat_ipv4_gateway})"
        _green "已选择 PVE NAT 网段：${nat_ipv4_subnet}（网关 ${nat_ipv4_gateway}）"
        return 0
    done

    _red "Unable to find a non-conflicting PVE NAT subnet"
    _red "无法找到与宿主机网络不冲突的 PVE NAT 网段"
    return 1
}

pve_nat_ipv6_candidate_is_safe() {
    local candidate="${1:-}" address_json route_json
    command -v python3 >/dev/null 2>&1 || return 1
    address_json=$(LC_ALL=C NO_COLOR=1 ip -j -6 addr show) || return 1
    route_json=$(LC_ALL=C NO_COLOR=1 ip -j -6 route show table all) || return 1
    PVE_HOST_IPV6_ADDRESSES="$address_json" PVE_HOST_IPV6_ROUTES="$route_json" \
        python3 - "$candidate" <<'PYCODE' >/dev/null 2>&1
import ipaddress
import json
import os
import re
import sys

try:
    candidate = ipaddress.IPv6Network(sys.argv[1], strict=False)
    if candidate.prefixlen != 64 or not candidate.subnet_of(ipaddress.IPv6Network('fc00::/7')):
        raise ValueError('not a ULA /64')
    strip_ansi = lambda raw: re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', raw)
    addresses = json.loads(strip_ansi(os.environ['PVE_HOST_IPV6_ADDRESSES']))
    routes = json.loads(strip_ansi(os.environ['PVE_HOST_IPV6_ROUTES']))
    if not isinstance(addresses, list) or not isinstance(routes, list):
        raise ValueError('invalid iproute2 JSON')
    for interface in addresses:
        device = interface['ifname']
        for info in interface.get('addr_info', []):
            if info.get('family') != 'inet6':
                continue
            existing = ipaddress.IPv6Interface(f"{info['local']}/{info['prefixlen']}").network
            if candidate.overlaps(existing) and not (device == 'vmbr1' and existing.subnet_of(candidate)):
                raise ValueError('host address overlap')
    for row in routes:
        destination = row.get('dst', 'default')
        if not destination or destination == 'default':
            continue
        try:
            existing = ipaddress.IPv6Network(destination, strict=False)
        except ValueError:
            if isinstance(destination, str) and destination.split(None, 1)[0] in {
                'local', 'broadcast', 'multicast', 'unreachable', 'prohibit',
                'blackhole', 'throw', 'nat', 'cache',
            }:
                continue
            raise
        if existing.prefixlen == 0:
            continue
        if candidate.overlaps(existing) and not (row.get('dev') == 'vmbr1' and existing.subnet_of(candidate)):
            raise ValueError('host route overlap')
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PYCODE
}

# Select an RFC4193 /64 for the NAT bridge. A child of the uplink's SLAAC /64
# is still covered by its connected route, even when no address in that child
# prefix is currently assigned on the host.
select_nat_ipv6_subnet() {
    local candidate index requested
    local state_dir="${PVE_STATE_DIR:-/usr/local/bin}"
    local subnet_state="${state_dir}/pve_nat_ipv6_subnet"
    local requested_explicit=false
    if [[ -n "${PVE_NAT_IPV6_SUBNET:-}" ]]; then
        requested="${PVE_NAT_IPV6_SUBNET}"
        requested_explicit=true
    elif [ -s "$subnet_state" ]; then
        requested="$(cat "$subnet_state" 2>/dev/null || true)"
    else
        requested=""
    fi
    candidate="$requested"
    if [ -n "$candidate" ] && ! pve_nat_ipv6_candidate_is_safe "$candidate"; then
        if [[ "$requested_explicit" == true ]]; then
            _red "Requested PVE NAT IPv6 subnet is invalid or overlaps a host route: ${candidate}"
            _red "请求的 PVE NAT IPv6 子网无效或与宿主机路由重叠：${candidate}"
            return 1
        fi
        candidate=""
    fi
    for index in $(seq 0 255); do
        [ -n "$candidate" ] || candidate="$(python3 - "$index" <<'PY'
import ipaddress
import sys
base = ipaddress.IPv6Network("fd42:5339:296f:1f00::/56")
print(ipaddress.IPv6Network((int(base.network_address) + (int(sys.argv[1]) << 64), 64)))
PY
)"
        if pve_nat_ipv6_candidate_is_safe "$candidate"; then
            break
        fi
        candidate=""
    done
    if [ -z "$candidate" ] || ! pve_nat_ipv6_candidate_is_safe "$candidate"; then
        _red "Unable to find a host-disjoint private IPv6 NAT subnet"
        _red "无法找到与宿主机网络不冲突的私有 IPv6 NAT 网段"
        return 1
    fi
    nat_ipv6_subnet="$candidate"
    nat_ipv6_gateway="$(python3 - "$candidate" <<'PY'
import ipaddress
import sys
network = ipaddress.IPv6Network(sys.argv[1], strict=False)
print(ipaddress.IPv6Address(int(network.network_address) + 1))
PY
)"
    write_network_state_atomic "$subnet_state" "$nat_ipv6_subnet" validate_ipv6_network_value || return 1
    write_network_state_atomic "${state_dir}/pve_nat_ipv6_gateway" "$nat_ipv6_gateway" validate_ipv6_value || return 1
    _green "Selected PVE IPv6 NAT subnet: ${nat_ipv6_subnet} (gateway ${nat_ipv6_gateway})"
    _green "已选择 PVE IPv6 NAT 网段：${nat_ipv6_subnet}（网关 ${nat_ipv6_gateway}）"
}

# 配置vmbr1网桥
configure_vmbr1() {
    chattr -i /etc/network/interfaces
    if grep -q "vmbr1" /etc/network/interfaces; then
        _blue "vmbr1 already exists in /etc/network/interfaces"
        _blue "vmbr1 已存在在 /etc/network/interfaces"
    elif [ -f "/usr/local/bin/iface_auto.txt" ]; then
        add_vmbr1_with_accept_ra
    elif [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ] || [ "$status_he" = true ]; then
        add_vmbr1_ipv4_only
    else
        add_vmbr1_with_ipv6
    fi
    # NAT66 also enables forwarding. Preserve router advertisements on the
    # actual uplink even when no direct IPv6 vmbr2 is configured.
    if [ -n "${nat_ipv6_subnet:-}" ]; then
        configure_ipv6_forwarding vmbr1 || return 1
    fi
}

# 添加带RA接受的vmbr1
add_vmbr1_with_accept_ra() {
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr1
iface vmbr1 inet static
    address ${nat_ipv4_gateway}
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up echo 1 > /proc/sys/net/ipv4/conf/vmbr1/proxy_arp
    post-up nft -f /etc/nftables.conf 2>/dev/null || true
EOF
    else
        cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr1
iface vmbr1 inet static
    address ${nat_ipv4_gateway}
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up echo 1 > /proc/sys/net/ipv4/conf/vmbr1/proxy_arp
    post-up iptables -t nat -A POSTROUTING -s '${nat_ipv4_subnet}' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '${nat_ipv4_subnet}' -o vmbr0 -j MASQUERADE
EOF
    fi
}

# 仅添加IPV4配置的vmbr1
add_vmbr1_ipv4_only() {
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr1
iface vmbr1 inet static
    address ${nat_ipv4_gateway}
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up echo 1 > /proc/sys/net/ipv4/conf/vmbr1/proxy_arp
    post-up nft -f /etc/nftables.conf 2>/dev/null || true
EOF
    else
        cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr1
iface vmbr1 inet static
    address ${nat_ipv4_gateway}
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up echo 1 > /proc/sys/net/ipv4/conf/vmbr1/proxy_arp
    post-up iptables -t nat -A POSTROUTING -s '${nat_ipv4_subnet}' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '${nat_ipv4_subnet}' -o vmbr0 -j MASQUERADE
EOF
    fi
}

# 添加带IPV6配置的vmbr1
add_vmbr1_with_ipv6() {
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        # nftables: masquerade rules managed by nftables.service, add IPv6 masquerade to nft
        nft add rule ip6 nat postrouting ip6 saddr "${nat_ipv6_subnet}" oifname "vmbr0" masquerade 2>/dev/null || true
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf
        nft list ruleset >> /etc/nftables.conf
        cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr1
iface vmbr1 inet static
    address ${nat_ipv4_gateway}
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up echo 1 > /proc/sys/net/ipv4/conf/vmbr1/proxy_arp
    post-up nft -f /etc/nftables.conf 2>/dev/null || true

iface vmbr1 inet6 static
    address ${nat_ipv6_gateway}/64
    post-up sysctl -w net.ipv6.conf.all.forwarding=1
EOF
    else
        cat <<EOF | sudo tee -a /etc/network/interfaces
auto vmbr1
iface vmbr1 inet static
    address ${nat_ipv4_gateway}
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up echo 1 > /proc/sys/net/ipv4/conf/vmbr1/proxy_arp
    post-up iptables -t nat -A POSTROUTING -s '${nat_ipv4_subnet}' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '${nat_ipv4_subnet}' -o vmbr0 -j MASQUERADE

iface vmbr1 inet6 static
    address ${nat_ipv6_gateway}/64
    post-up sysctl -w net.ipv6.conf.all.forwarding=1
    post-up ip6tables -t nat -A POSTROUTING -s ${nat_ipv6_subnet} -o vmbr0 -j MASQUERADE
    post-down ip6tables -t nat -D POSTROUTING -s ${nat_ipv6_subnet} -o vmbr0 -j MASQUERADE
EOF
    fi
}

# 配置直连 IPv6 网桥（仅明确委派前缀、已有桥或 HE/6in4 时）
configure_vmbr2() {
    local appended_file direct_config direct_bridge alias_addresses ip delay
    local -a direct_values
    chattr -i /etc/network/interfaces
    appended_file="/usr/local/bin/pve_appended_content.txt"
    if [ -s "$appended_file" ]; then
        tmp_script="/usr/local/bin/check_ipv6.sh"
        echo '#!/bin/bash' > "$tmp_script"
        echo "" >> "$tmp_script"
        counter=0
        alias_addresses=$(pve_ipv6_configured_alias_addresses "$appended_file") || return 1
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            delay=$((counter * 6))
            echo "sleep $delay; curl --interface $ip -6 -s https://ifconfig.co &" >> "$tmp_script"
            counter=$((counter + 1))
        done <<<"$alias_addresses"
        echo "wait" >> "$tmp_script"
        chmod +x "$tmp_script"
        (crontab -l 2>/dev/null; echo "*/15 * * * * bash $tmp_script") | sort -u | crontab -
        return 0
    fi

    if pve_direct_ipv6_requested; then
        if ! direct_config="$(pve_direct_ipv6_env_config)"; then
            _red "Invalid explicit PVE direct IPv6 configuration; keeping IPv6 NAT66 only"
            _red "显式 PVE 直连 IPv6 配置无效；仅保留 IPv6 NAT66"
            return 1
        fi
        mapfile -t direct_values <<<"$direct_config"
        [ "${#direct_values[@]}" -eq 6 ] || return 1
        direct_bridge="${direct_values[4]}"
        if pve_network_bridge_exists "$direct_bridge"; then
            _blue "${direct_bridge} already exists; preserving the existing direct IPv6 bridge"
            _blue "${direct_bridge} 已存在；保留已有直连 IPv6 网桥"
        elif [ -f /usr/local/bin/pve_maximum_subset ] && [ "$(cat /usr/local/bin/pve_maximum_subset)" = false ]; then
            _blue "No set ${direct_bridge}"
        else
            configure_vmbr2_with_explicit_ipv6_prefix "${direct_values[@]}" || return 1
        fi
    elif pve_network_bridge_exists vmbr2; then
        # Preserve historical NDP bridges, including a working /64 or non-nibble
        # delegated prefix. Their presence is stronger evidence than a host-only
        # SLAAC address and must not be replaced during an upgrade.
        _blue "vmbr2 already exists; preserving the existing direct IPv6 bridge"
        _blue "vmbr2 已存在；保留已有直连 IPv6 网桥"
    elif [ "$status_he" = true ]; then
        if [ -f /usr/local/bin/pve_maximum_subset ] && [ "$(cat /usr/local/bin/pve_maximum_subset)" = false ]; then
            _blue "No set vmbr2"
        else
            configure_vmbr2_with_he_tunnel || return 1
        fi
    else
        # A regular SLAAC /64 or /128 is not a delegation. Keep NAT66 for new
        # installs rather than synthesizing a public child prefix on vmbr2.
        disable_ndpresponder
        _blue "No delegated direct IPv6 prefix detected; using IPv6 NAT66"
        _blue "未检测到已委派的直连 IPv6 前缀；使用 IPv6 NAT66"
    fi
}

# 为HE隧道配置vmbr2
configure_vmbr2_with_he_tunnel() {
    chattr -i /etc/network/interfaces
    sudo tee -a /etc/network/interfaces <<EOF

${temp_config}
EOF
    cat <<EOF | sudo tee -a /etc/network/interfaces

auto vmbr2
iface vmbr2 inet6 static
    address ${new_subnet}
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF
    if [ -f "/usr/local/bin/ndpresponder" ]; then
        new_exec_start="ExecStart=/usr/local/bin/ndpresponder -i he-ipv6 -n ${new_subnet}"
        file_path="/etc/systemd/system/ndpresponder.service"
        sed -i "s|^ExecStart=.*|${new_exec_start}|" "$file_path"
    fi
    pve_save_direct_ipv6_config "$new_subnet" "${new_subnet%/*}" routed "$ipv6_gateway" vmbr2 tunnel || return 1
    configure_ipv6_forwarding vmbr2
}

# 为明确委派的 IPv6 前缀配置直连网桥
configure_vmbr2_with_explicit_ipv6_prefix() {
    local direct_prefix="$1" direct_gateway="$2" direct_mode="$3" direct_upstream_gateway="$4"
    local direct_bridge="$5" direct_transport="$6" ndp_interface new_exec_start file_path
    chattr -i /etc/network/interfaces
    cat <<EOF | sudo tee -a /etc/network/interfaces
auto ${direct_bridge}
iface ${direct_bridge} inet6 static
    address ${direct_gateway}/${direct_prefix##*/}
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF
    if [ "$direct_mode" = ndp ] || [ "$direct_transport" = tunnel ]; then
        ndp_interface="$(pve_direct_ndp_interface "$direct_transport")" || return 1
        validate_pve_direct_ipv6_bridge_value "$ndp_interface" || return 1
        if [ -f "/usr/local/bin/ndpresponder" ] && [ -f "/etc/systemd/system/ndpresponder.service" ]; then
            new_exec_start="ExecStart=/usr/local/bin/ndpresponder -i ${ndp_interface} -n ${direct_prefix}"
            file_path="/etc/systemd/system/ndpresponder.service"
            sed -i "s|^ExecStart=.*|${new_exec_start}|" "$file_path"
        fi
    else
        disable_ndpresponder
    fi
    pve_save_direct_ipv6_config "$direct_prefix" "$direct_gateway" "$direct_mode" "$direct_upstream_gateway" "$direct_bridge" "$direct_transport" || return 1
    configure_ipv6_forwarding "$direct_bridge"
}


# 配置IPV6转发设置
configure_ipv6_forwarding() {
    local direct_bridge="${1:-vmbr2}" uplink runtime_uplink
    validate_pve_direct_ipv6_bridge_value "$direct_bridge" || return 1
    uplink="$(pve_ipv6_uplink_interface 2>/dev/null || true)"
    [ -n "$uplink" ] || uplink=vmbr0
    runtime_uplink="$(pve_ipv6_json_probe default_interface 2>/dev/null || true)"
    # A first install can still route through the physical port while vmbr0
    # already owns it in the pending interfaces file. Protect that live port
    # before turning on forwarding, then persist RA on the future bridge.
    if [ "$runtime_uplink" != "$uplink" ] && validate_interface_value "$runtime_uplink" &&
       [ -e "${PVE_IPV6_PROC_CONF_ROOT:-/proc/sys/net/ipv6/conf}/${runtime_uplink}/accept_ra" ]; then
        sysctl -w "net.ipv6.conf.${runtime_uplink}.accept_ra=2" >/dev/null 2>&1 || return 1
    fi
    # Keep SLAAC router advertisements on the actual external uplink after
    # enabling forwarding, otherwise Linux can expire the host default route.
    update_sysctl "net.ipv6.conf.${uplink}.accept_ra=2" || return 1
    pve_install_ipv6_ifup_hook || return 1
    update_sysctl "net.ipv6.conf.all.forwarding=1" || return 1
    # NDP proxying is meaningful only on bridges that carry this topology.
    # Do not make unrelated current or future interfaces proxy NDP packets.
    update_sysctl "net.ipv6.conf.${uplink}.proxy_ndp=1" || return 1
    update_sysctl "net.ipv6.conf.vmbr1.proxy_ndp=1" || return 1
    update_sysctl "net.ipv6.conf.${direct_bridge}.proxy_ndp=1" || return 1
}

# A bridged SLAAC address can disappear when ifupdown moves the provider's
# physical port under vmbr0 and then reloads networking. Keep the exact live
# address and gateway observed before that transition and restore them on the
# resulting IPv6 uplink. This is deliberately address based instead of
# assuming a /64 or a fixed interface name.
restore_host_ipv6_runtime() {
    local bindings="${host_ipv6_runtime_address_bindings:-}" gateway="${host_ipv6_runtime_gateway:-}" uplink binding_interface cidr address prefix route_commands route_command
    local -a route_command_args
    [ -n "$bindings" ] || [ "${host_ipv6_runtime_has_default_route:-false}" = true ] || return 0
    if [ -n "$gateway" ]; then
        validate_ipv6_value "$gateway" || return 1
    fi
    uplink="$(pve_ipv6_uplink_interface 2>/dev/null || true)"
    [ -n "$uplink" ] || uplink="vmbr0"
    validate_interface_value "$uplink" || return 1
    sysctl -q -w "net.ipv6.conf.${uplink}.accept_ra=2" >/dev/null 2>&1 || true
    while IFS=$'\t' read -r binding_interface cidr; do
        [ -n "$cidr" ] || continue
        validate_interface_value "$binding_interface" || return 1
        address="${cidr%/*}"
        prefix="${cidr##*/}"
        validate_ipv6_value "$address" || return 1
        validate_ipv6_prefixlen_value "$prefix" || return 1
        if [ "$binding_interface" = "${host_ipv6_runtime_interface:-}" ]; then
            binding_interface="$uplink"
        fi
        ip -6 addr replace "${address}/${prefix}" dev "$binding_interface" || return 1
    done <<<"$bindings"
    if [ "${host_ipv6_runtime_has_default_route:-false}" = true ]; then
        route_commands=$(PVE_IPV6_ROUTE_JSON_OVERRIDE="${host_ipv6_runtime_route_json:-}" pve_ipv6_json_probe default_routes_restore "${host_ipv6_runtime_interface:-}" "$uplink") || return 1
        while IFS= read -r route_command; do
            [ -n "$route_command" ] || continue
            read -r -a route_command_args <<<"$route_command"
            ip "${route_command_args[@]}" || return 1
        done <<<"$route_commands"
    fi
}

# systemd-sysctl can run before ifupdown creates a PVE bridge. Reapply the
# persisted per-interface settings whenever the bridge or uplink comes up.
pve_install_ipv6_ifup_hook() {
    local hook="${PVE_IPV6_IFUP_HOOK_FILE:-/etc/network/if-up.d/99-oneclickvirt-ipv6-sysctl}"
    local config="${PVE_IPV6_SYSCTL_CONFIG_FILE:-/etc/sysctl.d/99-oneclickvirt-pve-ipv6.conf}"
    local temporary
    mkdir -p "$(dirname "$hook")" || return 1
    temporary="$(mktemp "${hook}.XXXXXX")" || return 1
    cat >"$temporary" <<'HOOK'
#!/bin/sh
set -eu
case "${IFACE:-}" in
    ''|*[!A-Za-z0-9_.:-]*) exit 0 ;;
esac
config='__PVE_SYSCTL_CONFIG__'
[ -r "$config" ] || exit 0
for setting in accept_ra proxy_ndp; do
    key="net.ipv6.conf.${IFACE}.${setting}"
    value=$(awk -F= -v key="$key" '$1 == key { result=$2 } END { gsub(/[[:space:]]/, "", result); print result }' "$config")
    case "$value" in
        0|1|2) sysctl -q -w "$key=$value" >/dev/null ;;
    esac
done
HOOK
    # The path is controlled by this installer, not a command argument.
    sed "s|__PVE_SYSCTL_CONFIG__|${config}|" "$temporary" >"${temporary}.rendered" || {
        rm -f "$temporary" "${temporary}.rendered"
        return 1
    }
    mv -f "${temporary}.rendered" "$temporary" || { rm -f "$temporary" "${temporary}.rendered"; return 1; }
    chmod 755 "$temporary" || { rm -f "$temporary"; return 1; }
    mv -f "$temporary" "$hook"
}

# 安装并配置防火墙
setup_firewall() {
    local nft_config="${PVE_NFTABLES_CONF:-/etc/nftables.conf}"
    # 优先尝试安装 nftables（Debian 10+ 默认）
    if ! command -v nft >/dev/null 2>&1; then
        _green "Attempting to install nftables..."
        _green "尝试安装 nftables..."
        apt-get install -y nftables 2>/dev/null || {
            _yellow "Failed to install nftables, will use iptables instead"
            _yellow "nftables 安装失败，将使用 iptables"
        }
    fi
    
    # 检测 nftables 是否可用
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        _green "Using nftables for firewall management"
        _green "使用 nftables 进行防火墙管理"
        nft add table ip nat 2>/dev/null || true
        nft 'add chain ip nat prerouting { type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
        nft 'add chain ip nat postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
        if ! nft list chain ip nat postrouting 2>/dev/null | grep -Fq "ip saddr ${nat_ipv4_subnet} oifname \"vmbr0\" masquerade"; then
            nft add rule ip nat postrouting ip saddr "$nat_ipv4_subnet" oifname "vmbr0" masquerade
        fi
        nft add table ip6 nat 2>/dev/null || true
        nft 'add chain ip6 nat prerouting { type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
        nft 'add chain ip6 nat postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
        # vmbr1 may have been created by the IPv4-only/RA branch, or may
        # already exist from an older install. NAT66 must not depend on which
        # bridge-creation branch happened to run. The installer may still
        # route through the physical NIC before ifupdown moves it under vmbr0,
        # so use the configured post-install uplink. The host's public IPv6
        # address remains on that uplink.
        if [ -n "${nat_ipv6_subnet:-}" ]; then
            nat66_uplink="$(pve_ipv6_uplink_interface)" || return 1
            validate_interface_value "$nat66_uplink" || return 1
            if ! nft list chain ip6 nat postrouting 2>/dev/null | grep -Fq "ip6 saddr ${nat_ipv6_subnet} oifname \"${nat66_uplink}\" masquerade"; then
                nft add rule ip6 nat postrouting ip6 saddr "$nat_ipv6_subnet" oifname "$nat66_uplink" masquerade || return 1
            fi
        fi
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > "$nft_config"
        nft list ruleset >> "$nft_config"
        systemctl enable nftables 2>/dev/null || true
    else
        _green "nftables not available, using iptables with iptables-persistent"
        _green "nftables 不可用，使用 iptables 和 iptables-persistent"
        apt-get install -y iptables iptables-persistent
        modprobe ip6table_nat 2>/dev/null || true
        modprobe ip6table_raw 2>/dev/null || true
        modprobe nf_nat 2>/dev/null || true
        if ! iptables -t nat -C POSTROUTING -s "$nat_ipv4_subnet" -o vmbr0 -j MASQUERADE 2>/dev/null; then
            iptables -t nat -A POSTROUTING -s "$nat_ipv4_subnet" -o vmbr0 -j MASQUERADE
        fi
        if [ -n "${nat_ipv6_subnet:-}" ]; then
            nat66_uplink="$(pve_ipv6_uplink_interface)" || return 1
            validate_interface_value "$nat66_uplink" || return 1
            if ! ip6tables -t nat -C POSTROUTING -s "$nat_ipv6_subnet" -o "$nat66_uplink" -j MASQUERADE 2>/dev/null; then
                ip6tables -t nat -A POSTROUTING -s "$nat_ipv6_subnet" -o "$nat66_uplink" -j MASQUERADE || return 1
            fi
            command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
        fi
    fi
    update_sysctl "net.ipv4.ip_forward=1"
    ${sysctl_path} -p
}

restart_network_services() {
    service networking restart
    systemctl restart networking.service
    sleep 3
    ifreload -ad
    # ifreload may complete successfully before a cloud RA is received. Put
    # the host's original IPv6 address and default route back immediately so
    # creating a NAT bridge never strands the provider node.
    restore_host_ipv6_runtime || {
        _red "Unable to restore the host IPv6 address/default route after network reload"
        _red "网络重载后无法恢复宿主机 IPv6 地址或默认路由"
        return 1
    }
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf
        nft list ruleset >> /etc/nftables.conf
    else
        iptables-save | awk '{if($1=="COMMIT"){delete x}}$1=="-A"?!x[$0]++:1' | iptables-restore
    fi
}

setup_ndpresponder() {
    if [ -f "/usr/local/bin/ndpresponder" ] && [ -f "/etc/systemd/system/ndpresponder.service" ]; then
        echo "Found ndpresponder binary and service file, setting up..."
        echo "已找到 ndpresponder 二进制文件和服务文件，正在配置..."
        systemctl daemon-reload
        systemctl enable ndpresponder.service
        systemctl start ndpresponder.service
        systemctl status ndpresponder.service 2>/dev/null
        return 0
    else
        echo "ndpresponder binary or service file not found."
        echo "未找到 ndpresponder 二进制文件或服务文件。"
        return 1
    fi
}

backup_and_clean_interfaces() {
    if [ ! -f /etc/network/interfaces_nat.bak ]; then
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
    fi
}

clean_cache_files() {
    if [ -f "/etc/network/interfaces.new" ]; then
        chattr -i /etc/network/interfaces.new
        rm -rf /etc/network/interfaces.new
    fi
}

check_ndpresponder_status() {
    appended_file="/usr/local/bin/pve_appended_content.txt"
    if [ ! -s "$appended_file" ]; then
        service_status=$(systemctl is-active ndpresponder.service)
        if [[ "$service_status" == "active" || "$service_status" == "activating" ]]; then
            _green "The ndpresponder service started successfully and is running, and the host can open a service with a separate IPV6 address."
            _green "ndpresponder服务启动成功且正在运行，宿主机可开设带独立IPV6地址的服务。"
        else
            if grep -q "vmbr2" /etc/network/interfaces; then
                _green "Please perform reboot to reboot the server to load the IPV6 configuration, otherwise IPV6 is not available"
                _green "请执行 reboot 重启服务器以加载IPV6配置，否则IPV6不可用"
            else
                _green "The status of the ndpresponder service is abnormal and the host can not open a service with a separate IPV6 address."
                _green "ndpresponder服务状态异常，宿主机不可开设带独立IPV6地址的服务。"
            fi
        fi
    elif [ -s "$appended_file" ]; then
        _green "Additional IPv6 addresses exist for mapping by NAT, and the host can open services with separate IPV6 addresses."
        _green "存在额外的IPv6地址可供NAT进行映射，宿主机可开设带独立IPV6地址的服务。"
    fi
}

install_required_tools
request_ipv6
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
check_cdn_file
get_system_arch
sysctl_path=$(which sysctl)
detect_network_interfaces || exit 1
detect_he_tunnel || exit 1
install_ndpresponder
detect_ipv4_info || exit 1
prepare_network_interfaces
configure_vmbr0
select_nat_ipv4_subnet || exit 1
select_nat_ipv6_subnet || exit 1
configure_vmbr1 || exit 1
configure_vmbr2 || exit 1
chattr +i /etc/network/interfaces
rm -rf /usr/local/bin/iface_auto.txt
setup_firewall || exit 1
restart_network_services || exit 1
setup_ndpresponder
backup_and_clean_interfaces
clean_cache_files
systemctl start check-dns.service
sleep 3
check_ndpresponder_status
sleep 1
_green "It is recommended to restart the server once to apply the new configuration."
_green "强烈推荐重启一次服务器，以应用新配置，避免配置不生效的问题。"
_green "you can test open a virtual machine or container to see if the actual network has been applied successfully"
_green "你可以测试开一个虚拟机或者容器看看就知道是不是实际网络已应用成功了"
