#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

# The configuration file is intentionally function-only, so it can be sourced
# without invoking a PVE command.  Stub downloads and exercise the image
# selection branches in an isolated temporary path.
# shellcheck source=/dev/null
source "${repo_root}/scripts/default_vm_config.sh"

_blue() { :; }
_red() { :; }
_yellow() { :; }
download_calls=()
_download_with_retry() {
    download_calls+=("$1")
    : >"$2"
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL: %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

file_path="${tmp_dir}/debian12.qcow2"
system="debian12"
cdn_success_url=""
sys_family=""
sys_tag_images=()
# Keep an empty first element to cover the array-length bug that previously
# skipped valid images in later elements.
new_images=("" "debian12_20260822_cloud.qcow2")
ver=""
download_calls=()
download_x86_image >/dev/null
assert_eq "1" "${#download_calls[@]}" "new image download count"
assert_eq "https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/debian12_20260822_cloud.qcow2" "${download_calls[0]}" "new image URL"
assert_eq "auto_build" "$ver" "new image selection mode"

file_path="${tmp_dir}/debian10.qcow2"
system="debian10"
new_images=()
sys_tag_images=()
sys_family=""
ver=""
download_calls=()
download_x86_image >/dev/null
assert_eq "1" "${#download_calls[@]}" "legacy image download count"
assert_eq "https://github.com/oneclickvirt/kvm_images/releases/download/v1.1/debian10.qcow2" "${download_calls[0]}" "legacy image URL"
assert_eq "v1.1" "$ver" "legacy image selection mode"

assert_rejected() {
    local label="$1"
    shift
    if "$@"; then
        printf 'FAIL: %s was accepted\n' "$label" >&2
        exit 1
    fi
}

# Keep the selector independent of this runner's network.  The reported
# failure is an on-link public /64 whose otherwise-unused child prefix cannot
# be claimed by a bridge, so cover both addresses and connected routes here.
nat_ipv6_addresses=""
nat_ipv6_routes=""
ip() {
    case "$*" in
    "-o -6 addr show")
        printf '%s\n' "$nat_ipv6_addresses"
        ;;
    "-6 route show table all")
        printf '%s\n' "$nat_ipv6_routes"
        ;;
    *)
        command ip "$@"
        ;;
    esac
}

exercise_nat_ipv6_selector() {
    local config_file="$1" selector_name="$2"
    local state_dir="$tmp_dir/${selector_name}-state"
    # shellcheck source=/dev/null
    source "$config_file"
    _blue() { :; }
    _green() { :; }
    _red() { :; }
    _yellow() { :; }

    rm -rf -- "$state_dir"
    mkdir -p "$state_dir"
    export PVE_STATE_DIR="$state_dir"
    unset PVE_NAT_IPV6_SUBNET
    nat_ipv6_addresses='2: eth0    inet6 2605:52c0:2:14b:be24:11ff:fe6e:d967/64 scope global dynamic'
    nat_ipv6_routes=$'2605:52c0:2:14b::/64 dev eth0 proto kernel metric 256\n::/0 via fe80::6016:20ff:fe1a:d6dd dev eth0 metric 1024'

    load_nat_ipv6_config
    assert_eq "fd42:5339:296f:1f00::/64" "$pve_nat_ipv6_subnet" "${selector_name} automatic ULA subnet"
    assert_eq "fd42:5339:296f:1f00::1" "$pve_nat_ipv6_gateway" "${selector_name} automatic ULA gateway"
    assert_eq "fd42:5339:296f:1f00::64" "$(pve_nat_ipv6_for_id 100)" "${selector_name} guest ULA address"

    export PVE_NAT_IPV6_SUBNET='2605:52c0:2:14b:ffff:ffff:ffff:0/112'
    assert_rejected "${selector_name} public child prefix" load_nat_ipv6_config
    assert_eq "fd42:5339:296f:1f00::/64" "$(cat "$state_dir/pve_nat_ipv6_subnet")" "${selector_name} rejected public prefix preserves state"

    export PVE_NAT_IPV6_SUBNET='fd42:beef:1234:100::/64'
    nat_ipv6_routes=$'fd42:beef:1234::/48 dev eth0 proto static\n2605:52c0:2:14b::/64 dev eth0 proto kernel'
    assert_rejected "${selector_name} ULA child of host route" load_nat_ipv6_config

    unset PVE_NAT_IPV6_SUBNET
    printf '%s\n' 'fd42:5339:296f:1f07::/64' >"$state_dir/pve_nat_ipv6_subnet"
    nat_ipv6_addresses=$'2: eth0    inet6 2605:52c0:2:14b:be24:11ff:fe6e:d967/64 scope global dynamic\n10: vmbr1    inet6 fd42:5339:296f:1f07::1/64 scope global'
    nat_ipv6_routes=$'2605:52c0:2:14b::/64 dev eth0 proto kernel\nfd42:5339:296f:1f07::/64 dev vmbr1 proto kernel\nlocal fd42:5339:296f:1f07::1 dev vmbr1 table local'
    load_nat_ipv6_config
    assert_eq "fd42:5339:296f:1f07::/64" "$pve_nat_ipv6_subnet" "${selector_name} preserves active vmbr1 subnet"

    printf '%s\n' '2001:db8:1::/64' >"$state_dir/pve_nat_ipv6_subnet"
    nat_ipv6_addresses='2: eth0    inet6 2605:52c0:2:14b:be24:11ff:fe6e:d967/64 scope global dynamic'
    nat_ipv6_routes=$'2605:52c0:2:14b::/64 dev eth0 proto kernel\n::/0 via fe80::6016:20ff:fe1a:d6dd dev eth0 metric 1024'
    load_nat_ipv6_config
    assert_eq "fd42:5339:296f:1f00::/64" "$pve_nat_ipv6_subnet" "${selector_name} migrates legacy documentation subnet"
}

exercise_nat_ipv6_selector "${repo_root}/scripts/default_vm_config.sh" "VM"
exercise_nat_ipv6_selector "${repo_root}/scripts/default_ct_config.sh" "CT"

printf 'default VM image selection tests passed\n'
