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

# These stubs are called by functions loaded from the sourced configuration.
# shellcheck disable=SC2317
_blue() { :; }
# shellcheck disable=SC2317
_red() { :; }
# shellcheck disable=SC2317
_yellow() { :; }
# The configuration helpers intentionally expose these values as global state.
# Initialize them here so ShellCheck can follow the test contract across the
# indirect source call.
pve_nat_ipv6_subnet=""
pve_nat_ipv6_gateway=""
pve_direct_ipv6_available=false
pve_direct_ipv6_prefix=""
pve_direct_ipv6_gateway=""
pve_direct_ipv6_upstream_gateway=""
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
direct_ipv6_addresses=""
direct_ipv6_bridge_present=false
ip() {
    case "$*" in
    "-o -6 addr show dev "*)
        printf '%s\n' "$direct_ipv6_addresses"
        ;;
    "-o -6 addr show")
        printf '%s\n' "$nat_ipv6_addresses"
        ;;
    "-6 route show table all")
        printf '%s\n' "$nat_ipv6_routes"
        ;;
    "link show "*)
        "$direct_ipv6_bridge_present"
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
    # shellcheck disable=SC2317
    _blue() { :; }
    # shellcheck disable=SC2317
    _green() { :; }
    # shellcheck disable=SC2317
    _red() { :; }
    # shellcheck disable=SC2317
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

