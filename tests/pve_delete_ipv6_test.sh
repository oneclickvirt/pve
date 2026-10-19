#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delete_script="${repo_root}/scripts/pve_delete.sh"
tmp_dir=$(mktemp -d)
original_path=$PATH
rm_bin=$(command -v rm)
trap 'PATH="$original_path"; "$rm_bin" -rf -- "$tmp_dir"' EXIT

# pve_delete.sh is function-only when sourced, allowing the cleanup path to be
# exercised without invoking PVE commands or requiring root.
# shellcheck source=/dev/null
source "$delete_script"

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL: %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# Address prefixes must not select another guest's nft rule handles.
rules=$'ip6 daddr 2001:db8::d1 drop # handle 11\nip6 daddr 2001:db8::d10 drop # handle 12\nip6 saddr fd42::d1 snat to 2001:db8::901 # handle 13\nip6 saddr fd42::d10 snat to 2001:db8::9010 # handle 14'
assert_eq 11 "$(printf '%s\n' "$rules" | nft_ipv6_rule_handles 2001:db8::d1)" 'exact nft destination matching'
assert_eq 13 "$(printf '%s\n' "$rules" | nft_ipv6_rule_handles fd42::d1 2001:db8::901)" 'exact nft NAT matching'

fake_bin="${tmp_dir}/bin"
mkdir -p "$fake_bin"
ln -s "$(command -v python3)" "${fake_bin}/python3"
ln -s "$(command -v cat)" "${fake_bin}/cat"
ln -s "$(command -v sed)" "${fake_bin}/sed"
ln -s "$(command -v awk)" "${fake_bin}/awk"
export PVE_STATE_DIR="${tmp_dir}/state"
mkdir -p "$PVE_STATE_DIR"
PATH="$fake_bin"

ip6tables_calls=()
ip6tables() {
    ip6tables_calls+=("$*")
}
log() { :; }
FW_BACKEND=iptables

# shellcheck disable=SC2317 # Called indirectly by the sourced list_vm_ids helper.
qm() {
    case "${PVE_TEST_LIST_LAYOUT:-legacy}" in
        legacy)
            printf '%s\n' 'VMID NAME STATUS MEM(MB) BOOTDISK(GB) PID' '100 vm100 running 512 8.00 1234' '102 vm102 stopped 256 4.00 0'
            ;;
        modern)
            printf '%s\n' 'VMID STATUS NAME MEM(MB) BOOTDISK(GB) PID' '101 stopped vm101 256 4.00 0' '103 running vm103 1024 16.00 5678'
            ;;
        *) return 1 ;;
    esac
}
# shellcheck disable=SC2317 # Called indirectly by the sourced list_ct_ids helper.
pct() {
    case "${PVE_TEST_LIST_LAYOUT:-legacy}" in
        legacy)
            printf '%s\n' 'VMID STATUS LOCK' '200 running -' '202 stopped -'
            ;;
        modern)
            printf '%s\n' 'VMID STATUS NAME' '201 stopped ct201' '203 running ct203'
            ;;
        *) return 1 ;;
    esac
}
assert_eq $'100\n102' "$(list_vm_ids)" "legacy qm list IDs"
assert_eq $'200\n202' "$(list_ct_ids)" "legacy pct list IDs"
PVE_TEST_LIST_LAYOUT=modern
assert_eq $'101\n103' "$(list_vm_ids)" "modern qm list IDs"
assert_eq $'201\n203' "$(list_ct_ids)" "modern pct list IDs"
# shellcheck disable=SC2317 # The next indirect list_vm_ids call must propagate this failure.
qm() { return 1; }
if list_vm_ids; then
    printf 'qm list command failure was accepted\n' >&2
    exit 1
fi
unset -f qm pct

# A persisted /38 uses the builder's decimal VMID allocation and must remove
# the canonical delegated-prefix rule, not a host-address-derived /64 rule.
printf '%s\n' '2a14:7c0:1002:10f8::/38' >"${PVE_STATE_DIR}/pve_direct_ipv6_prefix"
printf '%s\n' '2a14:7c0:1002:10f8::1' >"${PVE_STATE_DIR}/pve_direct_ipv6_gateway"
printf '%s\n' '2a14:7c0:1002:ffff::1' >"${PVE_STATE_DIR}/pve_check_ipv6"
printf '%s\n' 64 >"${PVE_STATE_DIR}/pve_ipv6_prefixlen"
cleanup_vmbr2_icmpv6_rule 100 '2a14:7c0:1002:10f8::beef'
assert_eq 3 "${#ip6tables_calls[@]}" "persisted direct IPv6 deletion count"
assert_eq '-t raw -D PREROUTING -d 2a14:7c0:1002:10f8::64 -s 2a14:7c0:1000::/38 -p icmpv6 --icmpv6-type echo-request -j ACCEPT' "${ip6tables_calls[0]}" "persisted /38 canonical source deletion"
assert_eq '-t raw -D PREROUTING -d 2a14:7c0:1002:10f8::64 -s fe80::/10 -p icmpv6 --icmpv6-type echo-request -j ACCEPT' "${ip6tables_calls[1]}" "persisted /38 link-local deletion"
assert_eq '-t raw -D PREROUTING -d 2a14:7c0:1002:10f8::64 -p icmpv6 --icmpv6-type echo-request -j DROP' "${ip6tables_calls[2]}" "persisted /38 drop deletion"

