#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
# shellcheck source=/dev/null
source "$repo_root/scripts/default_vm_config.sh"
vm_num=210
independent_ipv6_status=N
vm_external_ipv6=''
host_external_ipv6=''
pve_direct_ipv6_available=true
pve_direct_ipv6_prefix='2001:db8:1::/72'
pve_direct_ipv6_gateway='2001:db8:1::1'
pve_nat_ipv6_gateway='fd42:1::1'
pve_direct_ipv6_for_id() { [[ "${allocation_fails:-false}" != true ]] && echo '2001:db8:1::d2'; }
pve_nat_ipv6_for_id() { echo 'fd42:1::d2'; }
pve_nat66_ready() { [[ "${nat66_ready:-false}" == true ]]; }
# The sourced production functions call this fixture indirectly.
# shellcheck disable=SC2317
qm() { if [[ "$*" == *ip=manual* ]]; then echo "qm cloud-init rejects non-CIDR IPv4 manual" >&2; return 1; fi; printf '%s\n' "$*" >>"$test_dir/calls"; [[ "${pve_fails:-false}" != true ]]; }
pve_configure_vm_ipv6 0
grep -Fq -- '--ipconfig0 ip6=2001:db8:1::d2/72,gw6=2001:db8:1::1' "$test_dir/calls"
[[ "$independent_ipv6_status" == Y ]]
allocation_fails=true
: >"$test_dir/calls"
if pve_configure_vm_ipv6 1; then echo 'failed IPv6 allocation was accepted' >&2; exit 1; fi
[[ ! -s "$test_dir/calls" ]]
allocation_fails=false
pve_fails=true
if pve_configure_vm_ipv6 1; then echo 'PVE network failure was hidden' >&2; exit 1; fi
pve_fails=false
pve_direct_ipv6_available=false
if pve_configure_vm_ipv6 1; then echo 'missing NAT66 was accepted' >&2; exit 1; fi
nat66_ready=true
pve_configure_vm_ipv6 1
[[ "$independent_ipv6_status" == NAT66 && "$vm_external_ipv6" == 'fd42:1::d2' ]]
grep -Fq -- '--ipconfig1 ip6=fd42:1::d2/64,gw6=fd42:1::1' "$test_dir/calls"

# A rejected create must never import disks or mutate an existing guest.
extract() { sed -n "/^$2() {/,/^}/p" "$repo_root/scripts/$1"; }
sleep() { :; }
independent_ipv6=n
core=1
cpu_type=host
kvm_flag='--kvm 1'
system_arch=x86_64
for entrypoint in buildvm.sh buildvm_extra_ip.sh buildvm_fullnat_ip.sh buildvm_onlyv6.sh; do
    eval "$(extract "$entrypoint" create_vm)"
    : >"$test_dir/calls"
    pve_fails=true
    if create_vm; then echo "$entrypoint hid a rejected create" >&2; exit 1; fi
    [[ $(wc -l <"$test_dir/calls") -eq 1 ]]
done

# PVE treats a separate leading-hyphen password as another CLI option.
password='-sample secret'
user=root
pve_nat_prefix=172.16.1
pve_nat_gateway=172.16.1.1
user_ip=198.51.100.218
user_ip_range=27
gateway=198.51.100.193
memory=512
storage=local
independent_ipv6=n
pve_resize_vm_disk() { :; }
qm() {
    local argument
    for argument in "$@"; do
        [[ "$argument" != --cipassword ]] || return 1
        if [[ "$argument" == --cipassword=* ]]; then
            [[ "$argument" == '--cipassword=-sample secret' ]] || return 1
            printf '%s\n' accepted >>"$test_dir/password-calls"
        fi
    done
}
for entrypoint in buildvm.sh buildvm_extra_ip.sh buildvm_fullnat_ip.sh buildvm_manual_ip.sh; do
    function_name=configure_network
    [[ "$entrypoint" != buildvm_extra_ip.sh ]] || function_name=configure_vm
    eval "$(extract "$entrypoint" "$function_name")"
    "$function_name"
done
[[ $(wc -l <"$test_dir/password-calls") -eq 4 ]]

# A partial full-port NAT failure must keep its alias reserved for recovery.
PVE_VM_CONFIG_DIR="$test_dir/qemu"
mkdir -p "$PVE_VM_CONFIG_DIR"
touch "$PVE_VM_CONFIG_DIR/$vm_num.conf"
extranet_ipv4=198.51.100.218
_fw_add_full_dnat() { return 1; }
eval "$(extract buildvm_fullnat_ip.sh setup_firewall)"
if setup_firewall; then echo 'full NAT firewall failure was hidden' >&2; exit 1; fi
grep -Fxq '# oneclickvirt-fullnat-ipv4 198.51.100.218' "$PVE_VM_CONFIG_DIR/$vm_num.conf"

# Specific SNAT uses a hook earlier than generic priority-100 MASQUERADE.
_use_nft() { return 0; }
_nft_init() { :; }
nft() { printf '%s\n' "$*" >>"$test_dir/nft"; [[ "$1" != list ]]; }
_fw_add_snat '172.16.1.210' vmbr0 '198.51.100.218'
_fw6_add_snat 'fd42:1::d2' '2001:db8:1::d2'
[[ $(grep -c 'priority 90' "$test_dir/nft") -eq 2 ]]
grep -Fq 'insert rule ip nat ocv_snat' "$test_dir/nft"
grep -Fq 'insert rule ip6 nat ocv_snat' "$test_dir/nft"
printf 'VM IPv6, failure propagation and specific-SNAT priority tests passed\n'
