#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
script="$repo_root/scripts/build_nat_network.sh"
for function_name in pve_interfaces_probe pve_auto_direct_ipv6_config pve_require_writable_network_file pve_append_network_config pve_direct_ipv6_normalize; do
    eval "$(sed -n "/^${function_name}() {/,/^}/p" "$script")"
done
_red() { :; }
assert_eq() {
    [[ "$1" == "$2" ]] || { printf 'FAIL: %s: expected %s, got %s\n' "$3" "$1" "$2" >&2; exit 1; }
}
assert_rejected() {
    if "$@" >/dev/null 2>&1; then
        printf 'FAIL: accepted unsafe configuration: %s\n' "$*" >&2
        exit 1
    fi
}

export PVE_NETWORK_INTERFACES_FILE="$tmp_dir/interfaces"
mkdir "$tmp_dir/interfaces.d" "$tmp_dir/extra"
cat >"$PVE_NETWORK_INTERFACES_FILE" <<'EOF'
auto lo
iface lo inet loopback
source interfaces.d/*.cfg
source-directory extra
EOF
cat >"$tmp_dir/interfaces.d/uplink.cfg" <<'EOF'
# Öffentliches IPv6 / IPv6 public / 公网配置
auto eth0
iface eth0 inet6 static
    address 2a01:4f8:c014:1a63::2
    netmask 64
    gateway fe80::1
EOF
cat >"$tmp_dir/extra/bridge" <<'EOF'
source ../interfaces
auto vmbr9
iface vmbr9 inet6 static
    address 2a14:7c0:1002:10f8::1/38
    bridge_ports eth1
EOF
assert_eq '2a01:4f8:c014:1a63::2/64' "$(pve_interfaces_probe cidr eth0)" 'separate netmask in sourced configuration'
assert_eq '2a14:7c0:1002:10f8::1/38' "$(pve_interfaces_probe cidr vmbr9)" 'source-directory and include cycle'
pve_interfaces_probe exists vmbr9
pve_interfaces_probe ports vmbr9 eth1
assert_rejected pve_interfaces_probe ports vmbr9 eth0

fixture_addresses='[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::2","prefixlen":64,"scope":"global"}]}]'
fixture_routes='[{"dst":"2a01:4f8:c014:1a63::/64","dev":"eth0","protocol":"kernel"},{"dst":"local","type":"local","dev":"lo"},{"dst":"2a01:4f8:c014:1a63:100::/72","dev":"eth1"}]'
fixture_defaults='[{"dst":"default","gateway":"fe80::1","dev":"eth0"}]'
ip() {
    case "$*" in
        '-j -6 addr show') printf '\033[32m%s\033[0m\n' "$fixture_addresses" ;;
        '-j -6 route show table all') printf '%s\n' "$fixture_routes" ;;
        '-j -6 route show default') printf '%s\n' "$fixture_defaults" ;;
        *) return 1 ;;
    esac
}
selection=$(pve_auto_direct_ipv6_config)
mapfile -t selected <<<"$selection"
assert_eq '2a01:4f8:c014:1a63:200::/72' "${selected[0]}" 'avoids host address and occupied child route'
assert_eq '2a01:4f8:c014:1a63:200::1' "${selected[1]}" 'bridge gets its own gateway'
assert_eq 'fe80::1' "${selected[3]}" 'preserves link-local upstream next hop'
normalized=$(pve_direct_ipv6_normalize "${selected[0]}" "${selected[3]}" "${selected[2]}" "${selected[1]}")
assert_eq "${selected[1]}" "$(sed -n '2p' <<<"$normalized")" 'NDP supports separate bridge and upstream gateways'

# A static file by itself is insufficient when the live address is dynamic,
# tentative, stale, host-only, or belongs to a tunnel transfer link.
for flag in dynamic temporary tentative dadfailed; do
    fixture_addresses="[{\"ifname\":\"eth0\",\"addr_info\":[{\"family\":\"inet6\",\"local\":\"2a01:4f8:c014:1a63::2\",\"prefixlen\":64,\"scope\":\"global\",\"flags\":[\"$flag\"]}]}]"
    assert_rejected pve_auto_direct_ipv6_config
done
fixture_addresses='[{"ifname":"eth0","linkinfo":{"info_kind":"sit"},"addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::2","prefixlen":64,"scope":"global"}]}]'
assert_rejected pve_auto_direct_ipv6_config
fixture_addresses='[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::2","prefixlen":128,"scope":"global"}]}]'
assert_rejected pve_auto_direct_ipv6_config
fixture_addresses='IPv6-Adresse ungültig'
assert_rejected pve_auto_direct_ipv6_config

# Broad and narrow static prefixes retain their real boundaries.
for prefix in 38 56 80 112 118 119; do
    cat >"$tmp_dir/interfaces.d/uplink.cfg" <<EOF
auto eth0
iface eth0 inet6 static
    address 2a14:7c0:1002:10f8::2/$prefix
EOF
    fixture_addresses="[{\"ifname\":\"eth0\",\"addr_info\":[{\"family\":\"inet6\",\"local\":\"2a14:7c0:1002:10f8::2\",\"prefixlen\":$prefix,\"scope\":\"global\"}]}]"
    parent=$(python3 -c 'import ipaddress,sys; print(ipaddress.IPv6Interface(sys.argv[1]).network)' "2a14:7c0:1002:10f8::2/$prefix")
    fixture_routes="[{\"dst\":\"$parent\",\"dev\":\"eth0\"}]"
    choice=$(pve_auto_direct_ipv6_config)
    python3 - "$choice" "$parent" <<'PY'
import ipaddress
import sys
lines = sys.argv[1].splitlines()
child = ipaddress.IPv6Network(lines[0])
assert child.subnet_of(ipaddress.IPv6Network(sys.argv[2]))
assert child.prefixlen <= 120
assert ipaddress.IPv6Address('2a14:7c0:1002:10f8::2') not in child
assert ipaddress.IPv6Address(lines[1]) in child
PY
done

# Immutable failure never writes. Atomic append leaves the original file
# intact on a failed rename, and does not replace an existing symlink.
lsattr() { printf '%s %s\n' "$fixture_attributes" "$2"; }
chattr() { [[ "$unlock_allowed" == true ]]; }
fixture_attributes='----i--------------'
unlock_allowed=false
original=$(cat "$PVE_NETWORK_INTERFACES_FILE")
assert_rejected pve_append_network_config <<<"iface vmbr2 inet6 static"
assert_eq "$original" "$(cat "$PVE_NETWORK_INTERFACES_FILE")" 'unlock failure preserves file'
fixture_attributes='-------------------'
# Called by a dynamically loaded helper; older ShellCheck cannot trace it.
# shellcheck disable=SC2317
mv() { return 1; }
assert_rejected pve_append_network_config <<<"iface vmbr2 inet6 static"
assert_eq "$original" "$(cat "$PVE_NETWORK_INTERFACES_FILE")" 'failed atomic rename preserves file'
unset -f mv
ln -s "$PVE_NETWORK_INTERFACES_FILE" "$tmp_dir/interfaces-link"
export PVE_NETWORK_INTERFACES_FILE="$tmp_dir/interfaces-link"
pve_append_network_config <<<"# appended fixture"
[[ -L "$PVE_NETWORK_INTERFACES_FILE" ]]
assert_eq '# appended fixture' "$(tail -n 1 "$PVE_NETWORK_INTERFACES_FILE")" 'append follows existing symlink'
printf 'direct IPv6 discovery and safe-write tests passed\n'
