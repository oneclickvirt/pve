#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
network_script="${repo_root}/scripts/build_nat_network.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

extract_function() {
    local name="$1"
    sed -n "/^${name}() {/,/^}/p" "$network_script"
}

extract_function_from() {
    local script="$1" name="$2"
    sed -n "/^${name}() {/,/^}/p" "$script"
}

eval "$(extract_function is_single_network_value)"
eval "$(extract_function validate_prefixlen_value)"
eval "$(extract_function validate_ipv6_prefixlen_value)"
eval "$(extract_function validate_interface_value)"
eval "$(extract_function validate_ipv4_value)"
eval "$(extract_function validate_ipv4_network24_value)"
eval "$(extract_function validate_ipv6_value)"
eval "$(extract_function validate_ipv6_network_value)"
eval "$(extract_function validate_pve_direct_ipv6_bridge_value)"
eval "$(extract_function validate_pve_direct_ipv6_mode_value)"
eval "$(extract_function validate_pve_direct_ipv6_transport_value)"
eval "$(extract_function pve_direct_ipv6_normalize)"
eval "$(extract_function pve_direct_ipv6_env_config)"
eval "$(extract_function pve_direct_ipv6_state_file)"
eval "$(extract_function write_network_state_atomic)"
eval "$(extract_function read_network_state)"
eval "$(extract_function is_public_ipv6)"
eval "$(extract_function is_private_ipv6)"
eval "$(extract_function check_ipv6)"
eval "$(extract_function select_nat_ipv4_subnet)"
eval "$(extract_function pve_nat_ipv6_candidate_is_safe)"
eval "$(extract_function select_nat_ipv6_subnet)"
eval "$(extract_function pve_save_direct_ipv6_config)"
eval "$(extract_function pve_vmbr0_owns_interface)"
eval "$(extract_function pve_ipv6_uplink_interface)"
eval "$(extract_function pve_direct_ndp_interface)"
eval "$(extract_function configure_ipv6_forwarding)"

_green() { :; }
_red() { :; }

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# Avoid touching the test runner network while exercising the real selector.
ipcalc() {
    [ "${1:-}" = "-c" ] && validate_ipv4_network24_value "${2:-}"
}
nat_ipv6_addresses=""
nat_ipv6_routes=""
pve_default_ipv6_interface=""
pve_ipv6_link_interfaces="vmbr0 eth0"
export PVE_NETWORK_INTERFACES_FILE="${tmp_dir}/interfaces"
: >"$PVE_NETWORK_INTERFACES_FILE"
ip() {
    if [[ "$*" == "-6 route show default" ]]; then
        if [ -n "$pve_default_ipv6_interface" ]; then
            printf 'default via fe80::1 dev %s proto ra metric 1024\n' "$pve_default_ipv6_interface"
        fi
        return 0
    fi
    if [[ "$*" == "link show dev "* ]]; then
        if [[ " ${pve_ipv6_link_interfaces} " == *" ${4:-} "* ]]; then
            return 0
        fi
        return 1
    fi
    if [[ "$*" == "-o -6 addr show" ]]; then
        printf '%s\n' "$nat_ipv6_addresses"
        return 0
    fi
    if [[ "$*" == "-6 route show table all" ]]; then
        printf '%s\n' "$nat_ipv6_routes"
        return 0
    fi
    if [[ "$*" == *"addr show scope global"* ]]; then
        printf '%s\n' '2: eth0    inet6 fd42::1/64 scope global'
        printf '%s\n' '2: eth0    inet6 2606:4700::1111/64 scope global'
        return 0
    fi
    if [[ "$*" == "-4 route get "* ]]; then
        printf '%s via 198.51.100.1 dev eth0\n' "${*: -1}"
    fi
}

export PVE_STATE_DIR="${tmp_dir}/state"
export PVE_NAT_SUBNET="10.250.0.0/24"
select_nat_ipv4_subnet
assert_eq "10.250.0.0/24" "$(cat "$PVE_STATE_DIR/pve_nat_subnet")" "requested NAT subnet"
assert_eq "10.250.0.1" "$(cat "$PVE_STATE_DIR/pve_nat_gateway")" "derived NAT gateway"

