#!/usr/bin/env bash
set -euo pipefail

script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/build_nat_network.sh
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
extract_function() { sed -n "/^${1}() {/,/^}/p" "$script"; }
eval "$(extract_function setup_firewall)"

_green() { :; }
_yellow() { :; }
update_sysctl() { :; }
systemctl() { :; }
# The live route can still use eth0 during first install; vmbr0 is the
# post-install uplink that must be persisted in the NAT66 rule.
pve_ipv6_json_probe() { [ "$1" = default_interface ] && printf 'eth0\n'; }
pve_ipv6_uplink_interface() { printf 'vmbr0\n'; }
validate_interface_value() { [ "$1" = vmbr0 ]; }
sysctl_path=true
nat_ipv4_subnet='172.16.1.0/24'
nat_ipv6_subnet='fd42:5339:296f:1f00::/64'
PVE_NFTABLES_CONF="$tmp_dir/nftables.conf"
added=0
nft() {
    case "$*" in
        'list tables') printf 'table ip nat\ntable ip6 nat\n' ;;
        'list chain ip nat postrouting') printf 'ip saddr 172.16.1.0/24 oifname "vmbr0" masquerade\n' ;;
        'list chain ip6 nat postrouting')
            if [ "$added" -gt 0 ]; then
                printf 'ip6 saddr fd42:5339:296f:1f00::/64 oifname "vmbr0" masquerade\n'
            fi
            ;;
        'add rule ip6 nat postrouting ip6 saddr fd42:5339:296f:1f00::/64 oifname vmbr0 masquerade')
            added=$((added + 1))
            ;;
        'list ruleset')
            printf 'table ip6 nat { chain postrouting { ip6 saddr fd42:5339:296f:1f00::/64 oifname "vmbr0" masquerade } }\n'
            ;;
        *) : ;;
    esac
}

setup_firewall
setup_firewall
[ "$added" -eq 1 ] || { echo "NAT66 rule added $added times" >&2; exit 1; }
grep -Fq 'ip6 saddr fd42:5339:296f:1f00::/64 oifname "vmbr0" masquerade' "$PVE_NFTABLES_CONF"
