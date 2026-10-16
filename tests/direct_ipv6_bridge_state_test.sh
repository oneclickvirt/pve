#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
export PVE_STATE_DIR="$tmp_dir/state"
export PVE_NETWORK_INTERFACES_FILE="$tmp_dir/interfaces"
mkdir "$PVE_STATE_DIR" "$tmp_dir/interfaces.d"
cat >"$PVE_NETWORK_INTERFACES_FILE" <<'EOF'
auto lo
iface lo inet loopback
source interfaces.d/*
EOF
cat >"$tmp_dir/interfaces.d/direct" <<'EOF'
auto vmbr9
iface vmbr9 inet6 static
    address 2a14:7c0:1002:2000::1
    netmask 64
EOF
printf '%s\n' vmbr9 >"$PVE_STATE_DIR/pve_direct_ipv6_bridge"
fixture_bridge_json='[]'
pve_direct_ipv6_available=false
pve_direct_ipv6_prefix=''
ip() {
    case "$*" in
        '-j -6 addr show dev '*) printf '%s\n' "$fixture_bridge_json" ;;
        '-j -6 addr show') printf '%s\n' "$fixture_bridge_json" ;;
        '-j -6 route show default') printf '%s\n' '[{"dst":"default","dev":"eth0","gateway":"fe80::1"}]' ;;
        'link show '*) return 1 ;;
        *) return 1 ;;
    esac
}
assert_eq() {
    [[ "$1" == "$2" ]] || { printf 'FAIL: %s: expected %s, got %s\n' "$3" "$1" "$2" >&2; exit 1; }
}

for file in default_ct_config.sh default_vm_config.sh; do
    # shellcheck source=/dev/null
    source "$repo_root/scripts/$file"
    _yellow() { :; }
    _red() { :; }
    fixture_bridge_json='[]'
    rm -f "$PVE_STATE_DIR/pve_direct_ipv6_prefix" "$PVE_STATE_DIR/pve_direct_ipv6_gateway"
    pve_load_direct_ipv6_config
    assert_eq true "$pve_direct_ipv6_available" "$file preserves bridge in included file"
    assert_eq '2a14:7c0:1002:2000::/64' "$pve_direct_ipv6_prefix" "$file separate netmask"

    printf '%s\n' '2a14:7c0:1002:2000::/64' >"$PVE_STATE_DIR/pve_direct_ipv6_prefix"
    printf '%s\n' '2a14:7c0:1002:2000::1' >"$PVE_STATE_DIR/pve_direct_ipv6_gateway"
    printf '%s\n' routed >"$PVE_STATE_DIR/pve_direct_ipv6_mode"
    printf '%s\n' fe80::1 >"$PVE_STATE_DIR/pve_direct_ipv6_upstream_gateway"
    printf '%s\n' bridge >"$PVE_STATE_DIR/pve_direct_ipv6_transport"
    fixture_bridge_json='[{"ifname":"vmbr9","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:1000::1","prefixlen":80,"scope":"global"},{"family":"inet6","local":"2a14:7c0:1002:2000::1","prefixlen":64,"scope":"global"}]}]'
    pve_load_direct_ipv6_config
    assert_eq true "$pve_direct_ipv6_available" "$file selects matching address among multiple prefixes"
    if pve_direct_ipv6_ndp_required; then
        printf 'FAIL: %s routed bridge unnecessarily requires NDP\n' "$file" >&2
        exit 1
    fi
    fixture_bridge_json='[{"ifname":"vmbr9","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:2000::1","prefixlen":80,"scope":"global"}]}]'
    pve_load_direct_ipv6_config
    assert_eq false "$pve_direct_ipv6_available" "$file rejects stale prefix despite matching stale config file"
done

for function_name in is_single_network_value pve_ipv6_json_probe pve_existing_direct_ipv6_matches pve_direct_ipv6_env_config validate_pve_direct_ipv6_bridge_value validate_pve_direct_ipv6_transport_value configure_vmbr2_with_explicit_ipv6_prefix; do
    eval "$(sed -n "/^${function_name}() {/,/^}/p" "$repo_root/scripts/build_nat_network.sh")"
done
export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:2000::/64'
export PVE_IPV6_DIRECT_GATEWAY='fe80::1'
export PVE_IPV6_DIRECT_MODE=routed
export PVE_IPV6_DIRECT_BRIDGE=vmbr9
fixture_bridge_json='[{"ifname":"vmbr9","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:2000::7","prefixlen":64,"scope":"global"}]}]'
direct_config=$(pve_direct_ipv6_env_config)
assert_eq '2a14:7c0:1002:2000::7' "$(sed -n '2p' <<<"$direct_config")" 'explicit routed config preserves actual existing bridge gateway'
unset PVE_IPV6_ROUTED_PREFIX PVE_IPV6_DIRECT_GATEWAY PVE_IPV6_DIRECT_MODE PVE_IPV6_DIRECT_BRIDGE

# Tentative host addresses are still reserved, and must not be copied onto
# a new bridge before DAD has finished.
fixture_bridge_json='[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:2000::1","prefixlen":64,"scope":"global","tentative":true}]}]'
pve_append_network_config() { : >"$tmp_dir/unexpected-bridge-write"; }
disable_ndpresponder() { :; }
configure_ipv6_forwarding() { :; }
pve_save_direct_ipv6_config() { :; }
if configure_vmbr2_with_explicit_ipv6_prefix '2a14:7c0:1002:2000::/64' '2a14:7c0:1002:2000::1' routed fe80::1 vmbr2 bridge; then
    printf 'FAIL: tentative host address was reused as bridge gateway\n' >&2
    exit 1
fi
[[ ! -e "$tmp_dir/unexpected-bridge-write" ]]

# Exercise cleanup against a local file. It must retain includes, a second
# NIC, and a working tunnel instead of deleting the entire lo-to-vmbr0 range.
for function_name in backup_and_clean_interfaces pve_require_writable_network_file pve_vmbr0_owns_interface validate_interface_value is_single_network_value; do
    eval "$(sed -n "/^${function_name}() {/,/^}/p" "$repo_root/scripts/build_nat_network.sh")"
done
lsattr() { printf '%s\n' '-------------------'; }
chattr() { :; }
chmod() { :; }
chown() { :; }
interface=eth0
cat >"$PVE_NETWORK_INTERFACES_FILE" <<'EOF'
auto lo
iface lo inet loopback
source interfaces.d/*
auto eth0 eth1
iface eth0 inet6 static
    address 2a01:4f8:c014:1a63::2/64
iface eth1 inet static
    address 192.0.2.2/24
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
    address 2001:470:1234::2/64
auto vmbr0
iface vmbr0 inet static
    bridge_ports eth0
EOF
backup_and_clean_interfaces
grep -Fxq 'source interfaces.d/*' "$PVE_NETWORK_INTERFACES_FILE"
grep -Fxq 'auto eth1' "$PVE_NETWORK_INTERFACES_FILE"
grep -Fxq 'iface eth1 inet static' "$PVE_NETWORK_INTERFACES_FILE"
grep -Fxq 'iface he-ipv6 inet6 v4tunnel' "$PVE_NETWORK_INTERFACES_FILE"
if grep -q '^iface eth0 ' "$PVE_NETWORK_INTERFACES_FILE"; then
    printf 'FAIL: migrated physical uplink configuration was retained twice\n' >&2
    exit 1
fi

# Installation must retain a static uplink's real mask. Run only the bridge
# formatter with every state/config path redirected into this fixture.
formatter=$(sed -n '/^configure_vmbr0_bridge() {/,/^}/p' "$repo_root/scripts/install_pve.sh")
formatter=${formatter//\/etc\/network\/interfaces/$PVE_NETWORK_INTERFACES_FILE}
formatter=${formatter//\/usr\/local\/bin/$PVE_STATE_DIR}
eval "$formatter"
eval "$(sed -n '/^pve_installer_network_topology() {/,/^}/p' "$repo_root/scripts/install_pve.sh")"
get_ipv4_address_cidr() { printf '%s\n' '192.0.2.2/24'; }
format_ipv4_gateway_config() { printf '%s\n' '    gateway 192.0.2.1'; }
sudo() { "$@"; }
ipv6_address='2a14:7c0:1002:10f8::2'
ipv6_gateway='fe80::1'
for ipv6_prefixlen in 38 64 120 128; do
    : >"$PVE_NETWORK_INTERFACES_FILE"
    configure_vmbr0_bridge >/dev/null
    grep -Fxq "    address ${ipv6_address}/${ipv6_prefixlen}" "$PVE_NETWORK_INTERFACES_FILE"
done

# A stale address from another NIC cannot be paired with the default-route
# interface's gateway, while the runtime snapshot still keeps both NICs.
detector=$(sed -n '/^detect_existing_ipv6_config() {/,/^}/p' "$repo_root/scripts/build_nat_network.sh")
detector=${detector//\/usr\/local\/bin/$PVE_STATE_DIR}
eval "$detector"
for function_name in validate_ipv6_value validate_ipv6_prefixlen_value validate_prefixlen_value write_network_state_atomic read_network_state; do
    eval "$(sed -n "/^${function_name}() {/,/^}/p" "$repo_root/scripts/build_nat_network.sh")"
done
pve_capture_host_ipv6_runtime() {
    host_ipv6_runtime_interface=eth0
    host_ipv6_runtime_gateway=fe80::1
    host_ipv6_runtime_cidrs=$'2a14:7c0:1002:2000::2/64\n2a01:4f8:c014:1a63::2/56'
    host_ipv6_runtime_address_bindings=$'eth1\t2a14:7c0:1002:2000::2/64\neth0\t2a01:4f8:c014:1a63::2/56'
}
printf '%s\n' '2a14:7c0:1002:2000::2' >"$PVE_STATE_DIR/pve_check_ipv6"
detect_existing_ipv6_config
assert_eq '2a01:4f8:c014:1a63::2' "$ipv6_address" 'host address follows actual default-route NIC'
assert_eq 56 "$ipv6_prefixlen" 'host prefix follows its own NIC'

# HE hosts also need the private IPv6 NAT gateway for a usable NAT66 fallback.
nat_builder=$(sed -n '/^configure_vmbr1() {/,/^}/p' "$repo_root/scripts/build_nat_network.sh")
nat_builder=${nat_builder//\/usr\/local\/bin/$PVE_STATE_DIR}
eval "$nat_builder"
add_vmbr1_with_ipv6() { fixture_nat_mode=dual; }
add_vmbr1_ipv4_only() { fixture_nat_mode=ipv4; }
fixture_nat_mode=''
status_he=true
configure_vmbr1
assert_eq dual "$fixture_nat_mode" 'HE NAT bridge includes its ULA IPv6 gateway'

# Changing a preserved service's prefix must reload the running process once.
# Subsequent calls with an unchanged configuration must not restart it again.
setup=$(sed -n '/^setup_ndpresponder() {/,/^}/p' "$repo_root/scripts/build_nat_network.sh")
setup=${setup//\/usr\/local\/bin/$PVE_STATE_DIR}
setup=${setup//\/etc\/systemd\/system/$tmp_dir/unit}
eval "$setup"
for function_name in pve_direct_ipv6_state_file validate_pve_direct_ipv6_mode_value; do
    eval "$(sed -n "/^${function_name}() {/,/^}/p" "$repo_root/scripts/build_nat_network.sh")"
done
mkdir "$tmp_dir/unit"
: >"$PVE_STATE_DIR/ndpresponder"
: >"$tmp_dir/unit/ndpresponder.service"
printf '%s\n' ndp >"$PVE_STATE_DIR/pve_direct_ipv6_mode"
systemctl() { printf '%s\n' "$*" >>"$tmp_dir/service-calls"; }
pve_ndpresponder_config_changed=true
setup_ndpresponder >/dev/null
setup_ndpresponder >/dev/null
assert_eq 1 "$(grep -c '^restart ndpresponder.service$' "$tmp_dir/service-calls")" 'service restarted only for changed configuration'
assert_eq 1 "$(grep -c '^start ndpresponder.service$' "$tmp_dir/service-calls")" 'unchanged service uses normal start'
printf 'direct IPv6 bridge-state and topology-preservation tests passed\n'
