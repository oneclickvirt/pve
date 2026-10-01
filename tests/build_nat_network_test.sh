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
eval "$(extract_function pve_ipv6_json_probe)"
eval "$(extract_function pve_ipv6_configured_alias_addresses)"
eval "$(extract_function pve_he_bridge_cidr)"
eval "$(extract_function check_ipv6)"
eval "$(extract_function select_nat_ipv4_subnet)"
eval "$(extract_function pve_nat_ipv6_candidate_is_safe)"
eval "$(extract_function select_nat_ipv6_subnet)"
eval "$(extract_function pve_save_direct_ipv6_config)"
eval "$(extract_function pve_vmbr0_owns_interface)"
eval "$(extract_function pve_ipv6_uplink_interface)"
eval "$(extract_function pve_direct_ndp_interface)"
eval "$(extract_function pve_network_bridge_exists)"
eval "$(extract_function pve_install_ipv6_ifup_hook)"
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

# The tunnel address, any other live host address, and unrelated host routes
# must remain outside the chosen guest bridge subnet. JSON stays parseable
# when the terminal has colored output or the host language changes.
he_routes=$'\033[32m[{"type":"local","dst":"local","dev":"lo"},{"type":"multicast","dst":"multicast","dev":"eth0"},{"gateway":"fe80::1","dev":"eth0"},{"dst":"2001:470:1234::/64","dev":"he-ipv6"},{"dst":"2001:470:1234:0:100::/72","dev":"eth1"}]\033[0m'
assert_eq '2001:470:1234:0:200::1/72' \
    "$(pve_he_bridge_cidr '2001:470:1234::2/64' '2001:470:1234::1' '2001:470:1234::2/64' "$he_routes")" \
    'HE /64 skips tunnel host, gateway, and occupied child'
wide_choice=$(pve_he_bridge_cidr '2a14:7c0:1002:10f8::1/38' '2a14:7c0:1002:10f8::2' \
    '2a14:7c0:1002:10f8::1/38' '[{"dst":"2a14:7c0:1000::/38","dev":"he-ipv6"}]')
python3 - "$wide_choice" <<'PY'
import ipaddress
import sys
child = ipaddress.IPv6Interface(sys.argv[1]).network
assert child.prefixlen == 40
assert ipaddress.IPv6Address('2a14:7c0:1002:10f8::1') not in child
PY
assert_eq '2001:470:1234::101/120' \
    "$(pve_he_bridge_cidr '2001:470:1234::2/119' '2001:470:1234::1' '2001:470:1234::2/119' \
        '[{"dst":"2001:470:1234::/119","dev":"he-ipv6"}]')" \
    'HE /119 uses its other /120 child'

cat >"${tmp_dir}/ipv6-aliases" <<'EOF'
# control-alias eth0:1
iface eth0:1 inet6 static
    address 2a01:4f8:c014:1a63::10/64
# control-alias eth0:2
iface eth0:2 inet6 static
    address 2a14:7c0:1002:10f8::10/38
# control-alias eth0:3
iface eth0:3 inet6 static
    address 2a01:4f8:c014:1a63:1234::10/80
# control-alias eth0:4
iface eth0:4 inet6 static
    address 2a01:4f8:c014:1a63::20/120
# control-alias eth0:5
iface eth0:5 inet static
    address 198.51.100.10/24
EOF
assert_eq $'2a01:4f8:c014:1a63::10\n2a14:7c0:1002:10f8::10\n2a01:4f8:c014:1a63:1234::10\n2a01:4f8:c014:1a63::20' \
    "$(pve_ipv6_configured_alias_addresses "${tmp_dir}/ipv6-aliases")" \
    'IPv6 alias parser preserves variable prefix lengths and skips IPv4'

for narrow in 120 127 128; do
    if pve_he_bridge_cidr "2001:470:1234::2/${narrow}" '2001:470:1234::1' \
        "2001:470:1234::2/${narrow}" '[]' >/dev/null 2>&1; then
        printf 'FAIL: HE /%s offered an undersized guest bridge\n' "$narrow" >&2
        exit 1
    fi
done

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
    if [[ "$*" == "-j -6 route show default" ]]; then
        if [ -n "$pve_default_ipv6_interface" ]; then
            printf '[{"dst":"default","dev":"%s","gateway":"fe80::1"}]\n' "$pve_default_ipv6_interface"
        else
            printf '%s\n' '[]'
        fi
        return 0
    fi
    if [[ "$*" == "-j -6 addr show" ]]; then
        if [ -n "$nat_ipv6_addresses" ]; then
            printf '%s\n' "$nat_ipv6_addresses"
        else
            printf '%s\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2606:4700::1111","prefixlen":64,"scope":"global"}]}]'
        fi
        return 0
    fi
    if [[ "$*" == "-j -6 route show table all" ]]; then
        printf '%s\n' "${nat_ipv6_routes:-[]}"
        return 0
    fi
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
nat_ipv6_addresses='[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2605:52c0:2:14b:be24:11ff:fe6e:d967","prefixlen":64,"scope":"global"}]}]'
nat_ipv6_routes='[{"dst":"2605:52c0:2:14b::/64","dev":"eth0"},{"dst":"default","gateway":"fe80::6016:20ff:fe1a:d6dd","dev":"eth0"}]'
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
nat_ipv6_routes='[{"dst":"fd42:beef:1234::/48","dev":"eth0"},{"dst":"2605:52c0:2:14b::/64","dev":"eth0"}]'
if select_nat_ipv6_subnet >/dev/null 2>&1; then
    printf 'FAIL: ULA child of host IPv6 route was accepted for PVE NAT\n' >&2
    exit 1