old_subnet=$(cat "$PVE_STATE_DIR/pve_nat_subnet")
old_gateway=$(cat "$PVE_STATE_DIR/pve_nat_gateway")
export PVE_NAT_SUBNET=$'10.251.0.0/24\n\033[32mSelected network\033[0m'
if select_nat_ipv4_subnet >/dev/null 2>&1; then
    printf 'FAIL: polluted PVE_NAT_SUBNET was accepted\n' >&2
    exit 1
fi
assert_eq "$old_subnet" "$(cat "$PVE_STATE_DIR/pve_nat_subnet")" "rejected subnet preserves state"
assert_eq "$old_gateway" "$(cat "$PVE_STATE_DIR/pve_nat_gateway")" "rejected subnet preserves gateway"

unset PVE_NAT_SUBNET
printf 'Attempting to select network...\n172.16.1.0/24\n' >"$PVE_STATE_DIR/pve_nat_subnet"
select_nat_ipv4_subnet
assert_eq "172.16.1.0/24" "$(cat "$PVE_STATE_DIR/pve_nat_subnet")" "polluted state rotates to default"
assert_eq "172.16.1.1" "$(cat "$PVE_STATE_DIR/pve_nat_gateway")" "rotated NAT gateway"

unset PVE_NAT_IPV6_SUBNET
nat_ipv6_addresses='2: eth0    inet6 2605:52c0:2:14b:be24:11ff:fe6e:d967/64 scope global dynamic'
nat_ipv6_routes=$'2605:52c0:2:14b::/64 dev eth0 proto kernel metric 256\n::/0 via fe80::6016:20ff:fe1a:d6dd dev eth0 metric 1024'
select_nat_ipv6_subnet
assert_eq "fd42:5339:296f:1f00::/64" "$(cat "$PVE_STATE_DIR/pve_nat_ipv6_subnet")" "automatic ULA NAT subnet"
assert_eq "fd42:5339:296f:1f00::1" "$(cat "$PVE_STATE_DIR/pve_nat_ipv6_gateway")" "automatic ULA NAT gateway"

old_ipv6_subnet=$(cat "$PVE_STATE_DIR/pve_nat_ipv6_subnet")
export PVE_NAT_IPV6_SUBNET='2605:52c0:2:14b:ffff:ffff:ffff:0/112'
if select_nat_ipv6_subnet >/dev/null 2>&1; then
    printf 'FAIL: public IPv6 child subnet was accepted for PVE NAT\n' >&2
    exit 1
fi
assert_eq "$old_ipv6_subnet" "$(cat "$PVE_STATE_DIR/pve_nat_ipv6_subnet")" "rejected public IPv6 prefix preserves state"

export PVE_NAT_IPV6_SUBNET='fd42:beef:1234:100::/64'
nat_ipv6_routes=$'fd42:beef:1234::/48 dev eth0 proto static\n2605:52c0:2:14b::/64 dev eth0 proto kernel'
if select_nat_ipv6_subnet >/dev/null 2>&1; then
    printf 'FAIL: ULA child of host IPv6 route was accepted for PVE NAT\n' >&2
    exit 1
fi

unset PVE_NAT_IPV6_SUBNET
printf '%s\n' 'fd42:5339:296f:1f07::/64' >"$PVE_STATE_DIR/pve_nat_ipv6_subnet"
nat_ipv6_addresses=$'2: eth0    inet6 2605:52c0:2:14b:be24:11ff:fe6e:d967/64 scope global dynamic\n10: vmbr1    inet6 fd42:5339:296f:1f07::1/64 scope global'
nat_ipv6_routes=$'2605:52c0:2:14b::/64 dev eth0 proto kernel\nfd42:5339:296f:1f07::/64 dev vmbr1 proto kernel\nlocal fd42:5339:296f:1f07::1 dev vmbr1 table local'
select_nat_ipv6_subnet
assert_eq "fd42:5339:296f:1f07::/64" "$(cat "$PVE_STATE_DIR/pve_nat_ipv6_subnet")" "active vmbr1 ULA subnet remains stable"

