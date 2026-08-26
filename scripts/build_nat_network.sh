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

update_sysctl() {
    sysctl_config="$1"  # 格式: key=value
    key="${sysctl_config%%=*}"
    value="${sysctl_config#*=}"
    # 目标配置文件（systemd 方式）
    custom_conf="/etc/sysctl.d/99-custom.conf"
    mkdir -p /etc/sysctl.d
    # 检查 /etc/sysctl.conf 是否存在并且在系统加载路径中
    use_etc_sysctl_conf=false
    if [ -f /etc/sysctl.conf ]; then
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
        if grep -q "^$sysctl_config" /etc/sysctl.conf; then
            : # 已经有正确配置
        elif grep -q "^#$sysctl_config" /etc/sysctl.conf; then
            sed -i "s/^#$sysctl_config/$sysctl_config/" /etc/sysctl.conf
        elif grep -q "^$key" /etc/sysctl.conf; then
            sed -i "s|^$key.*|$sysctl_config|" /etc/sysctl.conf
        else
            echo "$sysctl_config" >> /etc/sysctl.conf
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
    candidate=$(ip -6 route show default 2>/dev/null | awk '
        /^default / {
            for (i = 1; i < NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ')
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

check_ipv6() {
    local ipv6_list candidate gateway_prefix
    ipv6_list=$(ip -o -6 addr show scope global 2>/dev/null | awk '$0 !~ / tentative/ {print $4}')
    IPV6=""
    while IFS= read -r candidate; do
        candidate=${candidate%/*}
        if validate_ipv6_value "$candidate" && ! is_private_ipv6 "$candidate"; then
            IPV6="$candidate"
            break
        fi
    done <<<"$ipv6_list"
    if [ ! -f /usr/local/bin/pve_last_ipv6 ] || [ ! -s /usr/local/bin/pve_last_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_last_ipv6)" = "" ]; then
        line_count=$(echo "$ipv6_list" | wc -l)
        if [ "$line_count" -ge 2 ]; then
            # 获取最后一行的内容
            last_ipv6=$(echo "$ipv6_list" | tail -n 1)
            # 切分最后一个:之前的内容
            last_ipv6_prefix="${last_ipv6%:*}:"
            # 与${ipv6_gateway}比较是否相同
            gateway_prefix="${ipv6_gateway:-}"
            gateway_prefix="${gateway_prefix%:*}:"
            if [ "${last_ipv6_prefix}" = "$gateway_prefix" ]; then
                echo $last_ipv6 >/usr/local/bin/pve_last_ipv6
            fi
            _green "The local machine is bound to more than one IPV6 address"
            _green "本机绑定了不止一个IPV6地址"
        fi
    fi

    if [ -n "$IPV6" ]; then
        if ! write_network_state_atomic /usr/local/bin/pve_check_ipv6 "$IPV6" validate_ipv6_value; then
            _yellow "Ignoring invalid IPv6 detection output: ${IPV6@Q}"
            _yellow "忽略无效的 IPv6 检测输出：${IPV6@Q}"
            IPV6=""
            rm -f /usr/local/bin/pve_check_ipv6
        fi
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
    interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
    interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
    check_interface

    if ! validate_interface_value "$interface" || [ ! -d "/sys/class/net/$interface" ]; then
        _red "Detected network interface output is invalid: ${interface@Q}"
        _red "检测到的网口输出无效：${interface@Q}"
        return 1
    fi
    write_network_state_atomic /usr/local/bin/pve_main_interface "$interface" validate_interface_value || return 1

    if [ ! -f /usr/local/bin/pve_mac_address ] || [ ! -s /usr/local/bin/pve_mac_address ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/pve_mac_address)" = "" ]; then
        mac_address=$(ip -o link show dev ${interface} | awk '{print $17}')
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
detect_he_tunnel() {
    status_he=false
    if grep -q "he-ipv6" /etc/network/interfaces; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/6in4/main/covert.sh -O /root/covert.sh
        chmod 755 /root/covert.sh
        /root/covert.sh
        sleep 1
        status_he=true
        chattr -i /etc/network/interfaces
        temp_config=$(awk '/auto he-ipv6/{flag=1; print $0; next} flag && flag++<10' /etc/network/interfaces)
        sed -i '/^auto he-ipv6/,/^$/d' /etc/network/interfaces
        chattr +i /etc/network/interfaces
        ipv6_address=$(echo "$temp_config" | awk '/address/ {print $2}')
        ipv6_gateway=$(echo "$temp_config" | awk '/gateway/ {print $2}')
        ipv6_prefixlen=$(ifconfig he-ipv6 | grep -oP 'prefixlen \K\d+' | head -n 1)
        validate_ipv6_value "$ipv6_address" || return 1
        validate_ipv6_value "$ipv6_gateway" && [[ "$ipv6_gateway" != */* ]] || return 1
        validate_ipv6_prefixlen_value "$ipv6_prefixlen" || return 1
        target_mask=${ipv6_prefixlen}
        remainder=$((target_mask % 8))
        [ "$remainder" -ne 0 ] && ((target_mask += 8 - remainder))
        [ "$target_mask" -gt 128 ] && target_mask=128
        write_network_state_atomic /usr/local/bin/pve_ipv6_prefixlen "$target_mask" validate_ipv6_prefixlen_value || return 1
        ipv6_subnet_2=$(sipcalc --v6split=${target_mask} ${ipv6_gateway}/${ipv6_prefixlen} | awk '/Network/{n++} n==2' | awk '{print $3}' | grep -v '^$')
        ipv6_subnet_2_without_last_segment="${ipv6_subnet_2%:*}:"
        new_subnet="${ipv6_subnet_2_without_last_segment}1/${target_mask}"
        ipv6_address="${ipv6_subnet_2_without_last_segment}1"
        write_network_state_atomic /usr/local/bin/pve_check_ipv6 "$ipv6_address" validate_ipv6_value || return 1
        write_network_state_atomic /usr/local/bin/pve_ipv6_gateway "$ipv6_gateway" validate_ipv6_value || return 1
    else
        detect_existing_ipv6_config
    fi

    check_fe80_gateway
}

# 检测已有的IPV6配置
detect_existing_ipv6_config() {
    if command -v rdisc6 >/dev/null 2>&1 && [ ! -f /usr/local/bin/pve_ipv6_real_prefixlen ]; then
        _blue "Attempting to get real IPv6 prefix from router advertisement..."
        _green "尝试使用从路由器通告中获取真实的 IPv6 前缀..."
        _blue "Using network interface: ${interface}"
        _green "正在使用网络接口: ${interface}"
        rdisc6_output=$(timeout 10 rdisc6 ${interface} 2>/dev/null)
        if [ -n "$rdisc6_output" ]; then
            real_prefixlen=$(echo "$rdisc6_output" | grep -i "Prefix" | grep -oP '[:：]\s*[0-9a-fA-F:]+/\K\d+' | head -n 1)
            if [ -n "$real_prefixlen" ] && [ "$real_prefixlen" -gt 0 ] && [ "$real_prefixlen" -le 128 ]; then
                _green "Found real IPv6 prefix length from router advertisement: /$real_prefixlen"
                _green "从路由器通告中发现真实的 IPv6 前缀长度: /$real_prefixlen"
                write_network_state_atomic /usr/local/bin/pve_ipv6_real_prefixlen "$real_prefixlen" validate_ipv6_prefixlen_value || return 1
            else
                _yellow "Could not parse IPv6 prefix length on interface ${interface}"
                _yellow "无法从接口 ${interface} 中解析 IPv6 前缀长度"
            fi
        else
            _yellow "Could not get router advertisement response on interface ${interface} (timeout or no response)"
            _yellow "无法在接口 ${interface} 上获取路由器通告响应(超时或无响应)"
        fi
    fi
    if real_prefixlen=$(read_network_state /usr/local/bin/pve_ipv6_real_prefixlen validate_ipv6_prefixlen_value 2>/dev/null); then
        ipv6_prefixlen="$real_prefixlen"
        _blue "Using real IPv6 prefix length: /$ipv6_prefixlen"
        _green "检测到的真实 IPv6 前缀长度: /$ipv6_prefixlen"
    else
        ipv6_prefixlen=$(read_network_state /usr/local/bin/pve_ipv6_prefixlen validate_ipv6_prefixlen_value 2>/dev/null || true)
    fi
    ipv6_gateway=$(read_network_state /usr/local/bin/pve_ipv6_gateway validate_ipv6_value 2>/dev/null || true)
    ipv6_address=$(read_network_state /usr/local/bin/pve_check_ipv6 validate_ipv6_value 2>/dev/null || true)
    if [ -n "$ipv6_address" ] && [ -n "$ipv6_prefixlen" ]; then
        ipv6_address_without_last_segment="${ipv6_address%:*}:"
        reconfigure_ipv6_address
    fi
}

# 重新配置IPV6地址
reconfigure_ipv6_address() {
    if [[ $ipv6_address != *:: && $ipv6_address_without_last_segment != *:: ]]; then
        ipv6_address=$(sipcalc -i ${ipv6_address}/${ipv6_prefixlen} | grep "Subnet prefix (masked)" | cut -d ' ' -f 4 | cut -d '/' -f 1 | sed 's/:0:0:0:0:/::/' | sed 's/:0:0:0:/::/')
        ipv6_address="${ipv6_address%:*}:1"
        if [ "$ipv6_address" == "$ipv6_gateway" ]; then
            ipv6_address="${ipv6_address%:*}:2"
        fi
        ipv6_address_without_last_segment="${ipv6_address%:*}:"
        if ping -c 1 -6 -W 3 $ipv6_address >/dev/null 2>&1; then
            check_ipv6
            ipv6_address=$(read_network_state /usr/local/bin/pve_check_ipv6 validate_ipv6_value 2>/dev/null || true)
            ipv6_address_without_last_segment="${ipv6_address%:*}:"
        fi
    elif [[ $ipv6_address == *:: ]]; then
        ipv6_address="${ipv6_address}1"
        if [ "$ipv6_address" == "$ipv6_gateway" ]; then
            ipv6_address="${ipv6_address%:*}:2"
        fi
        ipv6_address_without_last_segment="${ipv6_address%:*}:"
        write_network_state_atomic /usr/local/bin/pve_check_ipv6 "$ipv6_address" validate_ipv6_value || return 1
    fi
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
    local candidate="${1:-}" host_state
    command -v python3 >/dev/null 2>&1 || return 1
    host_state="$(
        {
            ip -o -6 addr show 2>/dev/null || true
            ip -6 route show table all 2>/dev/null || true
        }
    )"
    python3 - "$candidate" "$host_state" <<'PY' >/dev/null 2>&1
import ipaddress
import sys

try:
    candidate = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
if candidate.prefixlen != 64 or not candidate.subnet_of(ipaddress.IPv6Network("fc00::/7")):
    raise SystemExit(1)

def vmbr1_owns(network, device):
    # The bridge's connected /64 and its local gateway /128 are expected after
    # installation.  They are not a conflict with the persisted NAT subnet.
    return device == "vmbr1" and network.subnet_of(candidate)

route_types = {"unreachable", "prohibit", "blackhole", "throw", "local", "broadcast", "anycast", "multicast"}
for line in sys.argv[2].splitlines():
    fields = line.split()
    if not fields:
        continue
    if "inet6" in fields:
        address_index = fields.index("inet6") + 1
        if address_index >= len(fields):
            continue
        device = fields[1].split("@", 1)[0] if len(fields) > 1 else ""
        token = fields[address_index]
    else:
        destination_index = 1 if fields[0] in route_types else 0
        if destination_index >= len(fields):
            continue
        token = fields[destination_index]
        if token == "default":
            continue
        device = ""
        if "dev" in fields:
            device_index = fields.index("dev") + 1
            if device_index < len(fields):
                device = fields[device_index].split("@", 1)[0]
    try:
        existing = ipaddress.IPv6Network(token, strict=False)
    except ValueError:
        continue
    if existing.prefixlen == 0:
        continue
    if candidate.overlaps(existing) and not vmbr1_owns(existing, device):
        raise SystemExit(1)
raise SystemExit(0)
PY
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

pre-up echo 2 > /proc/sys/net/ipv6/conf/vmbr0/accept_ra
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

pre-up echo 2 > /proc/sys/net/ipv6/conf/vmbr0/accept_ra
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
    local appended_file direct_config direct_bridge
    local -a direct_values
    chattr -i /etc/network/interfaces
    appended_file="/usr/local/bin/pve_appended_content.txt"
    if [ -s "$appended_file" ]; then
        tmp_script="/usr/local/bin/check_ipv6.sh"
        echo '#!/bin/bash' > "$tmp_script"
        echo "" >> "$tmp_script"
        counter=0
        grep -Po '(?<=address )[\da-fA-F:]+(?=/64)' "$appended_file" | while read -r ip; do
            delay=$((counter * 6))
            echo "sleep $delay; curl --interface $ip -6 -s https://ifconfig.co &" >> "$tmp_script"
            counter=$((counter + 1))
        done
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
    local direct_bridge="${1:-vmbr2}" uplink
    validate_pve_direct_ipv6_bridge_value "$direct_bridge" || return 1
    uplink="$(pve_ipv6_uplink_interface 2>/dev/null || true)"
    [ -n "$uplink" ] || uplink=vmbr0
    # Keep SLAAC router advertisements on the actual external uplink after
    # enabling forwarding, otherwise Linux can expire the host default route.
    update_sysctl "net.ipv6.conf.${uplink}.accept_ra=2"
    update_sysctl "net.ipv6.conf.all.forwarding=1"
    # NDP proxying is meaningful only on bridges that carry this topology.
    # Do not make unrelated current or future interfaces proxy NDP packets.
    update_sysctl "net.ipv6.conf.${uplink}.proxy_ndp=1"
    update_sysctl "net.ipv6.conf.vmbr1.proxy_ndp=1"
    update_sysctl "net.ipv6.conf.${direct_bridge}.proxy_ndp=1"
}

# 安装并配置防火墙
setup_firewall() {
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
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf
        nft list ruleset >> /etc/nftables.conf
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
    fi
    update_sysctl "net.ipv4.ip_forward=1"
    ${sysctl_path} -p
}

restart_network_services() {
    service networking restart
    systemctl restart networking.service
    sleep 3
    ifreload -ad
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
configure_vmbr1
configure_vmbr2
chattr +i /etc/network/interfaces
rm -rf /usr/local/bin/iface_auto.txt
setup_firewall
restart_network_services
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
