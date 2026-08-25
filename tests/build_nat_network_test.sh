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
eval "$(extract_function write_network_state_atomic)"
eval "$(extract_function read_network_state)"
eval "$(extract_function is_public_ipv6)"
eval "$(extract_function is_private_ipv6)"
eval "$(extract_function check_ipv6)"
eval "$(extract_function select_nat_ipv4_subnet)"
eval "$(extract_function pve_nat_ipv6_candidate_is_safe)"
eval "$(extract_function select_nat_ipv6_subnet)"

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
ip() {
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
if ! extract_function configure_ipv6_forwarding | grep -Fq 'net.ipv6.conf.vmbr0.accept_ra=2'; then
    printf 'FAIL: PVE IPv6 forwarding must preserve router advertisements on vmbr0\n' >&2
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