# Direct public IPv6 is only enabled from explicit delegation data. A normal
# SLAAC address is intentionally absent from this input path.
unset PVE_IPV6_ROUTED_PREFIX PVE_IPV6_DIRECT_GATEWAY PVE_IPV6_DIRECT_MODE
unset PVE_IPV6_BRIDGE_GATEWAY PVE_IPV6_DIRECT_BRIDGE PVE_IPV6_DIRECT_TRANSPORT
if pve_direct_ipv6_env_config >/dev/null; then
    printf 'FAIL: PVE direct IPv6 accepted an unspecified SLAAC-derived prefix\n' >&2
    exit 1
fi

export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:10f8::1/38'
export PVE_IPV6_DIRECT_GATEWAY='2a14:7c0:1002:10f8::1'
export PVE_IPV6_DIRECT_MODE=ndp
export PVE_IPV6_DIRECT_BRIDGE=vmbr2
export PVE_IPV6_DIRECT_TRANSPORT=bridge
mapfile -t direct_values < <(pve_direct_ipv6_env_config)
assert_eq "2a14:7c0:1000::/38" "${direct_values[0]}" "explicit non-nibble delegated prefix"
assert_eq "2a14:7c0:1002:10f8::1" "${direct_values[1]}" "explicit NDP bridge gateway"
assert_eq "vmbr2" "${direct_values[4]}" "explicit direct bridge"

export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:2000::/64'
export PVE_IPV6_DIRECT_GATEWAY='fe80::1'
export PVE_IPV6_DIRECT_MODE=routed
export PVE_IPV6_DIRECT_BRIDGE=vmbr9
export PVE_IPV6_DIRECT_TRANSPORT=tunnel
unset PVE_IPV6_BRIDGE_GATEWAY
mapfile -t direct_values < <(pve_direct_ipv6_env_config)
assert_eq "2a14:7c0:1002:2000::1" "${direct_values[1]}" "routed guest bridge gateway"
assert_eq "routed" "${direct_values[2]}" "routed direct mode"
assert_eq "fe80::1" "${direct_values[3]}" "routed upstream link-local gateway"
assert_eq "vmbr9" "${direct_values[4]}" "routed custom bridge"
assert_eq "tunnel" "${direct_values[5]}" "routed tunnel transport"

export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:10f8::1/128'
if pve_direct_ipv6_env_config >/dev/null; then
    printf 'FAIL: host-only /128 was accepted as a PVE direct IPv6 prefix\n' >&2
    exit 1
fi

export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:10f8::/127'
export PVE_IPV6_DIRECT_GATEWAY='2a14:7c0:1002:10f8::1'
export PVE_IPV6_DIRECT_MODE=ndp
if pve_direct_ipv6_env_config >/dev/null; then
    printf 'FAIL: point-to-point /127 was accepted for the PVE 100-256 guest ID range\n' >&2
    exit 1
fi

export PVE_STATE_DIR="${tmp_dir}/direct-state"
mkdir -p "$PVE_STATE_DIR"
pve_save_direct_ipv6_config '2a14:7c0:1002:2000::/64' '2a14:7c0:1002:2000::1' routed fe80::1 vmbr9 tunnel
assert_eq "2a14:7c0:1002:2000::/64" "$(cat "$PVE_STATE_DIR/pve_direct_ipv6_prefix")" "persisted routed prefix"
assert_eq "2a14:7c0:1002:2000::1" "$(cat "$PVE_STATE_DIR/pve_direct_ipv6_gateway")" "persisted guest bridge gateway"
assert_eq "fe80::1" "$(cat "$PVE_STATE_DIR/pve_direct_ipv6_upstream_gateway")" "persisted upstream gateway"
assert_eq "vmbr9" "$(cat "$PVE_STATE_DIR/pve_direct_ipv6_bridge")" "persisted direct bridge"
unset PVE_IPV6_ROUTED_PREFIX PVE_IPV6_DIRECT_GATEWAY PVE_IPV6_DIRECT_MODE
unset PVE_IPV6_BRIDGE_GATEWAY PVE_IPV6_DIRECT_BRIDGE PVE_IPV6_DIRECT_TRANSPORT
export PVE_STATE_DIR="${tmp_dir}/state"

if extract_function configure_vmbr2 | grep -Fq 'configure_vmbr2_with_ipv6_subnet'; then
    printf 'FAIL: PVE must not derive a vmbr2 public subnet from a host SLAAC address\n' >&2
    exit 1
fi
if ! extract_function configure_vmbr2 | grep -Fq 'pve_direct_ipv6_requested'; then
    printf 'FAIL: PVE direct IPv6 bridge setup must require explicit delegation\n' >&2
    exit 1