# Keep the cleanup allocator aligned with creation for a small delegated
# prefix, where VMID 256 is reassigned around the bridge gateway.
printf '%s\n' '2a14:7c0:1002:3000::/120' >"${PVE_STATE_DIR}/pve_direct_ipv6_prefix"
printf '%s\n' '2a14:7c0:1002:3000::1' >"${PVE_STATE_DIR}/pve_direct_ipv6_gateway"
ip6tables_calls=()
cleanup_vmbr2_icmpv6_rule 256
assert_eq 3 "${#ip6tables_calls[@]}" "persisted /120 boundary deletion count"
assert_eq '-t raw -D PREROUTING -d 2a14:7c0:1002:3000::2 -s 2a14:7c0:1002:3000::/120 -p icmpv6 --icmpv6-type echo-request -j ACCEPT' "${ip6tables_calls[0]}" "persisted /120 boundary source deletion"

# Invalid persisted state must not fall back to a potentially unrelated host
# address and remove another guest's rules.
printf '%s\n' 'not-an-ipv6-prefix' >"${PVE_STATE_DIR}/pve_direct_ipv6_prefix"
ip6tables_calls=()
cleanup_vmbr2_icmpv6_rule 100 '2a14:7c0:1002:10f8::64'
assert_eq 0 "${#ip6tables_calls[@]}" "invalid direct state skips firewall deletion"

# A preserved vmbr2 can predate direct-prefix state while its VM/CT already
# uses the current decimal assignment. Its configured address is authoritative.
"$rm_bin" -f "${PVE_STATE_DIR}/pve_direct_ipv6_prefix" "${PVE_STATE_DIR}/pve_direct_ipv6_gateway"
printf '%s\n' '2a14:7c0:1002:10f8::1' >"${PVE_STATE_DIR}/pve_check_ipv6"
printf '%s\n' 38 >"${PVE_STATE_DIR}/pve_ipv6_prefixlen"
ip6tables_calls=()
cleanup_vmbr2_icmpv6_rule 100 '2a14:7c0:1002:10f8::64'
assert_eq 3 "${#ip6tables_calls[@]}" "configured legacy bridge deletion count"
assert_eq '-t raw -D PREROUTING -d 2a14:7c0:1002:10f8::64 -s 2a14:7c0:1000::/38 -p icmpv6 --icmpv6-type echo-request -j ACCEPT' "${ip6tables_calls[0]}" "configured legacy bridge canonical source deletion"

# Older installations without an inspectable guest configuration retain the
# historical host-derived address form, with a normalized source CIDR.
ip6tables_calls=()
cleanup_vmbr2_icmpv6_rule 100
assert_eq 3 "${#ip6tables_calls[@]}" "legacy host fallback deletion count"
assert_eq '-t raw -D PREROUTING -d 2a14:7c0:1002:10f8::100 -s 2a14:7c0:1000::/38 -p icmpv6 --icmpv6-type echo-request -j ACCEPT' "${ip6tables_calls[0]}" "legacy canonical source deletion"

assert_eq '2a14:7c0:1002:10f8::64' "$(extract_first_public_ipv6_from_config $'ipconfig0: ip6=fd42:5339:296f:1f00::64/64\nipconfig1: ip6=2a14:7c0:1002:10f8::64/128,gw6=2a14:7c0:1002:10f8::1')" "configured public IPv6 extraction"

# Full-NAT aliases are stored as comments beside the private cloud-init
# address.  Deletion must discover the alias as well, otherwise ocv_snat keeps
# forwarding traffic to a destroyed guest.
assert_eq '107.172.105.195' "$(extract_fullnat_ipv4_from_config $'ipconfig0: ip=172.16.1.204/24,gw=172.16.1.1\n# oneclickvirt-fullnat-ipv4 107.172.105.195')" "fullnat alias extraction"
assert_eq '' "$(extract_fullnat_ipv4_from_config $'ipconfig0: ip=172.16.1.204/24,gw=172.16.1.1\n# oneclickvirt-fullnat-ipv4 not-an-ip')" "invalid fullnat alias ignored"

printf '%s\n' '172.16.1.0/24' >"${tmp_dir}/nat-subnet"
export PVE_NAT_SUBNET_FILE="${tmp_dir}/nat-subnet"
assert_eq '172.16.1.204' "$(resolve_pve_nat_ipv4_for_id 204)" "NAT address derived from VMID"

printf 'pve delete IPv6 regression tests passed\n'
