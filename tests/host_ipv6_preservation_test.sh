#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

ip() {
    case "$*" in
        '-j -6 addr show')
            if [ "${PVE_TEST_BAD_JSON:-false}" = true ]; then
                printf '\033[31mAdresse IPv6 ungültig / adresse IPv6 invalide / IPv6 地址无效\033[0m\n'
            else
                printf '\033[32m[{"ifname":"vmbr0","addr_info":[{"family":"inet6","local":"2a01:4f8:c014:1a63::1","prefixlen":%s,"scope":"global"}]}]\033[0m\n' "${PVE_TEST_PREFIX:-64}"
            fi
            ;;
        '-j -6 route show table all')
            printf '%s\n' '[{"type":"local","dst":"local","dev":"lo"},{"type":"multicast","dst":"multicast","dev":"eth0"},{"dst":"default","gateway":"fe80::1","dev":"vmbr0","multipath":[{"gateway":"2a01:4f8:c014:1a63::11","dev":"vmbr0"}]},{"dst":"2a01:4f8:c014:1a63::9/128","dev":"vmbr0"}]'
            ;;
        *) return 1 ;;
    esac
}

for config in default_ct_config.sh default_vm_config.sh; do
    eval "$(sed -n '/^pve_ipv6_external_address_available() {/,/^}/p' "$repo_root/scripts/$config")"
    eval "$(sed -n '/^setup_nat_mapping() {/,/^}/p' "$repo_root/scripts/$config")"
    for prefix in 38 64 120 127 128; do
        export PVE_TEST_PREFIX="$prefix"
        if pve_ipv6_external_address_available '2a01:4f8:c014:1a63::1'; then
            echo "$config host IPv6 /${prefix} was offered to a container" >&2
            exit 1
        fi
    done
    for reserved in 'fe80::1' '2a01:4f8:c014:1a63::9' '2a01:4f8:c014:1a63::11'; do
        if pve_ipv6_external_address_available "$reserved"; then
            echo "$config host gateway or exact route ${reserved} was offered to a container" >&2
            exit 1
        fi
    done
    if setup_nat_mapping 'fd42:5339:296f:1f00::65' '2a01:4f8:c014:1a63::1' >/dev/null 2>&1; then
        echo "$config NAT mapping accepted the host IPv6 address" >&2
        exit 1
    fi
    pve_ipv6_external_address_available '2a01:4f8:c014:1a63::10'
    if PVE_TEST_BAD_JSON=true pve_ipv6_external_address_available '2a01:4f8:c014:1a63::10'; then
        echo "$config localized diagnostic was accepted as host address state" >&2
        exit 1
    fi
done

printf 'Host IPv6 reservation, variable prefix, color, and locale tests passed\n'