fi

for ipv6_script in "$repo_root/scripts/build_nat_network.sh" "$repo_root/scripts/check_kernal.sh" "$repo_root/scripts/install_pve.sh"; do
    ipv6_check=$(sed -n '/^check_ipv6() {/,/^}/p' "$ipv6_script")
    if grep -Eq 'API_NET|curl[[:space:]]' <<<"$ipv6_check"; then
        printf 'FAIL: %s check_ipv6 must not use an external address service\n' "$ipv6_script" >&2
        exit 1
    fi
    if ! grep -Fq 'ip -o -6 addr show scope global' <<<"$ipv6_check"; then
        printf 'FAIL: %s check_ipv6 must inspect locally bound global IPv6 addresses\n' "$ipv6_script" >&2
        exit 1
    fi
done
if ! extract_function install_required_tools | grep -Fq '"python3"'; then
    printf 'FAIL: build_nat_network.sh must install Python 3 for IPv6 validation\n' >&2
    exit 1
fi
if ! grep -Fq 'apt-get install python3 -y' "$repo_root/scripts/check_kernal.sh"; then
    printf 'FAIL: check_kernal.sh must install Python 3 for IPv6 validation\n' >&2
    exit 1
fi
if ! grep -Fq 'apt-get install -y python3' "$repo_root/scripts/install_pve.sh"; then
    printf 'FAIL: install_pve.sh must install Python 3 for IPv6 validation\n' >&2
    exit 1
fi
for classifier_script in "$repo_root/scripts/build_nat_network.sh" "$repo_root/scripts/check_kernal.sh" "$repo_root/scripts/install_pve.sh"; do
    eval "$(extract_function_from "$classifier_script" is_public_ipv6)"
    eval "$(extract_function_from "$classifier_script" is_private_ipv6)"
    if is_private_ipv6 "2606:4700::1111"; then
        printf 'FAIL: %s classified public IPv6 as private\n' "$classifier_script" >&2
        exit 1
    fi
    if ! is_private_ipv6 "2001::" || ! is_private_ipv6 "2001:0000::1" || ! is_private_ipv6 "2001:0010::1"; then
        printf 'FAIL: %s accepted a reserved IPv6 allocation source\n' "$classifier_script" >&2
        exit 1
    fi
    if ! is_private_ipv6 "fc12::1" || ! is_private_ipv6 "fe90::1" || ! is_private_ipv6 "fec0::1" || ! is_private_ipv6 "ff02::1"; then
        printf 'FAIL: %s classified local, site-local, or multicast IPv6 as public\n' "$classifier_script" >&2
        exit 1
    fi
done

# A default IPv6 route can be on a physical NIC, a routed bridge, or another
# provider-selected uplink. Preserve the vmbr0 fallback only when no route is
# available yet, and keep HE/6in4 plus explicit NDP-interface behavior.
pve_default_ipv6_interface=eth0
pve_ipv6_link_interfaces="eth0 vmbr0"
assert_eq eth0 "$(pve_ipv6_uplink_interface)" "default-route IPv6 uplink"
unset PVE_IPV6_DIRECT_NDP_INTERFACE
assert_eq eth0 "$(pve_direct_ndp_interface bridge)" "default-route NDP uplink"
assert_eq he-ipv6 "$(pve_direct_ndp_interface tunnel)" "HE tunnel NDP uplink"
export PVE_IPV6_DIRECT_NDP_INTERFACE=wan6
assert_eq wan6 "$(pve_direct_ndp_interface bridge)" "explicit NDP uplink"
unset PVE_IPV6_DIRECT_NDP_INTERFACE
pve_default_ipv6_interface=""
pve_ipv6_link_interfaces="vmbr0"
assert_eq vmbr0 "$(pve_ipv6_uplink_interface)" "legacy vmbr0 IPv6 uplink"

# During a first PVE install the active route can still point to the physical
# port, while the generated persistent configuration makes that port a vmbr0
# bridge member. The responder must follow the post-reload logical uplink.
cat >"$PVE_NETWORK_INTERFACES_FILE" <<'EOF'
auto vmbr0
iface vmbr0 inet static
    bridge_ports eth0
