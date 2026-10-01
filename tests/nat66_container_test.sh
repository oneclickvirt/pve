#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

extract_function() { sed -n "/^${2}() {/,/^}/p" "$1"; }
eval "$(extract_function "$repo_root/scripts/default_ct_config.sh" pve_nat66_ready)"
eval "$(extract_function "$repo_root/scripts/default_ct_config.sh" check_ipv6_setup)"
eval "$(extract_function "$repo_root/scripts/buildct.sh" configure_networking)"

_green() { :; }
_red() { :; }
_yellow() { :; }
sleep() { :; }
sysctl() { [ "$*" = '-n net.ipv6.conf.all.forwarding' ] && printf '1\n'; }
ip() {
    case "$*" in
        '-j -6 route show default') printf '\033[36m[{"dst":"default","gateway":"fe80::1","dev":"vmbr0"}]\033[0m\n' ;;
        '-j -6 addr show scope global') printf '\033[32m[{"ifname":"vmbr0","addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::1","prefixlen":%s,"scope":"global"}]}]\033[0m\n' "$host_prefix" ;;
        *) return 1 ;;
    esac
}
nft() {
    [ "$*" = 'list chain ip6 nat postrouting' ] || return 1
    [ "$rule_present" = true ] || return 1
    printf 'table ip6 nat { chain postrouting { ip6 saddr %s oifname "vmbr0" masquerade } }\n' "$pve_nat_ipv6_subnet"
}
ip6tables() { return 1; }

pve_nat_ipv6_subnet='fd42:5339:296f:1f00::/64'
pve_nat_ipv6_gateway='fd42:5339:296f:1f00::1'
rule_present=true
for host_prefix in 38 64 120 128; do
    pve_nat66_ready || { echo "NAT66 rejected a host /${host_prefix}" >&2; exit 1; }
done
rule_present=false
if pve_nat66_ready; then
    echo 'NAT66 accepted a missing egress rule' >&2
    exit 1
fi

independent_ipv6=y
pve_direct_ipv6_available=false
if check_ipv6_setup >/dev/null 2>&1; then
    echo 'IPv6 request silently fell back to IPv4 without NAT66' >&2
    exit 1
fi

rule_present=true
check_ipv6_setup >/dev/null
CTID=102
user_ip='172.16.1.102'
pve_nat_gateway='172.16.1.1'
pct() { printf '%s\n' "$*" >>"$tmp_dir/pct.log"; }
pve_nat_ipv6_for_id() { printf 'fd42:5339:296f:1f00::66\n'; }
configure_networking >"$tmp_dir/output.log"
[ "$independent_ipv6_status" = NAT66 ]
grep -Fq 'ip6=fd42:5339:296f:1f00::66/64' "$tmp_dir/pct.log"
grep -Fq 'shared public egress' "$tmp_dir/output.log"
if grep -Fq '2a01:4f8:c014:1a63::1' "$tmp_dir/pct.log"; then
    echo 'container took the host IPv6 address' >&2
    exit 1
fi
