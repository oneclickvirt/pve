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

if mode == "ndp" and preferred_bridge_gateway is None:
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
    else:
        bridge_gateway = ipaddress.IPv6Address(int(network.network_address) + 1)
        if bridge_gateway == upstream_gateway:
            bridge_gateway = ipaddress.IPv6Address(int(network.network_address) + 2)

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
    if [ -z "$bridge_gateway" ]; then
        bridge_gateway=$(pve_existing_direct_ipv6_matches "$prefix" "" "$bridge" 2>/dev/null || true)
    fi
    pve_direct_ipv6_normalize "$prefix" "$upstream_gateway" "$mode" "$bridge_gateway" || return 1
    printf '%s\n' "$bridge" "$transport"
}

pve_direct_ipv6_requested() {
    [ -n "${PVE_IPV6_ROUTED_PREFIX:-}" ] || [ -n "${PVE_IPV6_DIRECT_GATEWAY:-}" ] || [ -n "${PVE_IPV6_DIRECT_MODE:-}" ] ||
        [ -n "${PVE_IPV6_BRIDGE_GATEWAY:-}" ] || [ -n "${PVE_IPV6_DIRECT_BRIDGE:-}" ] || [ -n "${PVE_IPV6_DIRECT_TRANSPORT:-}" ]
}

