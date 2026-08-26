#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script_path="${repo_root}/extra_scripts/configure_network.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

mock_bin="${tmp_dir}/bin"
interfaces_file="${tmp_dir}/interfaces"
sysctl_file="${tmp_dir}/sysctl.d/99-oneclickvirt-pve-ra.conf"
ifreload_log="${tmp_dir}/ifreload.log"
sysctl_log="${tmp_dir}/sysctl.log"
mkdir -p "$mock_bin"

cat >"${mock_bin}/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"-6 route show default")
    # The reported PVE shape has a bridge address but no IPv6 default route
    # at the time this service runs.
    ;;
"-o -6 addr show scope global")
    printf '%s\n' '3: vmbr0    inet6 2a14:7c0:1002:10f8::1/128 scope global'
    printf '%s\n' '5: vmbr2    inet6 2a14:7c0:1002:10f8::1/38 scope global'
    ;;
"link show dev vmbr0")
    exit 0
    ;;
*)
    exit 1
    ;;
esac
EOF

cat >"${mock_bin}/sysctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PVE_TEST_SYSCTL_LOG:?}"
EOF

cat >"${mock_bin}/ifreload" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PVE_TEST_IFRELOAD_LOG:?}"
EOF
chmod +x "${mock_bin}/ip" "${mock_bin}/sysctl" "${mock_bin}/ifreload"

cat >"$interfaces_file" <<'EOF'
auto lo
iface lo inet loopback

auto vmbr0
iface vmbr0 inet static
    address 77.90.60.168/24
pre-up echo 2 > /proc/sys/net/ipv6/conf/all/accept_ra
EOF

PATH="${mock_bin}:$PATH" \
    PVE_NETWORK_INTERFACES_FILE="$interfaces_file" \
    PVE_RA_SYSCTL_FILE="$sysctl_file" \
    PVE_TEST_SYSCTL_LOG="$sysctl_log" \
    PVE_TEST_IFRELOAD_LOG="$ifreload_log" \
    bash "$script_path"

if grep -Fq '/proc/sys/net/ipv6/conf/all/accept_ra' "$interfaces_file"; then
    printf 'FAIL: legacy global accept_ra rule was not removed\n' >&2
    exit 1
fi
grep -Fqx 'iface vmbr0 inet static' "$interfaces_file"
grep -Fqx '    address 77.90.60.168/24' "$interfaces_file"
if grep -Fq 'inet6 auto' "$interfaces_file"; then
    printf 'FAIL: configure_network unexpectedly rewrote interface stanzas\n' >&2
    exit 1
fi
grep -Fqx 'net.ipv6.conf.vmbr0.accept_ra=2' "$sysctl_file"
grep -Fqx -- '-q -w net.ipv6.conf.vmbr0.accept_ra=2' "$sysctl_log"
grep -Fqx -- '-ad' "$ifreload_log"

printf 'configure_network regression test passed\n'