exercise_direct_ipv6_config() {
    local config_file="$1" selector_name="$2"
    local state_dir="$tmp_dir/${selector_name}-direct-state"
    local interfaces_file="$tmp_dir/${selector_name}-interfaces"

    # shellcheck source=/dev/null
    source "$config_file"
    _blue() { :; }
    _green() { :; }
    _red() { :; }
    _yellow() { :; }

    rm -rf -- "$state_dir"
    mkdir -p "$state_dir"
    : >"$interfaces_file"
    export PVE_STATE_DIR="$state_dir"
    export PVE_NETWORK_INTERFACES_FILE="$interfaces_file"
    unset PVE_IPV6_ROUTED_PREFIX PVE_IPV6_DIRECT_GATEWAY PVE_IPV6_DIRECT_MODE
    unset PVE_IPV6_BRIDGE_GATEWAY PVE_IPV6_DIRECT_BRIDGE PVE_IPV6_DIRECT_TRANSPORT

    # A historical vmbr2 /38 remains valid. This is the non-nibble-prefix
    # bridge form reported by the existing PVE deployment.
    cat >"$interfaces_file" <<'EOF'
auto vmbr2
iface vmbr2 inet6 static
    address 2a14:7c0:1002:10f8::1/38
EOF
    direct_ipv6_addresses='10: vmbr2    inet6 2a14:7c0:1002:10f8::1/38 scope global'
    direct_ipv6_bridge_present=true
    pve_load_direct_ipv6_config
    assert_eq "true" "$pve_direct_ipv6_available" "${selector_name} legacy /38 direct bridge"
    assert_eq "2a14:7c0:1000::/38" "$pve_direct_ipv6_prefix" "${selector_name} normalizes non-nibble prefix"
    assert_eq "2a14:7c0:1002:10f8::1" "$pve_direct_ipv6_gateway" "${selector_name} legacy bridge gateway"
    assert_eq "vmbr2" "$(pve_direct_ipv6_bridge)" "${selector_name} legacy direct bridge name"
    assert_eq "2a14:7c0:1002:10f8::64" "$(pve_direct_ipv6_for_id 100)" "${selector_name} /38 guest address"

    # A plain SLAAC /64 on the uplink does not imply a delegated guest prefix.
    rm -rf -- "$state_dir"
    mkdir -p "$state_dir"
    cat >"$interfaces_file" <<'EOF'
auto eth0
iface eth0 inet dhcp
EOF
    direct_ipv6_addresses='2: eth0    inet6 2605:52c0:2:14b:be24:11ff:fe6e:d967/64 scope global dynamic'
    direct_ipv6_bridge_present=false
    pve_load_direct_ipv6_config
    assert_eq "false" "$pve_direct_ipv6_available" "${selector_name} SLAAC /64 remains NAT66"

    # A host-only /128 also cannot provide distinct guest addresses.
    direct_ipv6_addresses=""
    export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:10f8::1/128'
    export PVE_IPV6_DIRECT_GATEWAY='2a14:7c0:1002:10f8::1'
    export PVE_IPV6_DIRECT_MODE=ndp
    assert_rejected "${selector_name} /128 direct prefix" pve_load_direct_ipv6_config
    assert_eq "false" "$pve_direct_ipv6_available" "${selector_name} /128 leaves direct mode disabled"

    # A /127 cannot accommodate PVE's supported 100-256 guest ID range.
    export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:10f8::/127'
    export PVE_IPV6_DIRECT_GATEWAY='2a14:7c0:1002:10f8::1'
    assert_rejected "${selector_name} /127 direct prefix" pve_load_direct_ipv6_config
    assert_eq "false" "$pve_direct_ipv6_available" "${selector_name} /127 leaves direct mode disabled"

    # A /120 has room for every supported guest ID. Preserve established
    # addresses where possible and allocate ID 256 from the unused low range.
    export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:3000::/120'
    export PVE_IPV6_DIRECT_GATEWAY='2a14:7c0:1002:3000::1'
    export PVE_IPV6_DIRECT_MODE=ndp
    pve_load_direct_ipv6_config
    assert_eq "true" "$pve_direct_ipv6_available" "${selector_name} /120 direct prefix"
    assert_eq "2a14:7c0:1002:3000::64" "$(pve_direct_ipv6_for_id 100)" "${selector_name} /120 first guest address"
    assert_eq "2a14:7c0:1002:3000::ff" "$(pve_direct_ipv6_for_id 255)" "${selector_name} /120 last historical guest address"
    assert_eq "2a14:7c0:1002:3000::2" "$(pve_direct_ipv6_for_id 256)" "${selector_name} /120 boundary guest address"

    # A configured bridge gateway may itself use a historical guest-numbered
    # address. Reassign only that guest to avoid a duplicate assignment.
    export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:3100::/64'
    export PVE_IPV6_DIRECT_GATEWAY='2a14:7c0:1002:3100::64'
    pve_load_direct_ipv6_config
    assert_eq "2a14:7c0:1002:3100::1" "$(pve_direct_ipv6_for_id 100)" "${selector_name} gateway collision guest address"
    assert_eq "2a14:7c0:1002:3100::65" "$(pve_direct_ipv6_for_id 101)" "${selector_name} gateway collision preserves other guest"

    # A routed prefix may use a link-local upstream gateway. Guests use the
    # bridge address inside their own routed prefix instead of that fe80 next hop.
    export PVE_IPV6_ROUTED_PREFIX='2a14:7c0:1002:2000::/64'
    export PVE_IPV6_DIRECT_GATEWAY='fe80::1'
    export PVE_IPV6_DIRECT_MODE=routed
    export PVE_IPV6_DIRECT_BRIDGE=vmbr9
    unset PVE_IPV6_BRIDGE_GATEWAY
    pve_load_direct_ipv6_config
    assert_eq "true" "$pve_direct_ipv6_available" "${selector_name} routed link-local gateway"
    assert_eq "2a14:7c0:1002:2000::1" "$pve_direct_ipv6_gateway" "${selector_name} routed guest bridge gateway"
    assert_eq "fe80::1" "$pve_direct_ipv6_upstream_gateway" "${selector_name} routed upstream gateway"
    assert_eq "vmbr9" "$(pve_direct_ipv6_bridge)" "${selector_name} custom direct bridge"
    assert_eq "2a14:7c0:1002:2000::64" "$(pve_direct_ipv6_for_id 100)" "${selector_name} routed guest address"

    # The tunnel marker keeps NDP mandatory even when the prefix itself is
    # routed, matching HE/6in4 deployments.
    printf '%s\n' tunnel >"$state_dir/pve_direct_ipv6_transport"
    cat >>"$interfaces_file" <<'EOF'
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
EOF
    pve_load_direct_ipv6_config
    if ! pve_direct_ipv6_ndp_required; then
        printf 'FAIL: %s tunnel direct IPv6 did not require NDP\n' "$selector_name" >&2
        exit 1
    fi

    unset PVE_IPV6_ROUTED_PREFIX PVE_IPV6_DIRECT_GATEWAY PVE_IPV6_DIRECT_MODE
    unset PVE_IPV6_BRIDGE_GATEWAY PVE_IPV6_DIRECT_BRIDGE PVE_IPV6_DIRECT_TRANSPORT
}

exercise_direct_ipv6_config "${repo_root}/scripts/default_vm_config.sh" "VM"
exercise_direct_ipv6_config "${repo_root}/scripts/default_ct_config.sh" "CT"

printf 'default configuration tests passed\n'
