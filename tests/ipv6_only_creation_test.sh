#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
extract() { sed -n "/^$2() {/,/^}/p" "$repo_root/scripts/$1"; }
export PVE_CT_CONFIG_DIR="$test_dir/lxc"
export PVE_CT_METADATA_DIR="$test_dir/records"
export PVE_GUEST_METADATA_DIR="$test_dir/records"
export PVE_VM_CONFIG_DIR="$test_dir/qemu"
mkdir -p "$PVE_CT_CONFIG_DIR" "$PVE_CT_METADATA_DIR" "$PVE_VM_CONFIG_DIR"
eval "$(extract default_ct_config.sh pve_configure_ct_dns)"
eval "$(extract default_ct_config.sh pve_validate_guest_metadata)"
eval "$(extract default_ct_config.sh pve_save_guest_record)"
eval "$(extract buildct_onlyv6.sh create_container)"
eval "$(extract buildct_onlyv6.sh init)"
validate_storage_name() { :; }
sleep() { :; }
pve_prepare_ct_template() { [[ "${template_broken:-false}" != true ]]; }
pve_direct_ipv6_for_id() { echo '2001:db8:1::a0'; }
pve_direct_ipv6_bridge() { echo vmbr2; }
_fw6_drop_icmpv6_ping() { :; }
_fw_save() { :; }
pct() {
    if [[ "$1" == create ]]; then
        [[ "$(umask)" == 0022 ]] || { echo 'unsafe LXC extraction umask' >&2; return 1; }
        local argument found=false
        for argument in "$@"; do
            [[ "$argument" != --password ]] || { echo 'password can be parsed as a CLI option' >&2; return 1; }
            [[ "$argument" != '--password=-sample-secret' ]] || found=true
        done
        [[ "$found" == true ]] || return 1
        touch "$PVE_CT_CONFIG_DIR/$2.conf"
    fi
    printf '%s\n' "$*" >>"$test_dir/calls"
}
init 160 -sample-secret 1 512 5 debian12 local
fixed_system=true
system_name=example.tar.zst
pve_nat_prefix=172.16.1
pve_direct_ipv6_available=true
pve_direct_ipv6_prefix='2001:db8:1::/72'
pve_direct_ipv6_gateway='2001:db8:1::1'
umask 077
create_container
[[ "$(umask)" == 0077 ]]
if grep -Eq -- '--net1|ip=[0-9]+\.' "$test_dir/calls"; then echo 'IPv6-only CT has an IPv4 NIC' >&2; exit 1; fi
grep -Fq -- 'ip6=2001:db8:1::a0/72' "$test_dir/calls"
grep -Fq 'start 160' "$test_dir/calls"
grep -Fq -- '--nameserver 2606:4700:4700::1111 2001:4860:4860::8888' "$test_dir/calls"
grep -Fq '/etc/resolv.conf' "$test_dir/calls"
: >"$test_dir/calls"
template_broken=true
if create_container; then echo 'corrupt template was accepted' >&2; exit 1; fi
[[ ! -s "$test_dir/calls" ]]
record='160 -sample-secret 1 512 5 debian12 local 2001:db8:1::a0'
pve_save_guest_record ct 160 "$record" 'CTID root密码-password CPU Memory Disk System Storage IPv6' >"$test_dir/output"
if grep -Fq -- -sample-secret "$test_dir/output" "$PVE_CT_CONFIG_DIR/160.conf"; then echo 'guest secret leaked into output or PVE config' >&2; exit 1; fi
if init 160 other 1 512 5 debian12 local >/dev/null 2>&1; then echo 'existing metadata accepted' >&2; exit 1; fi
[[ "$(cat "$PVE_CT_METADATA_DIR/ct160")" == "$record" ]]
# VM must attach the IPv6 bridge as its sole NIC and use ipconfig0.
eval "$(extract buildvm_onlyv6.sh create_vm)"
qm() { printf '%s\n' "$*" >>"$test_dir/vm-calls"; }
vm_num=161
system_arch=x86_64
cpu_type=host
kvm_flag=''
appended_file="$test_dir/missing"
create_vm
if grep -Fq -- '--net1' "$test_dir/vm-calls"; then echo 'IPv6-only VM has a second NIC' >&2; exit 1; fi
grep -Fq -- '--net0 virtio,bridge=vmbr2' "$test_dir/vm-calls"
# The pure-IPv6 VM entrypoint accepts NAT66 only when its forwarding is ready.
eval "$(extract buildvm_onlyv6.sh check_environment)"
export PVE_IPV6_MAPPING_FILE="$test_dir/no-mapping"
pve_direct_ipv6_available=false
pve_nat66_ready() { [[ "${nat66_ready:-false}" == true ]]; }
_red() { :; }
_yellow() { :; }
if (check_environment); then echo 'missing NAT66 was accepted by pure-IPv6 VM' >&2; exit 1; fi
nat66_ready=true
check_environment
if grep -Eq 'crontab -|--ipconfig[01] ip=\$\{user_ip\}|--net1 name=eth1,ip=' "$repo_root/scripts/buildct_onlyv6.sh" "$repo_root/scripts/buildvm_onlyv6.sh"; then echo 'IPv6-only entrypoint retains IPv4 or host crontab mutation' >&2; exit 1; fi
# The ignored resolver in an older template must be replaced, and errors
# from either the PVE property update or the guest write must fail creation.
for fail_at in set exec; do
    pct() { [[ "$1" != "$fail_at" ]]; }
    if pve_configure_ct_dns 6; then echo "DNS $fail_at failure was ignored" >&2; exit 1; fi
done
printf 'IPv6-only creation, address prefix and private metadata tests passed\n'