EOF
pve_default_ipv6_interface=eth0
pve_ipv6_link_interfaces="eth0 vmbr0"
assert_eq vmbr0 "$(pve_ipv6_uplink_interface)" "bridged IPv6 uplink migration"
assert_eq vmbr0 "$(pve_direct_ndp_interface bridge)" "bridged NDP uplink migration"

captured_sysctls=()
update_sysctl() {
    captured_sysctls+=("$1")
}
configure_ipv6_forwarding vmbr2
printf '%s\n' "${captured_sysctls[@]}" | grep -Fqx 'net.ipv6.conf.vmbr0.accept_ra=2' || {
    printf 'FAIL: PVE bridged IPv6 migration did not preserve RA on vmbr0\n' >&2
    exit 1
}
printf '%s\n' "${captured_sysctls[@]}" | grep -Fqx 'net.ipv6.conf.vmbr0.proxy_ndp=1' || {
    printf 'FAIL: PVE bridged IPv6 migration did not scope NDP proxying to vmbr0\n' >&2
    exit 1
}

# A non-bridged runtime uplink remains scoped to the actual default route.
: >"$PVE_NETWORK_INTERFACES_FILE"
pve_default_ipv6_interface=eth0
pve_ipv6_link_interfaces="eth0 vmbr0"
captured_sysctls=()
configure_ipv6_forwarding vmbr2
printf '%s\n' "${captured_sysctls[@]}" | grep -Fqx 'net.ipv6.conf.eth0.accept_ra=2' || {
    printf 'FAIL: PVE IPv6 forwarding did not preserve RA on the default-route uplink\n' >&2
    exit 1
}
printf '%s\n' "${captured_sysctls[@]}" | grep -Fqx 'net.ipv6.conf.eth0.proxy_ndp=1' || {
    printf 'FAIL: PVE IPv6 forwarding did not scope NDP proxying to the default-route uplink\n' >&2
    exit 1
}
if printf '%s\n' "${captured_sysctls[@]}" | grep -Fqx 'net.ipv6.conf.vmbr0.accept_ra=2'; then
    printf 'FAIL: PVE IPv6 forwarding retained a hard-coded vmbr0 RA setting\n' >&2
    exit 1
fi

if ! extract_function configure_ipv6_forwarding | grep -Fq 'pve_ipv6_uplink_interface'; then
    printf 'FAIL: PVE IPv6 forwarding must select the actual IPv6 uplink\n' >&2
    exit 1
fi
if ! extract_function configure_vmbr2_with_explicit_ipv6_prefix | grep -Fq 'pve_direct_ndp_interface'; then
    printf 'FAIL: PVE direct IPv6 setup must select the actual NDP uplink\n' >&2
    exit 1
fi
if extract_function configure_ipv6_forwarding | grep -Fq 'net.ipv6.conf.all.proxy_ndp=1'; then
    printf 'FAIL: PVE must not enable NDP proxying globally\n' >&2
    exit 1
fi
if extract_function configure_ipv6_forwarding | grep -Fq 'net.ipv6.conf.default.proxy_ndp=1'; then
    printf 'FAIL: PVE must not enable NDP proxying by default on future interfaces\n' >&2
    exit 1
fi
if grep -Fq 'post-down sysctl -w net.ipv6.conf.all.forwarding=0' "$network_script"; then
    printf 'FAIL: PVE must not disable host IPv6 forwarding when vmbr1 is stopped\n' >&2
    exit 1
fi
captured_ipv6_path=""
captured_ipv6_value=""
write_network_state_atomic() {
    captured_ipv6_path="$1"
    captured_ipv6_value="$2"
    "$3" "$2"
}
curl() {
    : >"$tmp_dir/external-ipv6-lookup"
    return 1
}
check_ipv6
assert_eq "2606:4700::1111" "$IPV6" "locally bound IPv6 selection"
assert_eq "/usr/local/bin/pve_check_ipv6" "$captured_ipv6_path" "IPv6 state path"
assert_eq "2606:4700::1111" "$captured_ipv6_value" "IPv6 state value"
[ ! -e "$tmp_dir/external-ipv6-lookup" ] || {
    printf 'FAIL: PVE check_ipv6 used an external address service\n' >&2
    exit 1
}

printf 'PVE NAT network state tests passed\n'
