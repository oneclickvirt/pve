#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="${repo_root}/scripts/install_pve.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

extract_function() {
    local name="$1"
    sed -n "/^${name}() {/,/^}/p" "$installer"
}

eval "$(extract_function get_ipv4_prefixlen)"
eval "$(extract_function get_ipv4_address_plain)"
eval "$(extract_function get_ipv4_address_cidr)"
eval "$(extract_function is_single_network_value)"
eval "$(extract_function validate_prefixlen_value)"
eval "$(extract_function validate_ipv6_prefixlen_value)"
eval "$(extract_function validate_interface_value)"
eval "$(extract_function validate_ipv4_value)"
eval "$(extract_function validate_ipv4_network24_value)"
eval "$(extract_function validate_ipv6_value)"
eval "$(extract_function write_network_state_atomic)"
eval "$(extract_function read_network_state)"
eval "$(extract_function ensure_selected_interface_ipv4_config)"
eval "$(extract_function choose_persisted_ipv4_address)"
eval "$(extract_function install_proxmox_packages)"

_red() { :; }
_yellow() { :; }

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_file_absent() {
    local path="$1" label="$2"
    if [[ -e "$path" ]]; then
        printf 'FAIL: %s: unexpected file remains at %s\n' "$label" "$path" >&2
        exit 1
    fi
}

assert_rejected() {
    local label="$1"
    shift
    if "$@"; then
        printf 'FAIL: %s: polluted or invalid value was accepted\n' "$label" >&2
        exit 1
    fi
}

# Reproduce the reported failure shape: status messages, ANSI color bytes and
# the discovered prefix were captured together and later written as one value.
polluted_prefix=$'Attempting to get real IPv6 prefix from router advertisement...\n\033[32mFound real IPv6 prefix length: /64\033[0m\n64'
assert_rejected "multiline IPv6 prefix" validate_ipv6_prefixlen_value "$polluted_prefix"
assert_rejected "quoted IPv6 prefix" validate_ipv6_prefixlen_value "64'"
assert_rejected "ANSI IPv6 prefix" validate_ipv6_prefixlen_value $'\033[32m64\033[0m'
assert_rejected "multiline interface" validate_interface_value $'eth0\nUsing network interface: eth0'
assert_rejected "oversized interface" validate_interface_value "interface-name-over-15"
assert_rejected "polluted IPv4" validate_ipv4_value $'192.0.2.10/24\nnetwork ready'
assert_rejected "malformed IPv4" validate_ipv4_value "192.0.2.999/24"
assert_rejected "polluted IPv6" validate_ipv6_value $'2001:db8::10\n64'
assert_rejected "malformed IPv6" validate_ipv6_value "2001:db8:::10"
validate_ipv6_prefixlen_value "80"
validate_interface_value "enp1s0.100"
validate_ipv4_value "192.0.2.10/31"
validate_ipv4_network24_value "10.250.0.0/24"
validate_ipv6_value "2001:db8:1:2:3::10/80"
validate_ipv6_value "2001:db8::10/128"

state_file="${tmp_dir}/network-state"
printf 'old-value\n' >"$state_file"
assert_rejected "invalid atomic state write" write_network_state_atomic "$state_file" "$polluted_prefix" validate_ipv6_prefixlen_value
assert_eq "old-value" "$(cat "$state_file")" "failed atomic write preserves old state"
write_network_state_atomic "$state_file" "64" validate_ipv6_prefixlen_value
assert_eq "64" "$(read_network_state "$state_file" validate_ipv6_prefixlen_value)" "atomic state write/read"
printf '64\nstatus line\n' >"$state_file"
assert_rejected "multiline persisted state" read_network_state "$state_file" validate_ipv6_prefixlen_value
if compgen -G "${state_file}.tmp.*" >/dev/null; then
    printf 'FAIL: atomic state write left temporary files behind\n' >&2
    exit 1
fi

# A previously captured address/prefix is authoritative when the same address
# comes back with a different classful prefix after reboot. Cover both prefix
# directions rather than only the /24 -> /8 incident seen on LightNode.
assert_eq "38.60.134.247/24" "$(choose_persisted_ipv4_address "38.60.134.247/8" "38.60.134.247/24")" "preserve narrower subnet"
assert_eq "10.0.0.10/20" "$(choose_persisted_ipv4_address "10.0.0.10/24" "10.0.0.10/20")" "preserve wider subnet"
assert_eq "10.0.0.11/24" "$(choose_persisted_ipv4_address "10.0.0.11/24" "10.0.0.10/20")" "do not reuse prefix for a different address"
assert_eq "10.0.0.10/24" "$(choose_persisted_ipv4_address "10.0.0.10/24" "invalid")" "ignore invalid persisted state"

