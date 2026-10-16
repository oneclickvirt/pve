#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/build_nat_network.sh"
test_dir=$(mktemp -d)
pve_network_snapshot=""
trap 'rm -rf "$test_dir"' EXIT

for name in pve_interfaces_probe pve_begin_network_transaction pve_abort_network_transaction pve_commit_network_transaction restart_network_services; do
    eval "$(sed -n "/^${name}() {/,/^}/p" "$script")"
done
_yellow() { :; }
_red() { :; }
chattr() { :; }
systemctl() { :; }
systemd-run() { printf '%s\n' "$*" >>"$test_dir/timer"; }
ifreload() { printf '%s\n' "$*" >>"$test_dir/reloads"; }
restore_host_ipv6_runtime() { return 0; }
pve_verify_host_connectivity() { [[ "${connectivity_ok:-true}" == true ]]; }
pve_network_transaction_files() { printf '%s\n' "$test_dir/$scenario/state" "$test_dir/$scenario/new-state"; }
pve_capture_network_runtime() { :; }
pve_normalize_bridge_forward_delay() { :; }
pve_configure_ufw_forwarding() { :; }
nft() { return 1; }
iptables-save() { :; }
iptables-restore() { :; }
export test_dir
export -f chattr ifreload systemctl

for scenario in aborted committed lost-connectivity; do
    (
        PVE_NETWORK_BACKUP_ROOT="$test_dir/$scenario/backups"
        PVE_NETWORK_INTERFACES_FILE="$test_dir/$scenario/interfaces"
        mkdir -p "$test_dir/$scenario/children"
        printf 'source %s/children/*\n\nauto lo\niface lo inet loopback\n' "$test_dir/$scenario" >"$PVE_NETWORK_INTERFACES_FILE"
        printf 'auto eth0\niface eth0 inet static\n    address 192.0.2.10/27\n' >"$test_dir/$scenario/children/uplink"
        cp "$PVE_NETWORK_INTERFACES_FILE" "$test_dir/$scenario/original"
        cp "$test_dir/$scenario/children/uplink" "$test_dir/$scenario/child-original"
        printf 'original-state\n' >"$test_dir/$scenario/state"
        pve_begin_network_transaction
        printf 'changed\n' >"$PVE_NETWORK_INTERFACES_FILE"
        printf 'changed child\n' >"$test_dir/$scenario/children/uplink"
        printf 'changed-state\n' >"$test_dir/$scenario/state"
        printf 'new-state\n' >"$test_dir/$scenario/new-state"
        case "$scenario" in
            aborted)
                pve_abort_network_transaction
                ;;
            committed)
                restart_network_services
                pve_commit_network_transaction
                # An already queued rollback must respect the commit marker.
                bash "$pve_network_snapshot/rollback.sh"
                grep -Fxq changed "$PVE_NETWORK_INTERFACES_FILE"
                grep -Fxq 'changed child' "$test_dir/$scenario/children/uplink"
                exit 0
                ;;
            lost-connectivity)
                connectivity_ok=false
                if restart_network_services; then
                    echo 'FAIL: lost host connectivity was accepted' >&2
                    exit 1
                fi
                pve_abort_network_transaction
                ;;
        esac
        cmp "$test_dir/$scenario/original" "$PVE_NETWORK_INTERFACES_FILE"
        cmp "$test_dir/$scenario/child-original" "$test_dir/$scenario/children/uplink"
        grep -Fxq original-state "$test_dir/$scenario/state"
        [[ ! -e "$test_dir/$scenario/new-state" ]]
        [[ -e "$pve_network_snapshot/rolled-back" ]]
    )
done
grep -Fq -- '--on-active=180s' "$test_dir/timer"
grep -Fxq -- '-a -s' "$test_dir/reloads"
grep -Fxq -- '-a' "$test_dir/reloads"
if grep -Eq 'service networking restart|systemctl restart networking.service' "$script"; then
    echo 'FAIL: network preconfiguration still tears down the SSH uplink' >&2
    exit 1
fi

eval "$(sed -n '/^pve_normalize_bridge_forward_delay() {/,/^}/p' "$script")"
pve_require_writable_network_file() { :; }
PVE_NETWORK_INTERFACES_FILE="$test_dir/delay"
cat >"$PVE_NETWORK_INTERFACES_FILE" <<'EOF'
auto vmbr0
iface vmbr0 inet static
    address 192.0.2.10/27
    bridge_stp off
    bridge_fd 0
auto vmbr9
iface vmbr9 inet manual
    bridge_stp on
    bridge_fd 8
EOF
pve_normalize_bridge_forward_delay
grep -Fxq '    bridge_fd 2' "$PVE_NETWORK_INTERFACES_FILE"
grep -Fxq '    bridge_fd 8' "$PVE_NETWORK_INTERFACES_FILE"

eval "$(sed -n '/^pve_wait_host_address_ready() {/,/^}/p' "$script")"
sleep() { :; }
ip() {
    local count=0 flag=tentative
    [[ ! -e "$test_dir/address-probes" ]] || count=$(cat "$test_dir/address-probes")
    count=$((count + 1))
    printf '%s' "$count" >"$test_dir/address-probes"
    [[ "$count" -lt 2 ]] || flag="${test_address_flag:-}"
    printf '[{"addr_info":[{"family":"inet6","local":"2a01:4f8:1::2","flags":["%s"]}]}]\n' "$flag"
}
# Defined by eval above; the later stub is for the connectivity-only fixture.
# shellcheck disable=SC2218
pve_wait_host_address_ready 6 2a01:4f8:1::2
[[ "$(cat "$test_dir/address-probes")" == 2 ]]
test_address_flag=dadfailed
if pve_wait_host_address_ready 6 2a01:4f8:1::2; then
    echo 'FAIL: duplicate IPv6 address was accepted as ready' >&2
    exit 1
fi

eval "$(sed -n '/^pve_verify_host_connectivity() {/,/^}/p' "$script")"
pve_wait_host_address_ready() { return 0; }
curl() {
    printf '%s\n' "$*" >>"$test_dir/probes"
    [[ "$*" == *cloudflare.com* ]]
}
ipv4_address=192.0.2.10/27
ipv6_address=2a01:4f8:1::2
host_ipv6_runtime_has_default_route=true
pve_verify_host_connectivity
grep -Fq -- '-4 --interface 192.0.2.10' "$test_dir/probes"
grep -Fq -- '-6 --interface 2a01:4f8:1::2' "$test_dir/probes"
PVE_NETWORK_PROBE_URL=https://www.debian.org/
if pve_verify_host_connectivity; then
    echo 'FAIL: failed explicit connectivity probe was accepted' >&2
    exit 1
fi
echo 'Network reload preserves sourced files, rolls back failed connectivity and cancels committed rollback'
