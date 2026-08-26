#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.08.26

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

set_locale() {
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
    if [[ -z "$utf8_locale" ]]; then
        echo "No UTF-8 locale found"
    else
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        echo "Locale set to $utf8_locale"
    fi
}

get_system_arch() {
    local sysarch="$(uname -m)"
    if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
        local sysarch="$(arch)"
    fi
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
    if [ -z "${system_arch}" ] || [ ! -v system_arch ]; then
        _red "This script can only run on machines under x86_64, arm64, or riscv64 architecture."
        return 1
    fi
    return 0
}

check_china() {
    _yellow "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            _yellow "根据ipapi.co提供的信息，当前IP可能在中国，使用中国镜像下载"
            CN=true
        fi
    fi
}

validate_ctid() {
    # 检查 CTID 是否为数字
    if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
        _red "Error: CTID must be a valid number."
        _red "错误：CTID 必须是有效的数字。"
        return 1
    fi
    # 检查 CTID 是否在范围 100 到 256 之间
    if [[ "$CTID" -lt 100 || "$CTID" -gt 256 ]]; then
        _red "Error: CTID must be in the range 100 ~ 256."
        _red "错误：CTID 需要在 100 到 256 以内。"
        return 1
    fi
    # 检查是否已有相同的 VM
    if qm list | awk '{print $1}' | grep -q "^${CTID}$"; then
        _red "Error: A VM with vmid ${CTID} already exists."
        _red "错误：vmid 为 ${CTID} 的虚拟机已存在。"
        return 1
    fi
    # 检查是否已有相同的 CT
    if pct list | awk '{print $1}' | grep -q "^${CTID}$"; then
        _red "Error: A CT with vmid ${CTID} already exists."
        _red "错误：vmid 为 ${CTID} 的容器已存在。"
        return 1
    fi
    _green "CTID is valid and available: $CTID"
    return 0
}

