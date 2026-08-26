#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.08.26

# 设置 echo "kvm64" > /usr/local/bin/cpu_type 可方便虚拟机进行迁移

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }
load_nat_ipv4_config() {
    pve_nat_gateway="172.16.1.1"
    [ -s /usr/local/bin/pve_nat_gateway ] && pve_nat_gateway="$(cat /usr/local/bin/pve_nat_gateway)"
    if [[ ! "$pve_nat_gateway" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        _red "Invalid persisted PVE NAT gateway: ${pve_nat_gateway}"
        _red "持久化的 PVE NAT 网关无效：${pve_nat_gateway}"
        return 1
    fi
    pve_nat_prefix="${pve_nat_gateway%.*}"
    load_nat_ipv6_config || return 1
    pve_load_direct_ipv6_config || return 1
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
load_nat_ipv6_config() {
    local state_dir="${PVE_STATE_DIR:-/usr/local/bin}" state_file gateway_file candidate requested index
    local requested_explicit=false
    state_file="${state_dir%/}/pve_nat_ipv6_subnet"
    gateway_file="${state_dir%/}/pve_nat_ipv6_gateway"
    if [[ -n "${PVE_NAT_IPV6_SUBNET:-}" ]]; then
        requested="${PVE_NAT_IPV6_SUBNET}"
        requested_explicit=true
    else
        requested="$(cat "$state_file" 2>/dev/null || true)"
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
    [ -n "$candidate" ] && pve_nat_ipv6_candidate_is_safe "$candidate" || return 1
    pve_nat_ipv6_subnet="$candidate"
    pve_nat_ipv6_gateway="$(python3 - "$candidate" <<'PY'
import ipaddress
import sys
network = ipaddress.IPv6Network(sys.argv[1], strict=False)
print(ipaddress.IPv6Address(int(network.network_address) + 1))
PY
)"
    mkdir -p "$state_dir" || return 1
    printf '%s\n' "$pve_nat_ipv6_subnet" >"$state_file"
    printf '%s\n' "$pve_nat_ipv6_gateway" >"$gateway_file"
}
pve_nat_ipv6_for_id() {
    python3 - "${pve_nat_ipv6_subnet:-}" "$1" <<'PY'
import ipaddress
import sys
network = ipaddress.IPv6Network(sys.argv[1], strict=False)
value = int(sys.argv[2])
candidate = ipaddress.IPv6Address(int(network.network_address) + value)
if candidate not in network or candidate == network.network_address:
    raise SystemExit(1)
print(candidate)
PY
}

# Direct public IPv6 is intentionally opt-in for new installs. A host address
# or an RA-advertised /64 does not prove that the whole prefix is delegated to
# the host. Existing direct bridges are still discovered so working
# installations using NDP (including non-nibble prefixes such as /38) keep
# their current addressing scheme.
pve_ipv6_state_file() {
    printf '%s/%s\n' "${PVE_STATE_DIR:-/usr/local/bin}" "$1"
}

pve_read_single_line_state() {
    local path="$1" value
    [ -s "$path" ] || return 1
    [ "$(awk 'END { print NR }' "$path" 2>/dev/null)" = "1" ] || return 1
    IFS= read -r value <"$path" || return 1
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

pve_direct_ipv6_bridge() {
    local bridge="${PVE_IPV6_DIRECT_BRIDGE:-}" stored_bridge
    if [ -z "$bridge" ]; then
        stored_bridge="$(pve_read_single_line_state "$(pve_ipv6_state_file pve_direct_ipv6_bridge)" 2>/dev/null || true)"
        bridge="${stored_bridge:-vmbr2}"
    fi
    [[ "$bridge" =~ ^[[:alnum:]_.:-]+$ ]] || return 1
    printf '%s\n' "$bridge"
}

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
if (
    network.prefixlen > 120
    or not network.subnet_of(global_unicast)
    or mode not in {"ndp", "routed"}
):
    raise SystemExit(1)

if mode == "ndp":
    if not upstream_gateway.is_global or upstream_gateway not in network:
        raise SystemExit(1)
    bridge_gateway = upstream_gateway
else:
    # A routed prefix can have an upstream global or link-local next hop. That
    # next hop lives on the host uplink; guests must instead use an address on
    # their own direct bridge as their default gateway.
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

pve_direct_ipv6_bridge_cidr() {
    local value interfaces_file bridge
    bridge="$(pve_direct_ipv6_bridge)" || return 1
    value="$(ip -o -6 addr show dev "$bridge" scope global 2>/dev/null | awk '
        $0 ~ /inet6/ { for (i = 1; i <= NF; i++) if ($i == "inet6") { print $(i + 1); exit } }
    ' | while IFS= read -r candidate; do
        if python3 - "$candidate" <<'PY' >/dev/null 2>&1
import ipaddress
import sys
try:
    interface = ipaddress.IPv6Interface(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if interface.ip.is_global else 1)
PY
        then
            printf '%s\n' "$candidate"
            break
        fi
    done)"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
        return 0
    fi
    interfaces_file="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}"
    [ -r "$interfaces_file" ] || return 1
    awk -v bridge="$bridge" '
        $1 == "iface" && $2 == bridge && $3 == "inet6" { inside = 1; next }
        $1 == "iface" { inside = 0 }
        inside && $1 == "address" { print $2; exit }
    ' "$interfaces_file"
}

pve_direct_ipv6_bridge_present() {
    local bridge interfaces_file
    bridge="$(pve_direct_ipv6_bridge)" || return 1
    ip link show "$bridge" >/dev/null 2>&1 && return 0
    local interfaces_file="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}"
    [ -r "$interfaces_file" ] || return 1
    awk -v bridge="$bridge" '
        $1 == "auto" {
            for (i = 2; i <= NF; i++) if ($i == bridge) found = 1
        }
        $1 == "iface" && $2 == bridge { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$interfaces_file"
}

pve_direct_ipv6_transport() {
    local interfaces_file="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}"
    if [ -r "$interfaces_file" ] && grep -Eiq '(^|[[:space:]])(he-ipv6|sit[0-9]*|6in4)([[:space:]]|$)' "$interfaces_file"; then
        printf '%s\n' tunnel
    else
        printf '%s\n' bridge
    fi
}

pve_direct_ipv6_bridge_configured() {
    local bridge_cidr
    [ "${pve_direct_ipv6_available:-false}" = true ] || return 1
    bridge_cidr="$(pve_direct_ipv6_bridge_cidr)" || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$bridge_cidr" "$pve_direct_ipv6_prefix" "$pve_direct_ipv6_gateway" <<'PY' >/dev/null 2>&1
import ipaddress
import sys

try:
    bridge = ipaddress.IPv6Interface(sys.argv[1])
    network = ipaddress.IPv6Network(sys.argv[2], strict=False)
    gateway = ipaddress.IPv6Address(sys.argv[3])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if bridge.network == network and bridge.ip == gateway else 1)
PY
}

pve_load_direct_ipv6_config() {
    local state_prefix state_gateway state_mode state_transport state_upstream prefix upstream_gateway bridge_gateway mode bridge_cidr source normalized_output
    local -a normalized_values
    pve_direct_ipv6_available=false
    pve_direct_ipv6_prefix=""
    pve_direct_ipv6_gateway=""
    pve_direct_ipv6_prefixlen=""
    pve_direct_ipv6_mode=""
    pve_direct_ipv6_source=""
    pve_direct_ipv6_transport=""
    pve_direct_ipv6_upstream_gateway=""

    state_prefix="$(pve_ipv6_state_file pve_direct_ipv6_prefix)"
    state_gateway="$(pve_ipv6_state_file pve_direct_ipv6_gateway)"
    state_mode="$(pve_ipv6_state_file pve_direct_ipv6_mode)"
    state_transport="$(pve_ipv6_state_file pve_direct_ipv6_transport)"
    state_upstream="$(pve_ipv6_state_file pve_direct_ipv6_upstream_gateway)"
    if [ -n "${PVE_IPV6_ROUTED_PREFIX:-}" ] || [ -n "${PVE_IPV6_DIRECT_GATEWAY:-}" ] || [ -n "${PVE_IPV6_DIRECT_MODE:-}" ]; then
        prefix="${PVE_IPV6_ROUTED_PREFIX:-}"
        upstream_gateway="${PVE_IPV6_DIRECT_GATEWAY:-}"
        bridge_gateway="${PVE_IPV6_BRIDGE_GATEWAY:-}"
        mode="${PVE_IPV6_DIRECT_MODE:-ndp}"
        source="environment"
        if [ -z "$bridge_gateway" ]; then
            bridge_gateway="$(pve_direct_ipv6_bridge_cidr 2>/dev/null | cut -d/ -f1 || true)"
        fi
        if [ -z "$upstream_gateway" ]; then
            upstream_gateway="$bridge_gateway"
        fi
        if [ -z "$upstream_gateway" ]; then
            upstream_gateway="$(pve_read_single_line_state "$(pve_ipv6_state_file pve_check_ipv6)" 2>/dev/null || true)"
        fi
    elif prefix="$(pve_read_single_line_state "$state_prefix" 2>/dev/null)" && bridge_gateway="$(pve_read_single_line_state "$state_gateway" 2>/dev/null)"; then
        upstream_gateway="$(pve_read_single_line_state "$state_upstream" 2>/dev/null || printf '%s' "$bridge_gateway")"
        mode="$(pve_read_single_line_state "$state_mode" 2>/dev/null || printf '%s' ndp)"
        source="state"
    elif bridge_cidr="$(pve_direct_ipv6_bridge_cidr)" && [ -n "$bridge_cidr" ]; then
        prefix="$bridge_cidr"
        upstream_gateway="${bridge_cidr%/*}"
        bridge_gateway="$upstream_gateway"
        mode="ndp"
        source="legacy-direct-bridge"
    else
        return 0
    fi

    # A persisted prefix without a live direct bridge is not evidence that the whole
    # prefix is still routed to this host. Keep SLAAC and stale state on NAT66.
    if [ "$source" != environment ] && ! pve_direct_ipv6_bridge_present; then
        return 0
    fi

    if ! normalized_output="$(pve_direct_ipv6_normalize "$prefix" "$upstream_gateway" "$mode" "$bridge_gateway")"; then
        if [ "$source" = "environment" ]; then
            _red "Invalid PVE direct IPv6 configuration; set a delegated public prefix, gateway, and mode ndp or routed"
            _red "PVE 直连 IPv6 配置无效；请设置已委派的公网前缀、网关，以及 ndp 或 routed 模式"
            return 1
        fi
        _yellow "Ignoring invalid persisted or legacy direct-bridge IPv6 configuration"
        _yellow "忽略无效的持久化或旧直连网桥 IPv6 配置"
        return 0
    fi
    mapfile -t normalized_values <<<"$normalized_output"
    [ "${#normalized_values[@]}" -eq 4 ] || return 1
    pve_direct_ipv6_prefix="${normalized_values[0]}"
    pve_direct_ipv6_gateway="${normalized_values[1]}"
    pve_direct_ipv6_mode="${normalized_values[2]}"
    pve_direct_ipv6_upstream_gateway="${normalized_values[3]}"
    pve_direct_ipv6_prefixlen="${pve_direct_ipv6_prefix##*/}"
    pve_direct_ipv6_source="$source"
    pve_direct_ipv6_transport="$(pve_read_single_line_state "$state_transport" 2>/dev/null || true)"
    [ -n "$pve_direct_ipv6_transport" ] || pve_direct_ipv6_transport="$(pve_direct_ipv6_transport)"
    pve_direct_ipv6_available=true
    return 0
}

pve_direct_ipv6_ndp_required() {
    [ "${pve_direct_ipv6_mode:-}" = "ndp" ] || [ "${pve_direct_ipv6_transport:-}" = tunnel ]
}

pve_direct_ipv6_for_id() {
    local identifier="${1:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "${pve_direct_ipv6_prefix:-}" "${pve_direct_ipv6_gateway:-}" "$identifier" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
    gateway = ipaddress.IPv6Address(sys.argv[2])
    identifier = int(sys.argv[3], 10)
except ValueError:
    raise SystemExit(1)
if identifier < 100 or identifier > 256:
    raise SystemExit(1)

# Retain the historical address form when the host's /64 fits inside the
# delegated prefix (for example, host ...:10f8::1/38 -> guest ...:10f8::64).
# Build assignments for the complete PVE ID range so an address that collides
# with the bridge gateway, or ID 256 in a /120, cannot duplicate another ID.
def historical_candidate(vm_id):
    candidate = ipaddress.IPv6Address((int(gateway) & ~((1 << 64) - 1)) | vm_id)
    if candidate in network:
        return candidate
    if vm_id >= network.num_addresses:
        return None
    return ipaddress.IPv6Address(int(network.network_address) + vm_id)

assignments = {}
assigned_addresses = set()
fallback_ids = []
for vm_id in range(100, 257):
    candidate = historical_candidate(vm_id)
    if (
        candidate is None
        or candidate == network.network_address
        or candidate == gateway
        or candidate in assigned_addresses
    ):
        fallback_ids.append(vm_id)
        continue
    assignments[vm_id] = candidate
    assigned_addresses.add(candidate)

for vm_id in fallback_ids:
    for offset in range(1, network.num_addresses):
        candidate = ipaddress.IPv6Address(int(network.network_address) + offset)
        if candidate != gateway and candidate not in assigned_addresses:
            assignments[vm_id] = candidate
            assigned_addresses.add(candidate)
            break
    else:
        raise SystemExit(1)

print(assignments[identifier].compressed)
PY
}

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
images_output=""

setup_locale() {
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
    if [[ -z "$utf8_locale" ]]; then
        _yellow "No UTF-8 locale found"
    else
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        _green "Locale set to $utf8_locale"
    fi
}

validate_vm_num() {
    # 检测 vm_num 是否为数字
    if ! [[ "$vm_num" =~ ^[0-9]+$ ]]; then
        _red "Error: vm_num must be a valid number."
        _red "错误：vm_num 必须是有效的数字。"
        return 1
    fi
    # 检测 vm_num 是否在范围 100 到 256 之间
    if [[ "$vm_num" -lt 100 || "$vm_num" -gt 256 ]]; then
        _red "Error: vm_num must be in the range 100 ~ 256."
        _red "错误：vm_num 需要在 100 到 256 以内。"
        return 1
    fi
    # 检查是否已有相同的 VM
    if qm list | awk '{print $1}' | grep -q "^${vm_num}$"; then
        _red "Error: A VM with vmid ${vm_num} already exists."
        _red "错误：vmid 为 ${vm_num} 的虚拟机已存在。"
        return 1
    fi
    # 检查是否已有相同的 CT
    if pct list | awk '{print $1}' | grep -q "^${vm_num}$"; then
        _red "Error: A CT with vmid ${vm_num} already exists."
        _red "错误：vmid 为 ${vm_num} 的容器已存在。"
        return 1
    fi
    _green "vm_num is valid and available: $vm_num"
    return 0
}

get_available_vmbr1_ipv6() {
    local appended_file="/usr/local/bin/pve_appended_content.txt"
    local used_ips_file="/usr/local/bin/pve_used_vmbr1_ips.txt"
    if [ ! -f "$used_ips_file" ]; then
        touch "$used_ips_file"
    fi
    local available_ips=()
    if [ -f "$appended_file" ]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^#[[:space:]]*control-alias ]]; then
                read -r next_line
                if [[ "$next_line" =~ ^iface[[:space:]]+.*[[:space:]]+inet6[[:space:]]+static ]]; then
                    read -r addr_line
                    if [[ "$addr_line" =~ ^[[:space:]]*address[[:space:]]+([^/]+) ]]; then
                        available_ips+=("${BASH_REMATCH[1]}")
                    fi
                fi
            fi
        done < "$appended_file"
    fi
    for ip in "${available_ips[@]}"; do
        if ! grep -q "^$ip$" "$used_ips_file"; then
            echo "$ip" >> "$used_ips_file"
            echo "$ip"
            return 0
        fi
    done
    echo ""
    return 1
}

########## Firewall abstraction: nftables preferred, iptables fallback ##########

_use_nft() {
    command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1
}

_nft_init() {
    # Try to install nftables if not present (one-time attempt)
    if ! command -v nft >/dev/null 2>&1 && [ ! -f "/tmp/.nft_install_attempted" ]; then
        touch /tmp/.nft_install_attempted
        apt-get update -qq 2>/dev/null && apt-get install -y nftables 2>/dev/null || true
    fi
    
    nft add table ip nat 2>/dev/null || true
    nft 'add chain ip nat prerouting { type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
    nft 'add chain ip nat postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
    nft add table ip6 nat 2>/dev/null || true
    nft 'add chain ip6 nat prerouting { type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
    nft 'add chain ip6 nat postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
    nft add table ip6 raw 2>/dev/null || true
    nft 'add chain ip6 raw prerouting { type filter hook prerouting priority raw; policy accept; }' 2>/dev/null || true
}

_ip6tables_ensure_modules() {
    modprobe ip6table_nat 2>/dev/null || true
    modprobe ip6table_raw 2>/dev/null || true
    modprobe nf_nat 2>/dev/null || true
}

_fw_save() {
    if _use_nft; then
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf
        nft list ruleset >> /etc/nftables.conf
        systemctl enable nftables 2>/dev/null || true
    else
        mkdir -p /etc/iptables
        iptables-save | awk '{if($1=="COMMIT"){delete x}}$1=="-A"?!x[$0]++:1' | iptables-restore
        iptables-save > /etc/iptables/rules.v4
        if command -v ip6tables-save >/dev/null 2>&1; then
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        fi
        service netfilter-persistent restart 2>/dev/null || true
    fi
}

_fw_add_dnat() {
    local iface="$1" proto="$2" dport="$3" dest="$4"
    if _use_nft; then
        _nft_init
        nft add rule ip nat prerouting iifname "$iface" "$proto" dport "$dport" dnat to "$dest"
    else
        iptables -t nat -A PREROUTING -i "$iface" -p "$proto" --dport "$dport" -j DNAT --to-destination "$dest"
    fi
}

_fw_add_dnat_range() {
    local iface="$1" proto="$2" dport_range="$3" dest="$4"
    if _use_nft; then
        _nft_init
        nft add rule ip nat prerouting iifname "$iface" "$proto" dport "$dport_range" dnat to "$dest"
    else
        local dport_iptables="${dport_range/-/:}"
        iptables -t nat -A PREROUTING -i "$iface" -p "$proto" -m "$proto" --dport "$dport_iptables" -j DNAT --to-destination "$dest"
    fi
}

_fw_add_full_dnat() {
    local ext_ip="$1" proto="$2" int_ip="$3"
    if _use_nft; then
        _nft_init
        nft add rule ip nat prerouting ip daddr "$ext_ip" meta l4proto "$proto" dnat to "$int_ip"
    else
        iptables -t nat -A PREROUTING -d "$ext_ip" -p "$proto" -j DNAT --to-destination "$int_ip"
    fi
}

_fw_add_snat() {
    local src_ip="$1" oif="$2" snat_ip="$3"
    if _use_nft; then
        _nft_init
        nft add rule ip nat postrouting ip saddr "$src_ip" oifname "$oif" snat to "$snat_ip"
    else
        iptables -t nat -A POSTROUTING -s "$src_ip" -o "$oif" -j SNAT --to-source "$snat_ip"
    fi
}

_fw6_add_dnat() {
    local dest_ext="$1" dest_int="$2"
    if _use_nft; then
        _nft_init
        nft add rule ip6 nat prerouting ip6 daddr "$dest_ext" dnat to "$dest_int"
    else
        _ip6tables_ensure_modules
        ip6tables -t nat -A PREROUTING -d "$dest_ext" -j DNAT --to-destination "$dest_int"
    fi
}

_fw6_add_snat() {
    local src_int="$1" src_ext="$2"
    if _use_nft; then
        _nft_init
        nft add rule ip6 nat postrouting ip6 saddr "$src_int" snat to "$src_ext"
    else
        _ip6tables_ensure_modules
        ip6tables -t nat -A POSTROUTING -s "$src_int" -j SNAT --to-source "$src_ext"
    fi
}

_fw6_drop_icmpv6_ping() {
    local dest_ext="$1"
    local local_prefix="${2:-}"
    if _use_nft; then
        _nft_init
        if ! nft list chain ip6 raw prerouting 2>/dev/null | grep -q "$dest_ext"; then
            if [ -n "$local_prefix" ]; then
                nft add rule ip6 raw prerouting ip6 daddr "$dest_ext" ip6 saddr "$local_prefix" icmpv6 type echo-request accept
                nft add rule ip6 raw prerouting ip6 daddr "$dest_ext" ip6 saddr fe80::/10 icmpv6 type echo-request accept
            fi
            nft add rule ip6 raw prerouting ip6 daddr "$dest_ext" icmpv6 type echo-request drop
        fi
    else
        _ip6tables_ensure_modules
        if [ -n "$local_prefix" ]; then
            if ! ip6tables -t raw -C PREROUTING -d "$dest_ext" -s "$local_prefix" -p icmpv6 --icmpv6-type echo-request -j ACCEPT 2>/dev/null; then
                ip6tables -t raw -A PREROUTING -d "$dest_ext" -s "$local_prefix" -p icmpv6 --icmpv6-type echo-request -j ACCEPT
            fi
            if ! ip6tables -t raw -C PREROUTING -d "$dest_ext" -s fe80::/10 -p icmpv6 --icmpv6-type echo-request -j ACCEPT 2>/dev/null; then
                ip6tables -t raw -A PREROUTING -d "$dest_ext" -s fe80::/10 -p icmpv6 --icmpv6-type echo-request -j ACCEPT
            fi
        fi
        if ! ip6tables -t raw -C PREROUTING -d "$dest_ext" -p icmpv6 --icmpv6-type echo-request -j DROP 2>/dev/null; then
            ip6tables -t raw -A PREROUTING -d "$dest_ext" -p icmpv6 --icmpv6-type echo-request -j DROP
        fi
    fi
}

########## End of firewall abstraction ##########

setup_nat_mapping() {
    local ct_internal_ipv6="$1"
    local host_external_ipv6="$2"
    if _use_nft; then
        if ! nft list chain ip6 nat prerouting 2>/dev/null | grep -q "$host_external_ipv6"; then
            _fw6_add_dnat "$host_external_ipv6" "$ct_internal_ipv6"
            _fw6_add_snat "$ct_internal_ipv6" "$host_external_ipv6"
        fi
        _fw_save
    else
        local rules_file="/usr/local/bin/ipv6_nat_rules.sh"
        local service_file="/etc/systemd/system/ipv6nat.service"
        if [ ! -f "$rules_file" ]; then
            printf '#!/bin/bash\n# Auto-generated NAT rule script\nmodprobe ip6table_nat 2>/dev/null || true\nmodprobe ip6table_raw 2>/dev/null || true\nmodprobe nf_nat 2>/dev/null || true\n' > "$rules_file"
            chmod +x "$rules_file"
        fi
        if ! grep -q "$host_external_ipv6" "$rules_file"; then
            ip6tables -t nat -A PREROUTING -d "$host_external_ipv6" -j DNAT --to-destination "$ct_internal_ipv6"
            ip6tables -t nat -A POSTROUTING -s "$ct_internal_ipv6" -j SNAT --to-source "$host_external_ipv6"
            echo "ip6tables -t nat -A PREROUTING -d $host_external_ipv6 -j DNAT --to-destination $ct_internal_ipv6" >> "$rules_file"
            echo "ip6tables -t nat -A POSTROUTING -s $ct_internal_ipv6 -j SNAT --to-source $host_external_ipv6" >> "$rules_file"
        fi
        if [ ! -f "$service_file" ]; then
            cat > "$service_file" << 'NATEOF'
[Unit]
Description=Apply IPv6 NAT rules at boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipv6_nat_rules.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
NATEOF
            systemctl daemon-reexec
            systemctl daemon-reload
            systemctl enable ipv6nat.service
        else
            systemctl daemon-reload
            systemctl restart ipv6nat.service
        fi
        _fw_save
    fi
}

get_system_arch() {
    local sysarch="$(uname -m)"
    if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
        local sysarch="$(arch)"
    fi
    # 根据架构信息设置系统位数并下载文件,其余 * 包括了 x86_64
    case "${sysarch}" in
    "i386" | "i686" | "x86")
        system_arch="x86"
        ;;
    "armv7l" | "armv8" | "armv8l" | "aarch64")
        system_arch="arm"
        ;;
    "x86_64" | "amd64")
        system_arch="x86_64"
        ;;
    "riscv64")
        system_arch="riscv64"
        ;;
    *)
        system_arch=""
        ;;
    esac
    if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
        _red "This script can only run on machines under x86_64, arm64, or riscv64 architecture."
        return 1
    fi
    return 0
}