# Only use a static, currently bound prefix on the default-route interface.
# A dynamic SLAAC address or a tunnel's transfer network is not a guest pool.
pve_auto_direct_ipv6_config() {
    local config addresses routes defaults
    config=$(pve_interfaces_probe json) || return 1
    addresses=$(LC_ALL=C NO_COLOR=1 ip -j -6 addr show) || return 1
    routes=$(LC_ALL=C NO_COLOR=1 ip -j -6 route show table all) || return 1
    defaults=$(LC_ALL=C NO_COLOR=1 ip -j -6 route show default) || return 1
    PVE_AUTO_CONFIG="$config" PVE_AUTO_ADDRESSES="$addresses" PVE_AUTO_ROUTES="$routes" PVE_AUTO_DEFAULTS="$defaults" python3 - <<'PY'
import ipaddress
import json
import os
import re

def payload(name):
    result = json.loads(re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', os.environ[name]))
    if not isinstance(result, list):
        raise ValueError('invalid network JSON')
    return result

try:
    config, addresses, routes, defaults = map(payload, (
        'PVE_AUTO_CONFIG', 'PVE_AUTO_ADDRESSES', 'PVE_AUTO_ROUTES', 'PVE_AUTO_DEFAULTS'))
    uplinks, gateways = [], set()
    for row in defaults:
        if row.get('dst') not in (None, '', 'default') or row.get('type') not in (None, '', 'unicast'):
            continue
        for hop in row.get('nexthops') or row.get('multipath') or [row]:
            device = hop.get('dev') or row.get('dev')
            gateway = hop.get('gateway') or row.get('gateway')
            if device and gateway:
                uplinks.append((device, ipaddress.IPv6Address(gateway)))
    occupied, bindings, tunnel_interfaces = set(), {}, set()
    for row in addresses:
        device = row.get('ifname')
        if (row.get('linkinfo') or {}).get('info_kind') in {'sit', 'ip6tnl', 'tun', 'wireguard', 'gre', 'ip6gre'}:
            tunnel_interfaces.add(device)
        for info in row.get('addr_info', []):
            if info.get('family') != 'inet6':
                continue
            address = ipaddress.IPv6Address(info['local'])
            occupied.add(address)
            flags = set(info.get('flags') or [])
            if info.get('tentative') or info.get('dadfailed') or flags & {'tentative', 'dadfailed', 'dynamic', 'temporary'} or info.get('dynamic') or info.get('temporary'):
                continue
            bindings.setdefault(device, set()).add(str(ipaddress.IPv6Interface(f"{address}/{info['prefixlen']}")))
    parsed_routes = []
    for row in routes:
        for hop in row.get('nexthops') or row.get('multipath') or [row]:
            if hop.get('gateway'):
                occupied.add(ipaddress.IPv6Address(hop['gateway']))
        destination = row.get('dst')
        if destination in (None, '', 'default') or row.get('type') == 'multicast':
            continue
        try:
            network = ipaddress.IPv6Network(destination, strict=False)
        except ValueError:
            if destination in {'local', 'multicast', 'broadcast', 'unreachable', 'blackhole', 'prohibit', 'throw'}:
                continue
            raise
        parsed_routes.append((network, row))
    for device, upstream in uplinks:
        if device in tunnel_interfaces or device == 'he-ipv6':
            continue
        # On the first PVE pass, the pending bridge already owns the static
        # stanza while the live address/default route still use its port.
        owners = {device} | {row['name'] for row in config
            if any(device in ports for ports in row['options'].get('bridge_ports', []))}
        candidates = [cidr for row in config if row['name'] in owners for cidr in row['cidrs']]
        for cidr in candidates:
            if cidr not in bindings.get(device, set()):
                continue
            parent = ipaddress.IPv6Interface(cidr).network
            if not parent.subnet_of(ipaddress.IPv6Network('2000::/3')):
                continue
            target = min(((parent.prefixlen // 8) + 1) * 8, 118)
            if target <= parent.prefixlen:
                target = parent.prefixlen + 1
            if target > 120:
                continue
            conflicts = [network for network, row in parsed_routes if not (
                network == parent and row.get('dev') == device and not row.get('gateway')
                and row.get('type') in (None, '', 'unicast')
                and not row.get('nexthops') and not row.get('multipath'))]
            for child in parent.subnets(new_prefix=target):
                if any(address in child for address in occupied | {upstream}):
                    continue
                if any(child.overlaps(network) for network in conflicts):
                    continue
                gateway = ipaddress.IPv6Address(int(child.network_address) + 1)
                print('\n'.join((child.with_prefixlen, str(gateway), 'ndp', str(upstream), 'vmbr2', 'bridge')))
                raise SystemExit(0)
    raise SystemExit(1)
except (KeyError, TypeError, ValueError):
    raise SystemExit(1)
PY
}

# Test the actual open operation: root's -w check alone does not detect a
# read-only filesystem. Only remove an immutable flag when it is present.
pve_require_writable_network_file() {
    local path="${1:-${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}}" attributes
    path=$(readlink -f "$path") || return 1
    [ -f "$path" ] || return 1
    attributes=$(LC_ALL=C lsattr -d "$path" 2>/dev/null | awk 'NR == 1 {print $1}')
    if [[ "$attributes" == *i* ]]; then
        if ! chattr -i "$path"; then
            _red "Unable to unlock $path; network configuration was not changed"
            _red "无法解锁 ${path}，未修改网络配置"
            return 1
        fi
    fi
    if ! { : >>"$path"; } 2>/dev/null; then
        _red "Cannot write $path; check filesystem permissions and read-only mounts"
        _red "无法写入 ${path}，请检查文件权限及文件系统是否只读"
        return 1
    fi
}

pve_append_network_config() {
    local path="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}" temporary
    # Follow a network-config symlink without replacing the symlink itself.
    path=$(readlink -f "$path") || return 1
    pve_require_writable_network_file "$path" || return 1
    temporary=$(mktemp "${path}.tmp.XXXXXX") || return 1
    if ! cp -p "$path" "$temporary" || ! printf '\n' >>"$temporary" ||
       ! cat >>"$temporary" || ! mv -f "$temporary" "$path"; then
        rm -f "$temporary"
        return 1
    fi
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

pve_interfaces_probe() {
    local mode="${1:-json}" selected="${2:-}" port="${3:-}"
    python3 - "${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}" "$mode" "$selected" "$port" <<'PY'
import glob
import ipaddress
import json
import pathlib
import re
import shlex
import sys

root, mode, selected, port = sys.argv[1:]
seen, stanzas = set(), []

def read_config(path):
    path = pathlib.Path(path).resolve()
    if path in seen:
        return
    if len(seen) >= 256:
        raise ValueError('too many network configuration files')
    seen.add(path)
    current = None
    text = path.read_text(errors='replace').replace('\\\n', ' ')
    for line in text.splitlines():
        fields = line.split()
        if not fields or fields[0].startswith('#'):
            continue
        key = fields[0]
        if key in {'source', 'source-directory'}:
            for pattern in shlex.split(line, comments=True)[1:]:
                pattern = pathlib.Path(pattern)
                if not pattern.is_absolute():
                    pattern = path.parent / pattern
                for match in sorted(glob.glob(str(pattern))):
                    child = pathlib.Path(match)
                    if key == 'source-directory' and child.is_dir():
                        for entry in sorted(child.iterdir()):
                            if entry.is_file() and re.fullmatch(r'[A-Za-z0-9_-]+', entry.name):
                                read_config(entry)
                    elif key == 'source' and child.is_file():
                        read_config(child)
            current = None
        elif key == 'iface':
            fields = shlex.split(line, comments=True)
            current = None
            if len(fields) >= 4:
                current = dict(name=fields[1], family=fields[2], method=fields[3], options={})
                stanzas.append(current)
        elif key in {'auto', 'allow-auto', 'mapping'} or key.startswith('allow-'):
            current = None
        elif current is not None and key in {'address', 'netmask', 'gateway', 'bridge_ports'}:
            current['options'].setdefault(key, []).append(shlex.split(line, comments=True)[1:])

try:
    read_config(root)
    for stanza in stanzas:
        stanza['cidrs'] = []
        if stanza['family'] != 'inet6' or stanza['method'] != 'static':
            continue
        masks = stanza['options'].get('netmask', [])
        for values in stanza['options'].get('address', []):
            if not values:
                continue
            address = values[0]
            if '/' not in address:
                if not masks or not masks[0] or not masks[0][0].isdigit():
                    continue
                address += '/' + masks[0][0]
            try:
                interface = ipaddress.IPv6Interface(address)
            except ValueError:
                continue
            if interface.ip.is_global and interface.ip in ipaddress.IPv6Network('2000::/3'):
                stanza['cidrs'].append(str(interface))
    matches = [row for row in stanzas if row['name'] == selected]
    if mode == 'json':
        print(json.dumps(stanzas))
    elif mode == 'files':
        for path in sorted(seen):
            if '\n' in str(path):
                raise ValueError('invalid network configuration path')
            print(path)
    elif mode == 'exists':
        raise SystemExit(0 if matches else 1)
    elif mode == 'cidr':
        for row in matches:
            for cidr in row['cidrs']:
                print(cidr)
    elif mode == 'gateway':
        for row in matches:
            if row['family'] != 'inet6':
                continue
            for values in row['options'].get('gateway', []):
                if values:
                    print(ipaddress.IPv6Address(values[0]))
    elif mode == 'ports':
        raise SystemExit(0 if any(port in values for row in matches for values in row['options'].get('bridge_ports', [])) else 1)
    elif mode == 'tunnel':
        raise SystemExit(0 if any(row['family'] == 'inet6' and row['method'] in {'v4tunnel', 'tunnel'} for row in stanzas) else 1)
    else:
        raise ValueError('unknown network configuration probe')
except (OSError, TypeError, ValueError):
    raise SystemExit(1)
PY
}

pve_network_bridge_exists() {
    local bridge="$1" interfaces_file="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}"
    validate_pve_direct_ipv6_bridge_value "$bridge" || return 1
    ip link show "$bridge" >/dev/null 2>&1 && return 0
    pve_interfaces_probe exists "$bridge"
}

pve_existing_direct_ipv6_matches() {
    local prefix="$1" gateway="$2" bridge="$3" candidates
    candidates=$(pve_ipv6_json_probe addresses "$bridge") || return 1
    [ -n "$candidates" ] || candidates=$(pve_interfaces_probe cidr "$bridge") || return 1
    python3 - "$prefix" "$gateway" "$candidates" <<'PY'
import ipaddress
import sys
try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
    gateway = ipaddress.IPv6Address(sys.argv[2]) if sys.argv[2] else None
    for value in sys.argv[3].splitlines():
        interface = ipaddress.IPv6Interface(value)
        if interface.network == network and (gateway is None or interface.ip == gateway):
            if gateway is None:
                print(interface.ip)
            raise SystemExit(0)
except ValueError:
    pass
raise SystemExit(1)
PY
}

# A PVE installation may still have its IPv6 default route on a physical NIC
# while it is writing that NIC into vmbr0. Persisting RA/NDP on the physical
# port in that transition would break after the next reload or reboot.
pve_vmbr0_owns_interface() {
    local candidate="$1" interfaces_file
    validate_interface_value "$candidate" || return 1
    interfaces_file="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}"
    pve_interfaces_probe ports vmbr0 "$candidate"
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
        addresses|address_bindings|reserved_addresses|linklocal)
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
                if info.get('family') != 'inet6':
                    continue
                if mode == 'reserved_addresses':
                    print(ipaddress.IPv6Address(info['local']))
                    continue
                if info.get('tentative') or info.get('dadfailed'):
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
        if command -v udevadm >/dev/null 2>&1; then
            udevadm control --reload || return 1
        fi
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
    if pve_interfaces_probe exists he-ipv6; then
        pve_require_writable_network_file || return 1
        local covert_tmp
        covert_tmp=$(mktemp /root/covert.sh.tmp.XXXXXX) || return 1
        if ! wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/6in4/main/covert.sh" -O "$covert_tmp" || [ ! -s "$covert_tmp" ] || ! chmod 755 "$covert_tmp" || ! mv -f -- "$covert_tmp" /root/covert.sh; then
            rm -f -- "$covert_tmp"
            _red "Failed to download HE tunnel helper"
            _red "下载 HE 隧道辅助脚本失败"
            return 1
        fi
        /root/covert.sh || return 1
        sleep 1
        local tunnel_cidr host_cidrs route_json
        tunnel_cidr=$(pve_ipv6_json_probe addresses he-ipv6 | head -n 1) || return 1
        [ -n "$tunnel_cidr" ] || return 1
        ipv6_address="${tunnel_cidr%/*}"
        ipv6_prefixlen="${tunnel_cidr##*/}"
        ipv6_gateway=$(pve_interfaces_probe gateway he-ipv6 | head -n 1) || return 1
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
        # Keep the working tunnel in its original file, including sourced
        # interfaces.d files. A later bridge failure must not remove it.
        status_he=true
    else
        detect_existing_ipv6_config || return 1
    fi

    check_fe80_gateway
}

# 检测已有的IPV6配置
detect_existing_ipv6_config() {
    local preferred_interface live_cidrs persisted_cidr candidate
    pve_capture_host_ipv6_runtime || return 1
    preferred_interface="$host_ipv6_runtime_interface"
    live_cidrs=""
    if [ -n "$preferred_interface" ]; then
        live_cidrs=$(printf '%s\n' "$host_ipv6_runtime_address_bindings" | awk -F '\t' -v selected="$preferred_interface" '$1 == selected {print $2}')
    fi
    if [ -z "$live_cidrs" ]; then
        live_cidrs="$host_ipv6_runtime_cidrs"
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
    # Preserve a working installation and its custom uplink/prefix settings.
    if [ -x /usr/local/bin/ndpresponder ] && [ -s /etc/systemd/system/ndpresponder.service ]; then
        return 0
    fi
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
    pve_require_writable_network_file || return 1
    if [ ! -f /etc/network/interfaces.bak ]; then
        cp /etc/network/interfaces /etc/network/interfaces.bak || return 1
    fi
    # 修正部分网络设置重复的错误
    if [[ -f "/etc/network/interfaces.d/50-cloud-init" && -f "/etc/network/interfaces" ]]; then
        if grep -q "auto lo" "/etc/network/interfaces.d/50-cloud-init" && grep -q "iface lo inet loopback" "/etc/network/interfaces.d/50-cloud-init" && grep -q "auto lo" "/etc/network/interfaces" && grep -q "iface lo inet loopback" "/etc/network/interfaces"; then
            pve_require_writable_network_file /etc/network/interfaces.d/50-cloud-init || return 1
            sed -i '/auto lo/d' "/etc/network/interfaces.d/50-cloud-init" || return 1
            sed -i '/iface lo inet loopback/d' "/etc/network/interfaces.d/50-cloud-init" || return 1
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
    if ! pve_interfaces_probe exists lo; then
        _blue "Can not find 'iface lo inet loopback' in /etc/network/interfaces"
        return 1
    fi
}

# 配置vmbr0网桥
configure_vmbr0() {
    pve_require_writable_network_file || return 1
    if pve_interfaces_probe exists vmbr0; then
        _blue "vmbr0 already exists in /etc/network/interfaces"
        _blue "vmbr0 已存在在 /etc/network/interfaces"
    else
        # 根据不同情况添加vmbr0配置
        if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ] && [ ! -f /usr/local/bin/pve_last_ipv6 ]; then
            # 无IPV6地址情况
            add_vmbr0_ipv4_only || return 1
        elif [ -f /usr/local/bin/pve_slaac_status ] && [ $(cat /usr/local/bin/pve_maximum_subset) = false ] && [ ! -f /usr/local/bin/pve_last_ipv6 ]; then
            # 有IPV6地址，只有一个IPV6地址且后续仅使用一个IPV6地址，存在slaac机制
            add_vmbr0_with_slaac || return 1
        elif [ -f /usr/local/bin/pve_last_ipv6 ]; then
            # 有IPV6地址，不只一个IPV6地址，一个用作网关，一个用作实际地址
            add_vmbr0_with_dual_ipv6 || return 1
        else
            # 有IPV6地址，只有一个IPV6地址，但后续使用最大IPV6子网范围
            add_vmbr0_with_single_ipv6 || return 1
        fi
    fi
    # A global upstream gateway still needs NDP. Never delete the physical
    # port's link-local address as a supposed IPv6/MAC whitelist workaround.
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
    bridge_fd 2
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
    bridge_fd 2

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
    bridge_fd 2

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
    bridge_fd 2

iface vmbr0 inet6 static
    address ${ipv6_address}/${ipv6_prefixlen}
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
    pve_require_writable_network_file || return 1
    if pve_interfaces_probe exists vmbr1; then
        _blue "vmbr1 already exists in /etc/network/interfaces"
        _blue "vmbr1 已存在在 /etc/network/interfaces"
    elif [ -f "/usr/local/bin/iface_auto.txt" ]; then
        add_vmbr1_with_accept_ra || return 1
    elif [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
        add_vmbr1_ipv4_only || return 1
    else
        add_vmbr1_with_ipv6 || return 1
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
    bridge_fd 2
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
    bridge_fd 2
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
    bridge_fd 2
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
    bridge_fd 2
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
    bridge_fd 2
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
    bridge_fd 2
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
            if ! pve_existing_direct_ipv6_matches "${direct_values[0]}" "${direct_values[1]}" "$direct_bridge"; then
                _red "Existing ${direct_bridge} IPv6 does not match the requested prefix/gateway; check the values"
                _red "已有 ${direct_bridge} 的 IPv6 与所填前缀或网关不一致，请检查输入"
                return 1
            fi
            pve_save_direct_ipv6_config "${direct_values[@]}" || return 1
            _blue "${direct_bridge} already exists; preserving the existing direct IPv6 bridge"
            _blue "${direct_bridge} 已存在；保留已有直连 IPv6 网桥"
        else
            # A supplied delegated prefix is an explicit choice, even if an
            # earlier installation disabled host-derived subnet allocation.
            configure_vmbr2_with_explicit_ipv6_prefix "${direct_values[@]}" || return 1
        fi
    elif direct_bridge=$(read_network_state "$(pve_direct_ipv6_state_file pve_direct_ipv6_bridge)" validate_pve_direct_ipv6_bridge_value 2>/dev/null) && pve_network_bridge_exists "$direct_bridge"; then
        _blue "${direct_bridge} already exists; preserving the existing direct IPv6 bridge"
        _blue "${direct_bridge} 已存在；保留已有直连 IPv6 网桥"
    elif pve_network_bridge_exists vmbr2; then
        # Preserve historical NDP bridges, including a working /64 or non-nibble
        # delegated prefix. Their presence is stronger evidence than a host-only
        # SLAAC address and must not be replaced during an upgrade.
        _blue "vmbr2 already exists; preserving the existing direct IPv6 bridge"
        _blue "vmbr2 已存在；保留已有直连 IPv6 网桥"
    elif [ "$status_he" = true ]; then
        if [ -f /usr/local/bin/pve_maximum_subset ] && [ "$(cat /usr/local/bin/pve_maximum_subset)" = false ]; then
            _blue "No set vmbr2"
        elif [ ! -x /usr/local/bin/ndpresponder ] || [ ! -s /etc/systemd/system/ndpresponder.service ]; then
            _yellow "NDP responder is unavailable; using IPv6 NAT66"
            _yellow "NDP 服务未安装成功，使用 IPv6 NAT66"
        else
            configure_vmbr2_with_he_tunnel || return 1
        fi
    elif [ -n "${pve_detected_direct_ipv6_config:-}" ]; then
        mapfile -t direct_values <<<"$pve_detected_direct_ipv6_config"
        [ "${#direct_values[@]}" -eq 6 ] || return 1
        if [ -f /usr/local/bin/pve_maximum_subset ] && [ "$(cat /usr/local/bin/pve_maximum_subset)" = false ]; then
            _blue "No set ${direct_values[4]}"
        elif [ ! -x /usr/local/bin/ndpresponder ] || [ ! -s /etc/systemd/system/ndpresponder.service ]; then
            _yellow "NDP responder is unavailable; using IPv6 NAT66"
            _yellow "NDP 服务未安装成功，使用 IPv6 NAT66"
        else
            configure_vmbr2_with_explicit_ipv6_prefix "${direct_values[@]}" || return 1
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
    pve_append_network_config <<EOF || return 1

auto vmbr2
iface vmbr2 inet6 static
    address ${new_subnet}
    bridge_ports none
    bridge_stp off
    bridge_fd 2
EOF
    if [ -f "/usr/local/bin/ndpresponder" ]; then
        new_exec_start="ExecStart=/usr/local/bin/ndpresponder -i he-ipv6 -n ${new_subnet}"
        file_path="/etc/systemd/system/ndpresponder.service"
        if ! grep -Fxq "$new_exec_start" "$file_path"; then
            sed -i "s|^ExecStart=.*|${new_exec_start}|" "$file_path" || return 1
            pve_ndpresponder_config_changed=true
        fi
    fi
    pve_save_direct_ipv6_config "$new_subnet" "${new_subnet%/*}" routed "$ipv6_gateway" vmbr2 tunnel || return 1
    configure_ipv6_forwarding vmbr2
}

# 为明确委派的 IPv6 前缀配置直连网桥
configure_vmbr2_with_explicit_ipv6_prefix() {
    local direct_prefix="$1" direct_gateway="$2" direct_mode="$3" direct_upstream_gateway="$4"
    local direct_bridge="$5" direct_transport="$6" ndp_interface new_exec_start file_path
    local normalized
    local -a normalized_values
    normalized=$(pve_direct_ipv6_normalize "$direct_prefix" "$direct_upstream_gateway" "$direct_mode" "$direct_gateway") || return 1
    mapfile -t normalized_values <<<"$normalized"
    [ "${#normalized_values[@]}" -eq 4 ] || return 1
    direct_prefix="${normalized_values[0]}"
    direct_gateway="${normalized_values[1]}"
    direct_mode="${normalized_values[2]}"
    direct_upstream_gateway="${normalized_values[3]}"
    validate_pve_direct_ipv6_bridge_value "$direct_bridge" || return 1
    validate_pve_direct_ipv6_transport_value "$direct_transport" || return 1
    local host_addresses upstream_gateway
    host_addresses=$(pve_ipv6_json_probe reserved_addresses) || return 1
    upstream_gateway=$(pve_ipv6_json_probe gateway) || return 1
    if [ "$direct_gateway" = "$upstream_gateway" ] || printf '%s\n' "$host_addresses" | grep -Fxq "$direct_gateway"; then
        _red "Bridge gateway is already used by the host or upstream router; set PVE_IPV6_BRIDGE_GATEWAY to an unused address"
        _red "网桥网关已被宿主机或上游路由器使用，请用 PVE_IPV6_BRIDGE_GATEWAY 指定空闲地址"
        return 1
    fi
    pve_append_network_config <<EOF || return 1
auto ${direct_bridge}
iface ${direct_bridge} inet6 static
    address ${direct_gateway}/${direct_prefix##*/}
    bridge_ports none
    bridge_stp off
    bridge_fd 2
EOF
    if [ "$direct_mode" = ndp ] || [ "$direct_transport" = tunnel ]; then
        ndp_interface="$(pve_direct_ndp_interface "$direct_transport")" || return 1
        validate_pve_direct_ipv6_bridge_value "$ndp_interface" || return 1
        if [ -f "/usr/local/bin/ndpresponder" ] && [ -f "/etc/systemd/system/ndpresponder.service" ]; then
            new_exec_start="ExecStart=/usr/local/bin/ndpresponder -i ${ndp_interface} -n ${direct_prefix}"
            file_path="/etc/systemd/system/ndpresponder.service"
            if ! grep -Fxq "$new_exec_start" "$file_path"; then
                sed -i "s|^ExecStart=.*|${new_exec_start}|" "$file_path" || return 1
                pve_ndpresponder_config_changed=true
            fi
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
    # update_sysctl applies the exact key immediately and persists it under
    # sysctl.d. Debian 13 need not have the legacy /etc/sysctl.conf at all.
    update_sysctl "net.ipv4.ip_forward=1"
}

# Keep a per-run copy of every recursively sourced file. The rollback timer
# runs independently of SSH, so a lost connection cannot leave it unexecuted.
pve_configure_ufw_forwarding() {
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active$' || return 0
    local uplink direct_bridge direct_prefix
    uplink=$(pve_ipv6_uplink_interface) || return 1
    validate_interface_value "$uplink" || return 1
    ufw route allow in on vmbr1 out on vmbr0 from "$nat_ipv4_subnet" || return 1
    ufw route allow in on vmbr0 out on vmbr1 to "$nat_ipv4_subnet" || return 1
    if [ -n "${nat_ipv6_subnet:-}" ]; then
        ufw route allow in on vmbr1 out on "$uplink" from "$nat_ipv6_subnet" || return 1
        ufw route allow in on "$uplink" out on vmbr1 to "$nat_ipv6_subnet" || return 1
    fi
    direct_bridge=$(read_network_state "$(pve_direct_ipv6_state_file pve_direct_ipv6_bridge)" validate_pve_direct_ipv6_bridge_value 2>/dev/null || true)
    direct_prefix=$(read_network_state "$(pve_direct_ipv6_state_file pve_direct_ipv6_prefix)" is_single_network_value 2>/dev/null || true)
    if [ -n "$direct_bridge" ] && [ -n "$direct_prefix" ]; then
        is_public_ipv6 "${direct_prefix%/*}" || return 1
        python3 - "$direct_prefix" <<'PY' || return 1
import ipaddress, sys
network = ipaddress.IPv6Network(sys.argv[1], strict=True)
raise SystemExit(0 if network.prefixlen <= 120 else 1)
PY
        ufw route allow in on "$direct_bridge" out on "$uplink" from "$direct_prefix" || return 1
        ufw route allow in on "$uplink" out on "$direct_bridge" to "$direct_prefix" || return 1
    fi
}

pve_network_transaction_files() {
    local state_dir="${PVE_STATE_DIR:-/usr/local/bin}" name
    for name in pve_main_interface pve_mac_address pve_check_ipv6 pve_ipv6_gateway \
        pve_ipv6_prefixlen pve_ipv6_real_prefixlen pve_ipv4_address pve_ipv4_gateway \
        pve_ipv4_subnet pve_nat_subnet pve_nat_gateway pve_nat_ipv6_subnet \
        pve_nat_ipv6_gateway pve_direct_ipv6_prefix pve_direct_ipv6_gateway \
        pve_direct_ipv6_mode pve_direct_ipv6_upstream_gateway pve_direct_ipv6_bridge \
        pve_direct_ipv6_transport; do
        printf '%s/%s\n' "$state_dir" "$name"
    done
    printf '%s\n' "${PVE_SYSCTL_LEGACY_FILE:-/etc/sysctl.conf}" \
        "${PVE_SYSCTL_CONFIG_FILE:-/etc/sysctl.d/99-custom.conf}" \
        "${PVE_IPV6_SYSCTL_CONFIG_FILE:-/etc/sysctl.d/99-oneclickvirt-pve-ipv6.conf}" \
        "${PVE_IPV6_IFUP_HOOK_FILE:-/etc/network/if-up.d/99-oneclickvirt-ipv6-sysctl}" \
        "${PVE_NFTABLES_CONF:-/etc/nftables.conf}" \
        /etc/ufw/user.rules /etc/ufw/user6.rules \
        /etc/systemd/system/ndpresponder.service
}

pve_capture_network_runtime() {
    sysctl -a -r '^net\.(ipv4\.ip_forward|ipv6\.conf\..*\.(forwarding|accept_ra|proxy_ndp))$' \
        >"$pve_network_snapshot/sysctl" 2>/dev/null || return 1
    if command -v nft >/dev/null 2>&1 && nft list ruleset >"$pve_network_snapshot/rules.nft" 2>/dev/null; then
        sed -i '1i flush ruleset' "$pve_network_snapshot/rules.nft"
    else
        rm -f "$pve_network_snapshot/rules.nft"
        iptables-save >"$pve_network_snapshot/rules.v4" || return 1
        ip6tables-save >"$pve_network_snapshot/rules.v6" || return 1
    fi
    systemctl is-active --quiet ndpresponder.service && touch "$pve_network_snapshot/ndp-active"
    systemctl is-enabled --quiet ndpresponder.service && touch "$pve_network_snapshot/ndp-enabled"
    return 0
}

pve_begin_network_transaction() {
    local root="${PVE_NETWORK_BACKUP_ROOT:-/var/lib/oneclickvirt/network-backups}" file
    install -d -m 700 "$root" || return 1
    pve_network_snapshot=$(mktemp -d "$root/change.XXXXXXXX") || return 1
    pve_interfaces_probe files >"$pve_network_snapshot/files" || return 1
    : >"$pve_network_snapshot/absent"
    while IFS= read -r file; do
        if [ -e "$file" ] || [ -L "$file" ]; then
            printf '%s\n' "$file" >>"$pve_network_snapshot/files"
        else
            printf '%s\n' "$file" >>"$pve_network_snapshot/absent"
        fi
    done < <(pve_network_transaction_files)
    tar -cPf "$pve_network_snapshot/config.tar" --verbatim-files-from -T "$pve_network_snapshot/files" || return 1
    pve_capture_network_runtime || return 1
    pve_network_rollback_unit="pve-network-rollback-${BASHPID}"
    {
        printf '#!/bin/bash\nset -eu\nsnapshot=%q\n' "$pve_network_snapshot"
        cat <<'ROLLBACK'
exec 8>"$snapshot/lock"
flock 8
[ ! -e "$snapshot/committed" ] || exit 0
systemctl stop ndpresponder.service 2>/dev/null || true
while IFS= read -r file; do
    chattr -i "$file" 2>/dev/null || true
done <"$snapshot/files"
tar -xPf "$snapshot/config.tar"
while IFS= read -r file; do
    rm -f -- "$file"
done <"$snapshot/absent"
systemctl daemon-reload
if [ -e "$snapshot/ndp-enabled" ]; then
    systemctl enable ndpresponder.service
else
    systemctl disable ndpresponder.service 2>/dev/null || true
fi
[ ! -s "$snapshot/sysctl" ] || sysctl -q -p "$snapshot/sysctl" 2>/dev/null || true
if [ -e "$snapshot/reload-armed" ]; then
    ifreload -a
fi
if [ -f "$snapshot/rules.nft" ]; then
    nft -f "$snapshot/rules.nft"
elif [ -f "$snapshot/rules.v4" ]; then
    iptables-restore <"$snapshot/rules.v4"
    ip6tables-restore <"$snapshot/rules.v6"
fi
if [ -e "$snapshot/ndp-active" ]; then
    systemctl start ndpresponder.service
fi
touch "$snapshot/rolled-back"
ROLLBACK
    } >"$pve_network_snapshot/rollback.sh" || return 1
    chmod 700 "$pve_network_snapshot/rollback.sh" || return 1
    trap 'pve_abort_network_transaction' EXIT
}

pve_abort_network_transaction() {
    [ -n "${pve_network_snapshot:-}" ] || return 0
    [ ! -e "$pve_network_snapshot/committed" ] || return 0
    [ ! -e "$pve_network_snapshot/rolled-back" ] || return 0
    _yellow "Restoring the previous network configuration from $pve_network_snapshot"
    _yellow "正在从 ${pve_network_snapshot} 恢复此前的网络配置"
    bash "$pve_network_snapshot/rollback.sh" || return 1
    systemctl stop "${pve_network_rollback_unit}.timer" >/dev/null 2>&1 || true
}

pve_commit_network_transaction() {
    [ -n "${pve_network_snapshot:-}" ] || return 0
    (
        flock 8 || exit 1
        [ ! -e "$pve_network_snapshot/rolled-back" ] || exit 1
        touch "$pve_network_snapshot/committed"
    ) 8>"$pve_network_snapshot/lock" || return 1
    systemctl stop "${pve_network_rollback_unit}.timer" >/dev/null 2>&1 || true
}

pve_wait_host_address_ready() {
    local family="$1" address="$2" attempt snapshot
    for attempt in {1..12}; do
        snapshot=$(LC_ALL=C NO_COLOR=1 ip -j "-$family" addr show) || return 1
        if python3 - "$address" "$snapshot" <<'PY'
import ipaddress
import json
import sys
try:
    target = ipaddress.ip_address(sys.argv[1])
    ready = any(ipaddress.ip_address(info['local']) == target
        and not info.get('tentative') and not info.get('dadfailed')
        and not set(info.get('flags', [])) & {'tentative', 'dadfailed'}
        for row in json.loads(sys.argv[2]) for info in row.get('addr_info', [])
        if info.get('family') in {'inet', 'inet6'})
except (KeyError, TypeError, ValueError):
    ready = False
raise SystemExit(0 if ready else 1)
PY
        then
            return 0
        fi
        sleep 1
    done
    return 1
}

pve_verify_host_connectivity() {
    local ipv4="${ipv4_address%%/*}" ipv6="${ipv6_address:-}"
    local url family source connected
    local -a urls=("https://www.debian.org/" "https://www.cloudflare.com/")
    [ -z "${PVE_NETWORK_PROBE_URL:-}" ] || urls=("$PVE_NETWORK_PROBE_URL")
    for family in 4 6; do
        if [ "$family" = 6 ]; then
            [ "${host_ipv6_runtime_has_default_route:-false}" = true ] && [ -n "$ipv6" ] || continue
            source="${ipv6%%/*}"
        else
            source="$ipv4"
        fi
        # IPv6 DAD completes asynchronously after the bridge migration.
        # Binding curl before it finishes returns EADDRNOTAVAIL immediately.
        pve_wait_host_address_ready "$family" "$source" || return 1
        connected=false
        for url in "${urls[@]}"; do
            if curl "-$family" --interface "$source" -fsS -o /dev/null --connect-timeout 5 --max-time 12 "$url"; then
                connected=true
                break
            fi
        done
        [ "$connected" = true ] || return 1
    done
    return 0
}

pve_normalize_bridge_forward_delay() {
    # ifupdown2 3.3 rejects the historical fd=0 at syntax-check time even
    # with STP disabled. With STP off, fd=2 has the same forwarding behavior.
    local file
    while IFS= read -r file; do
        pve_require_writable_network_file "$file" || return 1
        python3 - "$file" <<'PY'
import pathlib
import re
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
blocks = re.split(r'(?=^iface\s)', text, flags=re.M)
for index, block in enumerate(blocks):
    if re.search(r'^\s*bridge[-_]stp\s+off\s*$', block, re.M):
        blocks[index] = re.sub(r'^(\s*bridge[-_]fd\s+)0([ \t]*)$', r'\g<1>2\2', block, flags=re.M)
updated = ''.join(blocks)
if updated != text:
    path.write_text(updated)
PY
        [ "$?" -eq 0 ] || return 1
    done < <(pve_interfaces_probe files)
}

restart_network_services() {
    # ifupdown2 can migrate a live physical uplink to a bridge. Restarting
    # networking first tears down the working route and defeats that support.
    command -v ifreload >/dev/null 2>&1 || return 1
    pve_normalize_bridge_forward_delay || return 1
    ifreload -a -s || return 1
    if [ -n "${pve_network_snapshot:-}" ]; then
        touch "$pve_network_snapshot/reload-armed" || return 1
        systemd-run --unit="$pve_network_rollback_unit" --on-active=180s \
            --timer-property=AccuracySec=1s /bin/bash "$pve_network_snapshot/rollback.sh" || return 1
    fi
    ifreload -a || return 1
    # ifreload may complete successfully before a cloud RA is received. Put
    # the host's original IPv6 address and default route back immediately so
    # creating a NAT bridge never strands the provider node.
    restore_host_ipv6_runtime || {
        _red "Unable to restore the host IPv6 address/default route after network reload"
        _red "网络重载后无法恢复宿主机 IPv6 地址或默认路由"
        return 1
    }
    pve_configure_ufw_forwarding || return 1
    if [ -n "${pve_network_snapshot:-}" ]; then
        pve_verify_host_connectivity || return 1
    fi
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf
        nft list ruleset >> /etc/nftables.conf
    else
        iptables-save | awk '{if($1=="COMMIT"){delete x}}$1=="-A"?!x[$0]++:1' | iptables-restore
    fi
}

setup_ndpresponder() {
    local mode transport bridge
    mode=$(read_network_state "$(pve_direct_ipv6_state_file pve_direct_ipv6_mode)" validate_pve_direct_ipv6_mode_value 2>/dev/null || true)
    transport=$(read_network_state "$(pve_direct_ipv6_state_file pve_direct_ipv6_transport)" validate_pve_direct_ipv6_transport_value 2>/dev/null || true)
    bridge=$(read_network_state "$(pve_direct_ipv6_state_file pve_direct_ipv6_bridge)" validate_pve_direct_ipv6_bridge_value 2>/dev/null || true)
    if [ "$mode" = routed ] && [ "$transport" = bridge ] && pve_network_bridge_exists "$bridge"; then
        _green "Direct routed IPv6 bridge is configured"
        _green "已配置路由 IPv6 网桥"
        return 0
    fi
    if [ -z "$mode" ] && ! pve_network_bridge_exists vmbr2 && [ "$transport" != tunnel ]; then
        # NAT66-only installations need no NDP responder.
        return 0
    fi
    if [ -f "/usr/local/bin/ndpresponder" ] && [ -f "/etc/systemd/system/ndpresponder.service" ]; then
        echo "Found ndpresponder binary and service file, setting up..."
        echo "已找到 ndpresponder 二进制文件和服务文件，正在配置..."
        systemctl daemon-reload
        systemctl enable ndpresponder.service || return 1
        if [ "${pve_ndpresponder_config_changed:-false}" = true ]; then
            systemctl restart ndpresponder.service || return 1
            pve_ndpresponder_config_changed=false
        else
            systemctl start ndpresponder.service || return 1
        fi
        systemctl is-active --quiet ndpresponder.service || return 1
        return 0
    else
        echo "ndpresponder binary or service file not found."
        echo "未找到 ndpresponder 二进制文件或服务文件。"
        return 1
    fi
}

backup_and_clean_interfaces() {
    local path="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}" temporary
    path=$(readlink -f "$path") || return 1
    [ -f "${path}_nat.bak" ] && return 0
    cp -p "$path" "${path}_nat.bak" || return 1
    # Older cleanup removed every line between lo and vmbr0, including
    # source directives, other NICs and tunnels. Only remove the migrated
    # physical uplink's stanzas from this file; retain all other topology.
    pve_vmbr0_owns_interface "${interface:-}" || return 0
    pve_require_writable_network_file "$path" || return 1
    temporary=$(mktemp "${path}.tmp.XXXXXX") || return 1
    if ! python3 - "$path" "$interface" >"$temporary" <<'PYCODE'
import pathlib
import sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines(keepends=True)
selected, dropping = sys.argv[2], False
for line in lines:
    fields = line.split()
    if fields and not line[0].isspace() and not fields[0].startswith('#'):
        dropping = fields[0] == 'iface' and len(fields) > 1 and fields[1] == selected
        if fields[0] in {'auto', 'allow-hotplug'} and selected in fields[1:]:
            remaining = [name for name in fields[1:] if name != selected]
            if remaining:
                print(fields[0] + ' ' + ' '.join(remaining))
            continue
    if not dropping:
        print(line, end='')
PYCODE
    then
        rm -f "$temporary"
        return 1
    fi
    if ! chmod --reference="$path" "$temporary" || ! chown --reference="$path" "$temporary" ||
       ! mv -f "$temporary" "$path"; then
        rm -f "$temporary"
        return 1
    fi
    chattr +i "$path" 2>/dev/null || true
}

clean_cache_files() {
    if [ -f "/etc/network/interfaces.new" ]; then
        chattr -i /etc/network/interfaces.new
        rm -rf /etc/network/interfaces.new
    fi
}

check_ndpresponder_status() {
    local mode transport bridge
    mode=$(read_network_state "$(pve_direct_ipv6_state_file pve_direct_ipv6_mode)" validate_pve_direct_ipv6_mode_value 2>/dev/null || true)
    transport=$(read_network_state "$(pve_direct_ipv6_state_file pve_direct_ipv6_transport)" validate_pve_direct_ipv6_transport_value 2>/dev/null || true)
    bridge=$(read_network_state "$(pve_direct_ipv6_state_file pve_direct_ipv6_bridge)" validate_pve_direct_ipv6_bridge_value 2>/dev/null || true)
    if [ "$mode" = routed ] && [ "$transport" = bridge ] && pve_network_bridge_exists "$bridge"; then
        _green "Direct routed IPv6 bridge is configured"
        _green "已配置路由 IPv6 网桥"
        return 0
    fi
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
pve_interfaces_probe json >/dev/null || {
    _red "Unable to read network configuration; check interfaces and its source files"
    _red "无法读取网络配置，请检查 interfaces 及其引用的配置文件"
    exit 1
}
pve_begin_network_transaction || exit 1
pve_require_writable_network_file || exit 1
detect_network_interfaces || exit 1
detect_he_tunnel || exit 1
# Discover before vmbr0 migration changes a physical uplink stanza to /128.
pve_detected_direct_ipv6_config=$(pve_auto_direct_ipv6_config 2>/dev/null || true)
install_ndpresponder
detect_ipv4_info || exit 1
prepare_network_interfaces || exit 1
configure_vmbr0 || exit 1
select_nat_ipv4_subnet || exit 1
select_nat_ipv6_subnet || exit 1
configure_vmbr1 || exit 1
configure_vmbr2 || exit 1
backup_and_clean_interfaces || exit 1
chattr +i /etc/network/interfaces
rm -rf /usr/local/bin/iface_auto.txt
setup_firewall || exit 1
restart_network_services || exit 1
setup_ndpresponder || exit 1
pve_commit_network_transaction || exit 1
clean_cache_files
systemctl start check-dns.service
sleep 3
check_ndpresponder_status
sleep 1
_green "It is recommended to restart the server once to apply the new configuration."
_green "强烈推荐重启一次服务器，以应用新配置，避免配置不生效的问题。"
_green "you can test open a virtual machine or container to see if the actual network has been applied successfully"
_green "你可以测试开一个虚拟机或者容器看看就知道是不是实际网络已应用成功了"
