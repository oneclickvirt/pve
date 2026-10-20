#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
extract() { sed -n "/^$1() {/,/^}/p" "$repo_root/scripts/buildct.sh"; }
eval "$(extract prepare_ipv4_network)"
eval "$(extract configure_networking)"
eval "$(extract setup_port_forwarding)"
allocator_fail=false
pve_public_ipv4_config() {
    [ "$allocator_fail" != true ] || return 1
    [ "$1" = manual ] && [ "$2" = 198.51.100.195/27 ]
    user_ip=198.51.100.195
    user_ip_range=27
    gateway=198.51.100.193
}
ct_ipv4_prefix=''
ct_ipv4_gateway=''
ct_ipv4_bridge=''
sshn=''
CTID=150
pve_nat_gateway=172.16.1.1
pve_nat_prefix=172.16.1
public_ipv4=198.51.100.195/27
prepare_ipv4_network
[ "$ct_ipv4_prefix" = 27 ] && [ "$ct_ipv4_gateway" = 198.51.100.193 ] && [ "$sshn" = 22 ]
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
pct() { printf '%s\n' "$*" >>"$test_dir/commands"; }
sleep() { :; }
_fw6_drop_icmpv6_ping() { :; }
_fw_save() { :; }
_fw_add_dnat() { echo 'dedicated IPv4 must not create NAT' >&2; return 1; }
pve_direct_ipv6_for_id() { printf '2001:db8:1:2:100::96\n'; }
pve_direct_ipv6_bridge() { printf 'vmbr2\n'; }
pve_direct_ipv6_prefix=2001:db8:1:2:100::/72
pve_direct_ipv6_gateway=2001:db8:1:2:100::1
pve_direct_ipv6_available=true
independent_ipv6=y
configure_networking
setup_port_forwarding
grep -Fq 'name=eth0,ip=198.51.100.195/27,bridge=vmbr0,gw=198.51.100.193' "$test_dir/commands"
grep -Fq 'name=eth1,ip6=2001:db8:1:2:100::96/72,bridge=vmbr2,gw6=2001:db8:1:2:100::1' "$test_dir/commands"
public_ipv4=''
prepare_ipv4_network
[ "$user_ip" = 172.16.1.150 ] && [ "$ct_ipv4_prefix" = 24 ] && [ "$ct_ipv4_bridge" = vmbr1 ]
# A failed allocation must abort before pct create, without a NAT fallback.
allocator_fail=true
public_ipv4=198.51.100.195/27
if prepare_ipv4_network; then exit 1; fi
printf 'LXC dedicated dual-stack preserves bridge, actual IPv4/IPv6 prefixes and NAT compatibility\n'