check_kvm_support() {
    if [ -e /dev/kvm ]; then
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            _green "KVM硬件加速可用，将使用硬件加速。"
            _green "KVM hardware acceleration is available. Using hardware acceleration."
            if [ -s /usr/local/bin/cpu_type ]; then
                cpu_type=$(cat /usr/local/bin/cpu_type) # 设置为kvm64可方便迁移
                _green "检测到自定义 CPU 类型配置：$cpu_type"
            else
                cpu_type="host"
            fi
            if [[ "$cpu_type" == "qemu64" || "$cpu_type" == "qemu32" ]]; then
                kvm_flag="--kvm 0"
            else
                kvm_flag="--kvm 1"
            fi
            return 0
        fi
    fi
    if grep -E 'vmx|svm' /proc/cpuinfo >/dev/null; then
        _yellow "CPU支持虚拟化，但/dev/kvm不可用，请检查BIOS设置或内核模块。"
        _yellow "CPU supports virtualization, but /dev/kvm is not available. Please check BIOS settings or kernel modules."
    else
        _yellow "CPU不支持硬件虚拟化。"
        _yellow "CPU does not support hardware virtualization."
    fi
    _yellow "将使用QEMU软件模拟(TCG)模式，性能会受到影响。"
    _yellow "Falling back to QEMU software emulation (TCG). Performance will be affected."
    case "$system_arch" in
    "arm")
        cpu_type="max"
        ;;
    "x86")
        cpu_type="qemu32"
        ;;
    "x86_64")
        cpu_type="qemu64"
        ;;
    *)
        cpu_type="max"
        ;;
    esac
    kvm_flag="--kvm 0"
    return 1
}

