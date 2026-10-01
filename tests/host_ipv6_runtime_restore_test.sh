#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/build_nat_network.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

extract_function() {
    sed -n "/^$1() {/,/^}/p" "$script"
}

eval "$(extract_function is_single_network_value)"
eval "$(extract_function validate_prefixlen_value)"
eval "$(extract_function validate_ipv6_value)"
eval "$(extract_function validate_ipv6_prefixlen_value)"
eval "$(extract_function validate_interface_value)"
eval "$(extract_function pve_ipv6_json_probe)"
eval "$(extract_function pve_capture_host_ipv6_runtime)"
eval "$(extract_function restore_host_ipv6_runtime)"
eval "$(extract_function restart_network_services)"

export PVE_TEST_SCENARIO=multiple
export PVE_TEST_COMMAND_LOG="$test_dir/commands"
export PVE_TEST_IP_LOG="$test_dir/ip-env"
export PVE_IPV6_PROBE_IP="$test_dir/ip"

cat >"$PVE_IPV6_PROBE_IP" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${LC_ALL:-}" "${NO_COLOR:-}" "$*" >>"$PVE_TEST_IP_LOG"
case "$*" in
    '-j -6 route show default')
        case "$PVE_TEST_SCENARIO" in
            no-route) printf '%s\n' '[]' ;;
            direct-route) printf '%s\n' '[{"dst":"default","dev":"eth0"}]' ;;
            multipath) printf '%s\n' '[{"dst":"default","metric":100,"nexthops":[{"gateway":"fe80::1","dev":"eth0","weight":2},{"gateway":"fe80::2","dev":"eth1","weight":1}]}]' ;;
            *) printf '\033[32m%s\033[0m\n' '[{"dst":"default","gateway":"fe80::1","dev":"eth0","metric":100},{"dst":"default","gateway":"fe80::2","dev":"eth1","metric":200}]' ;;
        esac
        ;;
    '-j -6 addr show')
        printf '\033[36m%s\033[0m\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a01:4f8:1234::1","prefixlen":38,"scope":"global"},{"family":"inet6","local":"2a01:4f8:1234::2","prefixlen":127,"scope":"global"},{"family":"inet6","local":"2a01:4f8:1234::3","prefixlen":128,"scope":"global"}]},{"ifname":"eth1","addr_info":[{"family":"inet6","local":"2a01:4f8:5678::1","prefixlen":56,"scope":"global"}]}]'
        ;;
    '-6 addr replace '*|'-6 route replace '*) printf '%s\n' "$*" >>"$PVE_TEST_COMMAND_LOG" ;;
    *) exit 2 ;;
esac
EOF
chmod 700 "$PVE_IPV6_PROBE_IP"

ip() { "$PVE_IPV6_PROBE_IP" "$@"; }
sysctl() { return 1; }
pve_ipv6_uplink_interface() { printf '%s\n' vmbr0; }

pve_capture_host_ipv6_runtime
[ "$host_ipv6_runtime_cidrs" = $'2a01:4f8:1234::1/38\n2a01:4f8:1234::2/127\n2a01:4f8:1234::3/128\n2a01:4f8:5678::1/56' ]
[ "$host_ipv6_runtime_address_bindings" = $'eth0\t2a01:4f8:1234::1/38\neth0\t2a01:4f8:1234::2/127\neth0\t2a01:4f8:1234::3/128\neth1\t2a01:4f8:5678::1/56' ]
[ "$host_ipv6_runtime_gateway" = fe80::1 ]
[ "$host_ipv6_runtime_has_default_route" = true ]
[ "$(awk -F'|' 'NR == 1 {print $1 ":" $2}' "$PVE_TEST_IP_LOG")" = C:1 ]
# shellcheck disable=SC2218 # The initial implementation is loaded dynamically above.
restore_host_ipv6_runtime
for expected in \
    '-6 addr replace 2a01:4f8:1234::1/38 dev vmbr0' \
    '-6 addr replace 2a01:4f8:1234::2/127 dev vmbr0' \
    '-6 addr replace 2a01:4f8:1234::3/128 dev vmbr0' \
    '-6 addr replace 2a01:4f8:5678::1/56 dev eth1' \
    '-6 route replace default via fe80::1 dev vmbr0 onlink metric 100' \
    '-6 route replace default via fe80::2 dev eth1 onlink metric 200'; do
    grep -Fxq -- "$expected" "$PVE_TEST_COMMAND_LOG"
done

: >"$PVE_TEST_COMMAND_LOG"
PVE_TEST_SCENARIO=direct-route pve_capture_host_ipv6_runtime
# shellcheck disable=SC2218 # The initial implementation is loaded dynamically above.
restore_host_ipv6_runtime
grep -Fxq -- '-6 route replace default dev vmbr0' "$PVE_TEST_COMMAND_LOG"

: >"$PVE_TEST_COMMAND_LOG"
PVE_TEST_SCENARIO=no-route pve_capture_host_ipv6_runtime
# shellcheck disable=SC2218 # The initial implementation is loaded dynamically above.
restore_host_ipv6_runtime
if grep -Fq -- '-6 route replace default' "$PVE_TEST_COMMAND_LOG"; then
    echo 'unexpected default route was added when the host had none' >&2
    exit 1
fi

: >"$PVE_TEST_COMMAND_LOG"
PVE_TEST_SCENARIO=multipath pve_capture_host_ipv6_runtime
# shellcheck disable=SC2218 # The initial implementation is loaded dynamically above.
restore_host_ipv6_runtime
grep -Fxq -- '-6 route replace default metric 100 nexthop via fe80::1 dev vmbr0 weight 2 onlink nexthop via fe80::2 dev eth1 weight 1 onlink' "$PVE_TEST_COMMAND_LOG"

service() { :; }
systemctl() { :; }
ifreload() { :; }
sleep() { :; }
_red() { :; }
restore_host_ipv6_runtime() { return 1; }
post_restore_called=false
nft() { post_restore_called=true; return 1; }
iptables-save() { post_restore_called=true; return 0; }
iptables-restore() { post_restore_called=true; return 0; }
if restart_network_services >/dev/null 2>&1; then
    echo 'network reload succeeded after host IPv6 restoration failed' >&2
    exit 1
fi
[ "$post_restore_called" = false ] || {
    echo 'network reload continued after host IPv6 restoration failed' >&2
    exit 1
}
grep -Fq 'setup_firewall || exit 1' "$script"
grep -Fq 'restart_network_services || exit 1' "$script"

echo 'Host IPv6 runtime snapshot and restoration tests passed'