check_ipv6_setup() {
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
                if [ "$part_1_last" = "$CTID" ]; then
                    ipv6_address=""
                else
                    part_1_head=$(echo "$part_1" | awk -F':' 'BEGIN {OFS=":"} {last=""; for (i=1; i<NF; i++) {last=last $i ":"}; print last}')
                    ipv6_address="${part_1_head}${CTID}"
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

prepare_system_image() {
    if [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
        find_and_download_system_image_x86 || return 1
    elif [ "$system_arch" = "arm" ]; then
        find_and_download_system_image_arm || return 1
    elif [ "$system_arch" = "riscv64" ]; then
        find_and_download_system_image_riscv || return 1
    else
        echo "Unknown architecture: $system_arch"
        return 1
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

_fetch_list_with_retry() {
    local url="$1"
    local attempts=0
    local max_attempts=5
    local delay=1
    fetch_list_response=""
    while ((attempts < max_attempts)); do
        response=$(curl -slk -m 6 "${url}")
        if [[ $? -eq 0 && -n "$response" ]]; then
            fetch_list_response="$response"
            return 0
        fi

        sleep "$delay"
        ((attempts++))
        delay=$((delay * 2))
        [[ $delay -gt 16 ]] && delay=16
    done
    return 1
}

find_and_download_system_image_arm() {
    system_name=""
    system_names=()
    usable_system=false
    # 获取可用列表，带指数退避，结果赋值到 system_names
    if _fetch_list_with_retry "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxc_arm_images/main/all_images.txt"; then
        mapfile -t system_names <<<"$fetch_list_response"
    fi
    ubuntu_versions=("18.04" "20.04" "22.04" "23.04" "23.10" "24.04")
    ubuntu_names=("bionic" "focal" "jammy" "lunar" "mantic" "noble")
    debian_versions=("10" "11" "12" "13")
    debian_names=("buster" "bullseye" "bookworm" "trixie")
    version=""
    if [ "$en_system" = "ubuntu" ]; then
        for ((i = 0; i < ${#ubuntu_versions[@]}; i++)); do
            if [ "${ubuntu_versions[$i]}" = "$num_system" ]; then
                version="${ubuntu_names[$i]}"
                system_name="${en_system}_${ubuntu_versions[$i]}_${ubuntu_names[$i]}_arm64_cloud.tar.xz"
                break
            fi
        done
    elif [ "$en_system" = "debian" ]; then
        for ((i = 0; i < ${#debian_versions[@]}; i++)); do
            if [ "${debian_versions[$i]}" = "$num_system" ]; then
                version="${debian_names[$i]}"
                system_name="${en_system}_${debian_versions[$i]}_${debian_names[$i]}_arm64_cloud.tar.xz"
                break
            fi
        done
    elif [ -z "$num_system" ]; then
        matched_systems=()
        for sy in "${system_names[@]}"; do
            if [[ "$sy" == "${en_system}_"* ]]; then
                matched_systems+=("$sy")
            fi
        done
        if [ ${#matched_systems[@]} -gt 0 ]; then
            IFS=$'\n' sorted=($(sort <<<"${matched_systems[*]}"))
            unset IFS
            system_name="${sorted[-1]}"
        fi
    else
        version="$num_system"
        system_name="${en_system}_${version}"
    fi
    # 校验是否在列表中
    if [ ${#system_names[@]} -gt 0 ] && [ -n "$system_name" ]; then
        for sy in "${system_names[@]}"; do
            if [[ "$sy" == "${system_name}"* ]]; then
                usable_system=true
                system_name="$sy"
                break
            fi
        done
    elif [ ${#system_names[@]} -eq 0 ] && [ -n "$system_name" ]; then
        # 列表拉取失败但已从硬编码数据构建了镜像名，直接尝试下载
        usable_system=true
    fi
    if [ "$usable_system" = false ]; then
        _red "Invalid system version."
        return 1
    fi
    # 开始下载
    if [ -n "$system_name" ]; then
        target="/var/lib/vz/template/cache/${system_name}"
        if [ ! -f "$target" ]; then
            url="${cdn_success_url}https://github.com/oneclickvirt/lxc_arm_images/releases/download/${en_system}/${system_name}"
            if ! _download_with_retry "$url" "$target"; then
                _red "Failed to download ${system_name}"
                return 1
            fi
        else
            _blue "File already exists: ${target}"
        fi
        fixed_system=true
    fi
    return 0
}

find_and_download_system_image_riscv() {
    fixed_system=false
    system="${en_system}-${num_system}"
    system_name=""
    if [ -z "$num_system" ]; then
        system_name=$(pveam available --section system | awk '{print $2}' | grep "^${en_system}" | head -n1)
    else
        system_name=$(pveam available --section system | awk '{print $2}' | grep "^${system}" | head -n1)
    fi
    if [ -z "$system_name" ]; then
        _red "No matching riscv64 CT template was found through pveam for ${system}"
        _red "未通过 pveam 找到适用于 ${system} 的 riscv64 容器模板"
        _yellow "Please run pveam update and ensure the PXVIRT repository for riscv64 is available"
        _yellow "请先执行 pveam update，并确认 riscv64 的 PXVIRT 仓库已可用"
        return 1
    fi
    target="/var/lib/vz/template/cache/${system_name}"
    if [ ! -f "$target" ]; then
        pveam download local "$system_name" || return 1
    else
        _blue "File already exists: ${target}"
    fi
    fixed_system=true
    _blue "Use riscv64 template from pveam: ${system_name}"
    return 0
}

find_and_download_system_image_x86() {
    fixed_system=false
    system="${en_system}-${num_system}"
    system_name=""
    system_names=()
    # 优先从 lxc_amd64_images 列表获取，带指数退避
    if _fetch_list_with_retry "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxc_amd64_images/main/all_images.txt"; then
        mapfile -t system_names <<<"$fetch_list_response"
    fi
    for image_name in "${system_names[@]}"; do
        if { [ -z "$num_system" ] && [[ "$image_name" == "${en_system}"* ]]; } ||
            { [ -n "$num_system" ] && [[ "$image_name" == "${en_system}_${num_system}"* ]]; }; then
            fixed_system=true
            system_name="$image_name"
            break
        fi
    done
    if [ "$fixed_system" = true ] && [ -n "$system_name" ]; then
        target="/var/lib/vz/template/cache/${system_name}"
        url="${cdn_success_url}https://github.com/oneclickvirt/lxc_amd64_images/releases/download/${en_system}/${system_name}"
        if [ ! -f "$target" ]; then
            if ! _download_with_retry "$url" "$target"; then
                _red "Failed to download ${system_name}"
                rm -f "$target"
                fixed_system=false
            fi
        fi
        _blue "Use matching image: ${system_name}"
    fi
    # 如果未找到，再从 pve_lxc_images 列表获取，带指数退避
    if [ "$fixed_system" = false ]; then
        system_name=""
        system_names=()
        if _fetch_list_with_retry "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve_lxc_images/main/fixed_images.txt"; then
            mapfile -t system_names <<<"$fetch_list_response"
        fi
        pve_version=$(pveversion)
        allow_zst=true
        [[ $pve_version == pve-manager/5* ]] && allow_zst=false
        for sy in "${system_names[@]}"; do
            if { [ -z "$num_system" ] && [[ "$sy" == "${en_system}-"* ]]; } ||
                { [ -n "$num_system" ] && [[ "$sy" == "${system}"* ]]; }; then
                system_name="$sy"
                fixed_system=true
                target="/var/lib/vz/template/cache/${system_name}"
                url="${cdn_success_url}https://github.com/oneclickvirt/pve_lxc_images/releases/download/${en_system}/${system_name}"
                if [ ! -f "$target" ] && { $allow_zst || [[ "$system_name" != *.zst ]]; }; then
                    if ! _download_with_retry "$url" "$target"; then
                        _red "Failed to download ${system_name}"
                        rm -f "$target"
                        fixed_system=false
                    fi
                fi
                _blue "Use self-fixed image: ${system_name}"
                break
            fi
        done
    fi
    # 回退到 pveam
    if [ "$fixed_system" = false ]; then
        if [ -z "$num_system" ]; then
            system_name=$(pveam available --section system | grep "^${en_system}" | awk '{print $2}' | head -n1)
        else
            system_name=$(pveam available --section system | grep "^${system}" | awk '{print $2}' | head -n1)
        fi
        if [ -z "$system_name" ]; then
            # pveam 也没有时，尝试根据已知版本名映射直接构造 URL 下载
            local -A debian_name_map=([10]="buster" [11]="bullseye" [12]="bookworm" [13]="trixie" [14]="forky")
            local -A ubuntu_name_map=([18]="bionic" [20]="focal" [22]="jammy" [23]="lunar" [24]="noble" [25]="plucky")
            local ver_name=""
            if [[ "$en_system" == "debian" ]] && [[ -n "${debian_name_map[$num_system]+_}" ]]; then
                ver_name="${debian_name_map[$num_system]}"
                system_name="${en_system}_${num_system}_${ver_name}_amd64_cloud.tar.zst"
            elif [[ "$en_system" == "ubuntu" ]] && [[ -n "${ubuntu_name_map[${num_system%%.*}]+_}" ]]; then
                ver_name="${ubuntu_name_map[${num_system%%.*}]}"
                system_name="${en_system}_${num_system}_${ver_name}_amd64_cloud.tar.zst"
            fi
            if [ -n "$system_name" ]; then
                target="/var/lib/vz/template/cache/${system_name}"
                url="${cdn_success_url}https://github.com/oneclickvirt/lxc_amd64_images/releases/download/${en_system}/${system_name}"
                echo "$url"
                if _download_with_retry "$url" "$target"; then
                    _blue "Use version-mapped fallback image: ${system_name}"
                    fixed_system=true
                else
                    rm -f "$target"
                    _red "No such system"
                    return 1
                fi
            else
                _red "No such system"
                return 1
            fi
        else
            _green "Use ${system_name}"
            target="/var/lib/vz/template/cache/${system_name}"
            if [ ! -f "$target" ]; then
                pveam download local "$system_name"
            fi
            fixed_system=true
        fi
    fi
    return 0
}