prepare_system_image() {
    if [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
        prepare_x86_image || return 1
    elif [ "$system_arch" = "arm" ]; then
        prepare_arm_image || return 1
    elif [ "$system_arch" = "riscv64" ]; then
        if [[ "${PVE_RISCV_VM_EXPERIMENTAL^^}" != "TRUE" ]]; then
            _red "Automatic VM image preparation is experimental on riscv64 and disabled by default"
            _red "riscv64 的自动虚拟机镜像准备为实验功能，默认关闭"
            _yellow "Set PVE_RISCV_VM_EXPERIMENTAL=true to enable this path"
            _yellow "如需启用该流程，请设置 PVE_RISCV_VM_EXPERIMENTAL=true"
            return 1
        fi
        prepare_riscv_image || return 1
    else
        echo "Unknown architecture: $system_arch"
        return 1
    fi
    return 0
}

get_new_images() {
    local attempts=0
    local max_attempts=5
    local delay=1
    while ((attempts < max_attempts)); do
        images_output=$(curl -s https://api.github.com/repos/oneclickvirt/pve_kvm_images/releases/tags/images 2>/dev/null |
            jq -r '.assets[].name' 2>/dev/null | sed -n '/qcow2$/s/.qcow2$//p')
        if [[ -n "$images_output" ]] && [[ "$images_output" != *"error"* ]] && [[ "$images_output" != *"failed"* ]]; then
            return 0
        fi
        sleep "$delay"
        ((attempts++))
        delay=$((delay * 2))
        [[ $delay -gt 16 ]] && delay=16
    done
    return 1
}

get_system_tag_images() {
    local sys_tag="$1"
    local attempts=0
    local max_attempts=3
    local delay=1
    system_tag_output=""
    while ((attempts < max_attempts)); do
        system_tag_output=$(curl -s "https://api.github.com/repos/oneclickvirt/pve_kvm_images/releases/tags/${sys_tag}" 2>/dev/null |
            jq -r '.assets[].name' 2>/dev/null | sed -n '/qcow2$/s/.qcow2$//p')
        if [[ -n "$system_tag_output" ]] && [[ "$system_tag_output" != *"error"* ]] && [[ "$system_tag_output" != *"message"* ]]; then
            return 0
        fi
        sleep "$delay"
        ((attempts++))
        delay=$((delay * 2))
        [[ $delay -gt 8 ]] && delay=8
    done
    system_tag_output=""
    return 1
}

prepare_x86_image() {
    file_path=""
    old_images=("debian10" "debian11" "debian12" "ubuntu18" "ubuntu20" "ubuntu22" "centos7" "archlinux" "almalinux8" "fedora33" "fedora34" "opensuse-leap-15" "alpinelinux_edge" "alpinelinux_stable" "rockylinux8" "centos8-stream")
    new_images=()
    if get_new_images; then
        mapfile -t new_images <<< "$images_output"
    fi
    # 提取系统族名（去掉末尾数字及连字符），用于查询按系统分类的 release tag
    sys_family=$(echo "$system" | sed 's/[0-9]*$//' | sed 's/-$//')
    sys_tag_images=()
    if get_system_tag_images "$sys_family"; then
        mapfile -t sys_tag_images <<< "$system_tag_output"
    fi
    if [[ ${#new_images[@]} -gt 0 ]] || [[ ${#sys_tag_images[@]} -gt 0 ]]; then
        combined=($(echo "${old_images[@]}" "${new_images[@]}" "${sys_tag_images[@]}" | tr ' ' '\n' | sort -u))
        systems=("${combined[@]}")
    else
        systems=("${old_images[@]}")
    fi
    for sys in "${systems[@]}"; do
        if [[ "$system" == "$sys" ]]; then
            file_path="/root/qcow/${system}.qcow2"
            break
        fi
    done
    if [[ -z "$file_path" ]]; then
        # API 查询失败时，仍基于系统族名推断，允许 download_x86_image 尝试下载
        if [[ -n "$sys_family" ]]; then
            file_path="/root/qcow/${system}.qcow2"
        else
            _red "Unable to install corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
            _red "无法安装对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
            return 1
        fi
    fi
    if [ ! -f "$file_path" ]; then
        download_x86_image
    fi
    return 0
}

_download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=5
    local attempt=1
    local wait_time=1
    while ((attempt <= max_attempts)); do
        curl -Lk --connect-timeout 10 --retry 0 -o "$output" "$url"
        if [ $? -eq 0 ]; then
            return 0
        else
            _yellow "Download attempt $attempt failed. Retrying in $wait_time seconds..."
            sleep $wait_time
            wait_time=$((wait_time * 2))
            ((attempt++))
        fi
    done
    return 1
}

download_x86_image() {
    ver=""
    selected_image=""
    selected_tag_image=""
    # 尝试使用新镜像
    if [[ ${#new_images[@]} -gt 0 ]]; then
        matched_images=()
        for image in "${new_images[@]}"; do
            if [[ "$image" == $system* ]]; then
                matched_images+=("$image")
            fi
        done
        if [[ ${#matched_images[@]} -gt 0 ]]; then
            # 优先选择带 cloud 的，并按版本号排序
            sorted_images=$(printf "%s\n" "${matched_images[@]}" | sort -r)
            for img in $sorted_images; do
                if [[ "$img" == *cloud* ]]; then
                    selected_image="$img"
                    selected_image=${selected_image%.qcow2}
                    break
                fi
            done
            # 如果没有带 cloud 的，就取第一个版本最高的
            if [[ -z "$selected_image" ]]; then
                selected_image=$(echo "$sorted_images" | head -n1)
                selected_image=${selected_image%.qcow2}
            fi
            if [[ -n "$selected_image" ]]; then
                ver="auto_build"
                url="${cdn_success_url}https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/${selected_image}.qcow2"
                echo "$url"
                if ! _download_with_retry "$url" "$file_path"; then
                    _red "Failed to download $file_path"
                    ver=""
                    rm -rf "$file_path"
                else
                    _blue "Use auto-fixed image: ${selected_image}"
                    return 0
                fi
            fi
        fi
    fi
    # 尝试使用 pve_kvm_images 中按系统族分类的 release tag 镜像
    if [[ -z "$ver" ]] && [[ ${#sys_tag_images[@]} -gt 0 ]]; then
        matched_tag_images=()
        for image in "${sys_tag_images[@]}"; do
            if [[ "$image" == $system* ]]; then
                matched_tag_images+=("$image")
            fi
        done
        if [[ ${#matched_tag_images[@]} -gt 0 ]]; then
            sorted_tag_images=$(printf "%s\n" "${matched_tag_images[@]}" | sort -r)
            selected_tag_image=""
            for img in $sorted_tag_images; do
                if [[ "$img" == *cloud* ]]; then
                    selected_tag_image="$img"
                    break
                fi
            done
            if [[ -z "$selected_tag_image" ]]; then
                selected_tag_image=$(echo "$sorted_tag_images" | head -n1)
            fi
            if [[ -n "$selected_tag_image" ]]; then
                url="${cdn_success_url}https://github.com/oneclickvirt/pve_kvm_images/releases/download/${sys_family}/${selected_tag_image}.qcow2"
                echo "$url"
                if ! _download_with_retry "$url" "$file_path"; then
                    _red "Failed to download $file_path from system tag release"
                    rm -rf "$file_path"
                else
                    ver="system_tag"
                    _blue "Use system-tag image: ${selected_tag_image}"
                    return 0
                fi
            fi
        fi
    fi
    # API 查询列表失败时，仍直接按系统族 tag 构造 URL 尝试下载
    if [[ -z "$ver" ]] && [[ -n "$sys_family" ]] && [[ ${#sys_tag_images[@]} -eq 0 ]]; then
        url="${cdn_success_url}https://github.com/oneclickvirt/pve_kvm_images/releases/download/${sys_family}/${system}.qcow2"
        echo "$url"
        if _download_with_retry "$url" "$file_path"; then
            ver="system_tag_fallback"
            _blue "Use system-tag fallback image: ${system}"
            return 0
        else
            rm -rf "$file_path"
        fi
    fi
    # 如果新镜像不可用，使用旧镜像
    if [[ -z "$ver" ]]; then
        v20=("fedora34" "almalinux8" "debian11" "debian12" "ubuntu18" "ubuntu20" "ubuntu22" "centos7" "alpinelinux_edge" "alpinelinux_stable" "rockylinux8")
        v11=("ubuntu18" "ubuntu20" "ubuntu22" "debian10" "debian11")
        v10=("almalinux8" "archlinux" "fedora33" "opensuse-leap-15" "ubuntu18" "ubuntu20" "ubuntu22" "debian10" "debian11")
        ver_list=(v20 v11 v10)
        ver_name_list=("v2.0" "v1.1" "v1.0")
        for ver in "${ver_list[@]}"; do
            array_name="${ver}[@]"
            array=("${!array_name}")
            if [[ " ${array[*]} " == *" $system "* ]]; then
                for index in "${!ver_list[@]}"; do
                    if [[ "${ver_list[$index]}" == "$ver" ]]; then
                        ver="${ver_name_list[$index]}"
                        break
                    fi
                done
                break
            fi
        done
        if [[ "$system" == "centos8-stream" ]]; then
            url="https://api.ilolicon.com/centos8-stream.qcow2"
            echo "$url"
            if ! _download_with_retry "$url" "$file_path"; then
                _red "Unable to download corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                _red "无法下载对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                rm -rf "$file_path"
                return 1
            else
                _blue "Use manual-fixed image: ${system}"
                return 0
            fi
        else
            if [[ -n "$ver" ]]; then
                url="${cdn_success_url}https://github.com/oneclickvirt/kvm_images/releases/download/${ver}/${system}.qcow2"
                echo "$url"
                if ! _download_with_retry "$url" "$file_path"; then
                    _red "Unable to download corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                    _red "无法下载对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                    rm -rf "$file_path"
                    return 1
                else
                    _blue "Use manual-fixed image: ${system}"
                    return 0
                fi
            else
                _red "Unable to install corresponding system, please check https://github.com/oneclickvirt/kvm_images/ for supported system images "
                _red "无法安装对应系统，请查看 https://github.com/oneclickvirt/kvm_images/ 支持的系统镜像 "
                return 1
            fi
        fi
    fi
}

prepare_arm_image() {
    ext="img"
    url=""
    declare -A ubuntu_map=(
        [ubuntu14]=trusty [ubuntu16]=xenial [ubuntu18]=bionic
        [ubuntu20]=focal [ubuntu22]=jammy
    )
    declare -A debian_map=(
        [10]=buster [11]=bullseye [12]=bookworm [13]=trixie
    )
    if [[ "$system" == "debian" ]]; then
        local latest=$(printf "%s\n" "${!debian_map[@]}" | sort -nr | head -n1)
        system="debian${latest}"
    fi
    if [[ -n "${ubuntu_map[$system]}" ]]; then
        ext="img"
        local codename=${ubuntu_map[$system]}
        url="http://cloud-images.ubuntu.com/${codename}/current/${codename}-server-cloudimg-arm64.img"
    elif [[ "$system" =~ debian([0-9]+) ]]; then
        ext="qcow2"
        local ver=${BASH_REMATCH[1]}
        local codename=${debian_map[$ver]}
        url="https://cloud.debian.org/images/cloud/${codename}/latest/debian-${ver}-generic-arm64.qcow2"
    else
        echo -e "错误: 不支持的系统版本 ${system}\nError: Unsupported system version: ${system}" >&2
        echo -e "请查看 http://cloud-images.ubuntu.com 和 https://cloud.debian.org/images/cloud 支持的系统镜像\nSee supported images at http://cloud-images.ubuntu.com and https://cloud.debian.org/images/cloud."
        return 1
    fi
    local file_path="/root/qcow/${system}.${ext}"
    if [[ ! -f "$file_path" ]]; then
        echo -e "开始下载镜像: ${url}\nDownloading image: ${url}"
        curl -L -o "$file_path" "$url"
        if [[ $? -ne 0 ]]; then
            echo -e "下载失败: ${url}\nDownload failed: ${url}" >&2
            return 1
        fi
    else
        echo -e "镜像已存在: ${file_path}\nImage already exists: ${file_path}"
    fi
    return 0
}

prepare_riscv_image() {
    ext="qcow2"
    local url=""
    declare -A debian_map=(
        [12]=bookworm [13]=trixie
    )
    if [[ "$system" == "debian" ]]; then
        system="debian13"
    fi
    if [[ "$system" =~ debian([0-9]+) ]]; then
        local ver=${BASH_REMATCH[1]}
        if [[ -z "${debian_map[$ver]}" ]]; then
            echo -e "错误: riscv64 实验虚拟机模式仅支持 debian12/debian13\nError: riscv64 experimental VM mode only supports debian12/debian13" >&2
            return 1
        fi
        local codename=${debian_map[$ver]}
        url="https://cloud.debian.org/images/cloud/${codename}/latest/debian-${ver}-generic-riscv64.qcow2"
    else
        echo -e "错误: riscv64 实验虚拟机模式仅支持 Debian 云镜像\nError: riscv64 experimental VM mode only supports Debian cloud images" >&2
        return 1
    fi
    local file_path="/root/qcow/${system}.${ext}"
    if [[ ! -f "$file_path" ]]; then
        echo -e "开始下载 riscv64 镜像: ${url}\nDownloading riscv64 image: ${url}"
        curl -L -o "$file_path" "$url"
        if [[ $? -ne 0 ]]; then
            echo -e "下载失败: ${url}\nDownload failed: ${url}" >&2
            return 1
        fi
    else
        echo -e "镜像已存在: ${file_path}\nImage already exists: ${file_path}"
    fi
    return 0
}

check_ipv6_config() {
    independent_ipv6_status="N"
    if [ "$independent_ipv6" == "y" ]; then
        appended_file="/usr/local/bin/pve_appended_content.txt"
        if [ -s "$appended_file" ]; then
            _green "Additional IPv6 addresses exist for mapping by NAT, and the host can open services with separate IPV6 addresses."
            _green "存在额外的IPv6地址可供NAT进行映射，宿主机可开设带独立IPV6地址的服务。"
        elif [ "${pve_direct_ipv6_available:-false}" = true ]; then
            if pve_direct_ipv6_ndp_required; then
                service_status=$(systemctl is-active ndpresponder.service 2>/dev/null || true)
                if [ "$service_status" != "active" ]; then
                    _red "ndpresponder is required for this NDP IPv6 prefix but is not active"
                    _red "当前 IPv6 前缀需要 ndpresponder，但服务未运行"
                    return 1
                fi
            fi
            _green "Independent IPv6 direct-assignment mode is available (${pve_direct_ipv6_mode})."
            _green "独立 IPv6 直连分配模式可用（${pve_direct_ipv6_mode}）。"
        else
            _yellow "No delegated public IPv6 prefix is available; falling back to IPv6 NAT66."
            _yellow "未检测到已委派的公网 IPv6 前缀，将回退到 IPv6 NAT66。"
        fi
        if [ -f /usr/local/bin/pve_check_ipv6 ]; then
            host_ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
            ipv6_address_without_last_segment="${host_ipv6_address%:*}:"
        fi
        if [ -f /usr/local/bin/pve_ipv6_prefixlen ]; then
            ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
        fi
        if [ -f /usr/local/bin/pve_ipv6_gateway ]; then
            ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
        fi
    else
        if [ -f /usr/local/bin/pve_check_ipv6 ]; then
            ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
            IFS="/" read -ra parts <<<"$ipv6_address"
            part_1="${parts[0]}"
            part_2="${parts[1]}"
            IFS=":" read -ra part_1_parts <<<"$part_1"
            if [ ! -z "${part_1_parts[*]}" ]; then
                part_1_last="${part_1_parts[-1]}"
                if [ "$part_1_last" = "$vm_num" ]; then
                    ipv6_address=""
                else
                    part_1_head=$(echo "$part_1" | awk -F':' 'BEGIN {OFS=":"} {last=""; for (i=1; i<NF; i++) {last=last $i ":"}; print last}')
                    ipv6_address="${part_1_head}${vm_num}"
                fi
            fi
        fi
        if [ -f /usr/local/bin/pve_ipv6_prefixlen ]; then
            ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
        fi
        if [ -f /usr/local/bin/pve_ipv6_gateway ]; then
            ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
        fi
    fi
    return 0
}

is_ipv4() {
    local ip=$1
    local regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    if [[ $ip =~ $regex ]]; then
        return 0
    else
        return 1
    fi
}
