#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
for name in pve_installer_network_topology rebuild_interfaces remove_duplicate_lines; do
    eval "$(sed -n "/^${name}() {/,/^}/p" "$repo_root/scripts/install_pve.sh")"
done
chattr() { :; }
export PVE_NETWORK_INTERFACES_FILE="$test_dir/interfaces"
mkdir "$test_dir/parts"
cat >"$PVE_NETWORK_INTERFACES_FILE" <<'EOF'
auto lo
iface lo inet loopback
source parts/*.cfg
auto vmbr0
iface vmbr0 inet static
    address 192.0.2.10/27
    bridge_ports eth0
    bridge_stp off
    bridge_fd 2
EOF
cat >"$test_dir/parts/uplink.cfg" <<'EOF'
auto eth0 eth1
iface eth0 inet static
    address 192.0.2.10/27
    gateway 192.0.2.1
iface eth0 inet6 static
    address 2a01:4f8:1::2/64
iface eth1 inet6 static
    address 2a01:4f8:2::2/64
    post-up true
auto vmbr9
iface vmbr9 inet manual
    bridge_ports eth1
    bridge_stp off
    bridge_fd 2
EOF
interface=eth0
cp "$PVE_NETWORK_INTERFACES_FILE" "$test_dir/original"
cp "$test_dir/parts/uplink.cfg" "$test_dir/child-original"
rebuild_interfaces
cmp "$test_dir/original" "$PVE_NETWORK_INTERFACES_FILE"
cmp "$test_dir/child-original" "$test_dir/parts/uplink.cfg"
pve_installer_network_topology has-interface eth1
pve_installer_network_topology owns-uplink eth0
pve_installer_network_topology clean-uplink eth0
grep -Fxq 'source parts/*.cfg' "$PVE_NETWORK_INTERFACES_FILE"
grep -Fxq 'auto eth1' "$test_dir/parts/uplink.cfg"
grep -Fxq '    address 2a01:4f8:2::2/64' "$test_dir/parts/uplink.cfg"
grep -Fxq '    post-up true' "$test_dir/parts/uplink.cfg"
if pve_installer_network_topology has-interface eth0; then
    echo 'FAIL: migrated physical L3 stanza remains' >&2
    exit 1
fi
pve_installer_network_topology owns-uplink eth0
cat "$test_dir/parts/uplink.cfg" >>"$PVE_NETWORK_INTERFACES_FILE"
remove_duplicate_lines "$PVE_NETWORK_INTERFACES_FILE"
[[ "$(grep -Fc '    bridge_stp off' "$PVE_NETWORK_INTERFACES_FILE")" == 2 ]]
[[ "$(grep -Fc '    bridge_fd 2' "$PVE_NETWORK_INTERFACES_FILE")" == 2 ]]
echo 'PVE installer retains sourced topology, unrelated IPv6 and repeated bridge options'