interfaces_file="${tmp_dir}/interfaces"
interfaces_dir="${tmp_dir}/interfaces.d"
mkdir -p "$interfaces_dir"
cat >"$interfaces_file" <<'EOF'
auto lo
iface lo inet loopback

auto eth1
iface eth1 inet static
    address 38.60.134.247
    address 38.60.134.248/8
    netmask 255.0.0.0
    gateway 38.60.134.1
EOF

interface=eth1
ipv4_address=38.60.134.247/24
ipv4_subnet=255.255.255.0
PVE_NETWORK_INTERFACES_FILE="$interfaces_file"
PVE_NETWORK_INTERFACES_DIR="$interfaces_dir"
ensure_selected_interface_ipv4_config
grep -Fxq '    address 38.60.134.247' "$interfaces_file"
grep -Fxq '    netmask 255.255.255.0' "$interfaces_file"
grep -Fxq '    gateway 38.60.134.1' "$interfaces_file"
assert_eq "1" "$(grep -Fc '    address 38.60.134.247' "$interfaces_file")" "collapse duplicate address lines"
assert_eq "1" "$(grep -Fc '    netmask 255.255.255.0' "$interfaces_file")" "collapse duplicate netmask lines"
cp "$interfaces_file" "${tmp_dir}/interfaces.once"
ensure_selected_interface_ipv4_config
cmp -s "$interfaces_file" "${tmp_dir}/interfaces.once" || {
    printf 'FAIL: selected-interface normalization is not idempotent\n' >&2
    exit 1
}
assert_eq "38.60.134.247/24" "$(get_ipv4_address_cidr)" "bridge CIDR"

# A DHCP-only stanza is intentionally left untouched; rebuild_interfaces owns
# that conversion later in the installer.
dhcp_file="${tmp_dir}/dhcp-interfaces"
cat >"$dhcp_file" <<'EOF'
auto eth9
iface eth9 inet dhcp
EOF
interface=eth9
ipv4_address=192.0.2.10/24
ipv4_subnet=255.255.255.0
PVE_NETWORK_INTERFACES_FILE="$dhcp_file"
ensure_selected_interface_ipv4_config
grep -Fxq 'iface eth9 inet dhcp' "$dhcp_file"
if grep -q 'address 192.0.2.10' "$dhcp_file"; then
    printf 'FAIL: DHCP interface was rewritten prematurely\n' >&2
    exit 1
fi

# The marker must exist while dpkg configures ifupdown2, be removed on normal
# completion and failure when this script created it, and be preserved when an
# outer Proxmox installer already owns it.
install_package() { :; }
ensure_arm_qemu_server_installable() { return 0; }
verify_pve_installation() { return 0; }
cleanup_ceph_service_packages() { :; }
install_optional_pve_packages() { :; }
rebuild_interfaces() { :; }
rollback_failed_pve_install() { :; }

marker="${tmp_dir}/proxmox_install_mode"
PROXMOX_INSTALL_MODE_FILE="$marker"
TEST_INSTALL_DPKG_FAILURE=false
# install_proxmox_packages is loaded above through eval, so ShellCheck cannot
# see this intentionally injected test double as a direct call site.
# shellcheck disable=SC2317
install_dpkg_packages() {
    [[ -e "$PROXMOX_INSTALL_MODE_FILE" ]] || return 1
    [[ "$TEST_INSTALL_DPKG_FAILURE" != true ]]
}
install_proxmox_packages
assert_file_absent "$marker" "owned install marker after success"

TEST_INSTALL_DPKG_FAILURE=true
set +e
(install_proxmox_packages >/dev/null 2>&1)
failure_status=$?
set -e
if [[ "$failure_status" -eq 0 ]]; then
    printf 'FAIL: package installation failure was accepted\n' >&2
    exit 1
fi
assert_file_absent "$marker" "owned install marker after failure"

touch "$marker"
TEST_INSTALL_DPKG_FAILURE=false
install_proxmox_packages
if [[ ! -e "$marker" ]]; then
    printf 'FAIL: pre-existing Proxmox install marker was removed\n' >&2
    exit 1
fi

printf 'PVE installer network/install-mode tests passed\n'
