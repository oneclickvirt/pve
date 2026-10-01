#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/install_pve.sh"
nat_script="$repo_root/scripts/build_nat_network.sh"
kernel_script="$repo_root/scripts/check_kernal.sh"
live_test="$repo_root/tests/live_host_ipv6_allocation_test.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

extract_function() {
    sed -n "/^$1() {/,/^}/p" "$installer"
}
eval "$(extract_function pve_ipv6_json_probe)"
eval "$(extract_function rebuild_ipv6_address)"
eval "$(extract_function is_single_network_value)"
eval "$(extract_function validate_ipv6_value)"
eval "$(sed -n '/^host_snapshot() {/,/^}/p' "$live_test")"
install_probe=$(extract_function pve_ipv6_json_probe)
nat_probe=$(sed -n '/^pve_ipv6_json_probe() {/,/^}/p' "$nat_script")
[ "$install_probe" = "$nat_probe" ] || { printf 'PVE installers use different IPv6 probes\n' >&2; exit 1; }
kernel_probe=$(sed -n '/^pve_ipv6_json_probe() {/,/^}/p' "$kernel_script")
[ "$install_probe" = "$kernel_probe" ] || { printf 'PVE kernel check uses a different IPv6 probe\n' >&2; exit 1; }

cat >"$test_dir/ip" <<'EOF'
#!/usr/bin/env bash
if [ "${LC_ALL:-}" != C ] || [ "${NO_COLOR:-}" != 1 ]; then
    printf 'IPv6 probe did not force C locale and no-color output\n' >&2
    exit 2
fi
case "$*" in
    '-j -6 addr show')
        if [ "${PVE_PROBE_SCENARIO:-}" = malformed ]; then
            printf '\033[31mUngültige IPv6-Adresse\033[0m\n'
        elif [ "${PVE_PROBE_SCENARIO:-}" = narrow127 ]; then
            printf '%s\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::8","prefixlen":127,"scope":"global"}]}]'
        elif [ "${PVE_PROBE_SCENARIO:-}" = hostonly ]; then
            printf '%s\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::8","prefixlen":128,"scope":"global"}]}]'
        else
            printf '\033[32m%s\033[0m\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::1","prefixlen":120,"scope":"global"},{"family":"inet6","local":"fe80::1234","prefixlen":64,"scope":"link"}]},{"ifname":"vmbr2","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:10f8::1","prefixlen":38,"scope":"global"},{"family":"inet6","local":"2a14:7c0:1002:10f8::1","prefixlen":128,"scope":"global","flags":["tentative"]}]}]'
        fi
        ;;
    '-j -6 route show default')
        printf '\033[36m%s\033[0m\n' '[{"dst":"default","gateway":"fe80::1","dev":"eth0"}]'
        ;;
    '-d -j link show')
        printf '%s\n' '[{"ifname":"lo"},{"ifname":"eth0"},{"ifname":"vmbr2","linkinfo":{"info_kind":"bridge"}},{"ifname":"veth0","linkinfo":{"info_kind":"veth"}}]'
        ;;
    *) exit 2 ;;
esac
EOF
chmod 700 "$test_dir/ip"
export PATH="$test_dir:$PATH"

[ "$(pve_ipv6_json_probe addresses eth0)" = '2a01:4f8:c014:1a63::1/120' ]
[ "$(pve_ipv6_json_probe addresses vmbr2)" = '2a14:7c0:1002:10f8::1/38' ]
[ "$(pve_ipv6_json_probe gateway eth0)" = 'fe80::1' ]
[ "$(pve_ipv6_json_probe linklocal eth0)" = 'fe80::1234/64' ]
[ "$(pve_ipv6_json_probe default_interface)" = 'eth0' ]
[ "$(pve_ipv6_json_probe interfaces)" = 'eth0' ]
[ "$(PVE_PROBE_SCENARIO=narrow127 pve_ipv6_json_probe addresses eth0)" = '2a01:4f8:c014:1a63::8/127' ]
[ "$(PVE_PROBE_SCENARIO=hostonly pve_ipv6_json_probe addresses eth0)" = '2a01:4f8:c014:1a63::8/128' ]
if PVE_PROBE_SCENARIO=malformed pve_ipv6_json_probe addresses eth0 >/dev/null 2>&1; then
    printf 'localized diagnostic was accepted as iproute2 JSON\n' >&2
    exit 1
fi

snapshot=$(host_snapshot)
SNAPSHOT="$snapshot" python3 - <<'PY'
import json
import os

addresses, routes = json.loads(os.environ['SNAPSHOT'])
assert addresses == [
    ['eth0', '2a01:4f8:c014:1a63::1', 120],
    ['vmbr2', '2a14:7c0:1002:10f8::1', 38],
]
assert routes == [['eth0', 'fe80::1', 'default']]
PY

ipv6_address='2a01:4f8:c014:1a63::42'
rebuild_ipv6_address
[ "$ipv6_address" = '2a01:4f8:c014:1a63::42' ] || exit 1
printf 'PVE IPv6 JSON and host address preservation tests passed\n'
