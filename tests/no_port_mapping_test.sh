#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
public_ipv4=''
user_ip=172.16.1.150
pve_nat_prefix=172.16.1
vm_num=150
web1_port=0
web2_port=0
port_first=0
port_last=0
firewall_fail=false
_fw_add_dnat() {
    [ "$firewall_fail" != true ] || return 1
    printf '%s\n' "$*" >>"$test_dir/rules"
}
_fw_add_dnat_range() { printf '%s\n' "$*" >>"$test_dir/rules"; }
_fw_save() { :; }
for script in buildct.sh buildvm.sh; do
    eval "$(sed -n '/^setup_port_forwarding() {/,/^}/p' "$repo_root/scripts/$script")"
    : >"$test_dir/rules"
    sshn=0
    setup_port_forwarding
    [ ! -s "$test_dir/rules" ]
    sshn=40150
    setup_port_forwarding
    grep -Fqx 'vmbr0 tcp 40150 172.16.1.150:22' "$test_dir/rules"
    firewall_fail=true
    if setup_port_forwarding; then
        echo "$script hid a firewall write failure" >&2
        exit 1
    fi
    firewall_fail=false
done
printf 'CT and VM zero-port mode creates no DNAT and propagates firewall failures\n'