fi

unset PVE_NAT_IPV6_SUBNET
printf '%s\n' 'fd42:5339:296f:1f07::/64' >"$PVE_STATE_DIR/pve_nat_ipv6_subnet"
nat_ipv6_addresses='[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2605:52c0:2:14b:be24:11ff:fe6e:d967","prefixlen":64,"scope":"global"}]},{"ifname":"vmbr1","addr_info":[{"family":"inet6","local":"fd42:5339:296f:1f07::1","prefixlen":64,"scope":"global"}]}]'
nat_ipv6_routes='[{"dst":"2605:52c0:2:14b::/64","dev":"eth0"},{"dst":"fd42:5339:296f:1f07::/64","dev":"vmbr1"},{"dst":"fd42:5339:296f:1f07::1","dev":"vmbr1","type":"local"}]'
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
    if ! grep -Fq 'ip -o -6 addr show scope global' <<<"$ipv6_check" &&
       ! { grep -Fq 'pve_ipv6_json_probe addresses' <<<"$ipv6_check" && grep -Fq 'ip -j -6 addr show' "$ipv6_script"; }; then
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

export PVE_IPV6_IFUP_HOOK_FILE="$tmp_dir/if-up.d/99-oneclickvirt-ipv6-sysctl"
export PVE_IPV6_SYSCTL_CONFIG_FILE="$tmp_dir/sysctl.d/99-oneclickvirt-pve-ipv6.conf"
export PVE_SYSCTL_LEGACY_FILE="$tmp_dir/no-legacy-sysctl.conf"
export PVE_IPV6_PROC_CONF_ROOT="$tmp_dir/proc/net/ipv6/conf"
mkdir -p "$PVE_IPV6_PROC_CONF_ROOT/eth0"
: >"$PVE_IPV6_PROC_CONF_ROOT/eth0/accept_ra"
captured_sysctls=()
sysctl() {
    captured_sysctls+=("runtime:$*")
}
update_sysctl() {
    captured_sysctls+=("$1")
}
configure_ipv6_forwarding vmbr2
assert_eq 'runtime:-w net.ipv6.conf.eth0.accept_ra=2' "${captured_sysctls[0]}" \
    'first install protects the current physical uplink before forwarding'
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

# A bridge configured for the next reload does not yet have a /proc sysctl.
# Its value must persist and the if-up hook must apply it on first creation.
cat >>"$PVE_NETWORK_INTERFACES_FILE" <<'EOF'
auto vmbr0
iface vmbr0 inet static
    bridge_ports eth0
auto vmbr1
iface vmbr1 inet6 static
    bridge_ports none
EOF
eval "$(extract_function update_sysctl)"
update_sysctl 'net.ipv6.conf.vmbr0.accept_ra=2'
update_sysctl 'net.ipv6.conf.vmbr1.proxy_ndp=1'
printf '%s\n' 'net.ipv6.conf.vmbr0.accept_ra=2' | grep -Fqxf "$PVE_IPV6_SYSCTL_CONFIG_FILE" || {
    printf 'FAIL: PVE did not persist future vmbr0 router advertisements\n' >&2
    exit 1
}
printf '%s\n' 'net.ipv6.conf.vmbr1.proxy_ndp=1' | grep -Fqxf "$PVE_IPV6_SYSCTL_CONFIG_FILE" || {
    printf 'FAIL: PVE did not persist future vmbr1 NDP proxying\n' >&2
    exit 1
}
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/sysctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$PVE_TEST_APPLIED_SYSCTLS"
EOF
chmod +x "$tmp_dir/bin/sysctl"
export PVE_TEST_APPLIED_SYSCTLS="$tmp_dir/applied-sysctls"
PATH="$tmp_dir/bin:$PATH" IFACE=vmbr0 "$PVE_IPV6_IFUP_HOOK_FILE"
PATH="$tmp_dir/bin:$PATH" IFACE=vmbr1 "$PVE_IPV6_IFUP_HOOK_FILE"
grep -Fqx -- '-q -w net.ipv6.conf.vmbr0.accept_ra=2' "$PVE_TEST_APPLIED_SYSCTLS" || {
    printf 'FAIL: PVE did not reapply vmbr0 RA on first if-up\n' >&2
    exit 1
}
grep -Fqx -- '-q -w net.ipv6.conf.vmbr1.proxy_ndp=1' "$PVE_TEST_APPLIED_SYSCTLS" || {
    printf 'FAIL: PVE did not reapply vmbr1 NDP on first if-up\n' >&2
    exit 1
}

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
if ! extract_function configure_vmbr1 | grep -Fq 'configure_ipv6_forwarding vmbr1 || return 1' ||
   ! grep -Fq 'configure_vmbr1 || exit 1' "$network_script"; then
    printf 'FAIL: PVE NAT66 setup can continue without preserving host router advertisements\n' >&2
    exit 1
fi
update_sysctl() { return 1; }
if configure_ipv6_forwarding vmbr1; then
    printf 'FAIL: PVE ignored a failed host IPv6 sysctl update\n' >&2
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
nat_ipv6_addresses=""
check_ipv6
assert_eq "2606:4700::1111" "$IPV6" "locally bound IPv6 selection"
assert_eq "/usr/local/bin/pve_check_ipv6" "$captured_ipv6_path" "IPv6 state path"
assert_eq "2606:4700::1111" "$captured_ipv6_value" "IPv6 state value"
[ ! -e "$tmp_dir/external-ipv6-lookup" ] || {
    printf 'FAIL: PVE check_ipv6 used an external address service\n' >&2
    exit 1
}

printf 'PVE NAT network state tests passed\n'
