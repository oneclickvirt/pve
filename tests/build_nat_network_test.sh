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

eval "$(extract_function is_single_network_value)"
eval "$(extract_function validate_prefixlen_value)"
eval "$(extract_function validate_ipv6_prefixlen_value)"
eval "$(extract_function validate_interface_value)"
eval "$(extract_function validate_ipv4_value)"
eval "$(extract_function validate_ipv4_network24_value)"
eval "$(extract_function validate_ipv6_value)"
eval "$(extract_function write_network_state_atomic)"
eval "$(extract_function read_network_state)"
eval "$(extract_function select_nat_ipv4_subnet)"

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
ip() {
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

printf 'PVE NAT network state tests passed\n'
