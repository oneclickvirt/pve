#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/pve
# 2026.08.27

# A PVE host can receive IPv6 on a bridge, a physical NIC, or a tunnel. Do
# not hard-code eth0 or change the global "all" setting: both break hosts
# whose guest prefix is carried by a different interface.
interfaces_file="${PVE_NETWORK_INTERFACES_FILE:-/etc/network/interfaces}"
ra_sysctl_file="${PVE_RA_SYSCTL_FILE:-/etc/sysctl.d/99-oneclickvirt-pve-ra.conf}"

is_safe_interface_name() {
    [[ "$1" =~ ^[[:alnum:]_.:-]{1,15}$ && "$1" != "lo" ]]
}

normalize_interface_name() {
    local interface_name="${1%%@*}"
    if is_safe_interface_name "$interface_name"; then
        printf '%s\n' "$interface_name"
    fi
}

default_ipv6_interface() {
    local interface_name
    interface_name=$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev" && i < NF) {print $(i + 1); exit}}')
    normalize_interface_name "$interface_name"
}

global_ipv6_interface() {
    local interface_name
    interface_name=$(ip -o -6 addr show scope global 2>/dev/null | awk '$3 == "inet6" {print $2; exit}')
    normalize_interface_name "$interface_name"
}

interface_exists() {
    local interface_name="$1"
    if ip link show dev "$interface_name" >/dev/null 2>&1; then
        return 0
    fi
    [[ -r "$interfaces_file" ]] && grep -Eq "^[[:space:]]*(auto|iface)[[:space:]]+${interface_name}([[:space:]]|$)" "$interfaces_file"
}

select_ipv6_uplink() {
    local interface_name
    for interface_name in "$(default_ipv6_interface)" "$(global_ipv6_interface)"; do
        if is_safe_interface_name "$interface_name"; then
            printf '%s\n' "$interface_name"
            return 0
        fi
    done

    # On a host that has not received its first RA yet, prefer the PVE bridge
    # when present. eth0 is retained only as the final compatibility fallback.
    for interface_name in vmbr0 eth0; do
        if interface_exists "$interface_name"; then
            printf '%s\n' "$interface_name"
            return 0
        fi
    done
    return 1
}

legacy_global_ra_rule='^[[:space:]]*pre-up[[:space:]]+echo[[:space:]]+2[[:space:]]*>[[:space:]]*/proc/sys/net/ipv6/conf/all/accept_ra([[:space:]]*(#.*)?)?$'

interfaces_file_is_immutable() {
    local attributes
    command -v lsattr >/dev/null 2>&1 || return 1
    attributes=$(lsattr -d "$interfaces_file" 2>/dev/null | awk 'NR == 1 {print $1}')
    [[ "$attributes" == *i* ]]
}

remove_legacy_global_ra_rule() {
    local temporary_file
    [[ -f "$interfaces_file" ]] || return 0
    grep -Eq "$legacy_global_ra_rule" "$interfaces_file" || return 0

    # Earlier releases made this file immutable solely to append the global
    # rule. Unlock it only while removing that legacy rule and leave normal
    # PVE/cloud-init ownership intact afterwards.
    if interfaces_file_is_immutable; then
        if ! command -v chattr >/dev/null 2>&1 || ! chattr -i "$interfaces_file"; then
            printf 'Unable to remove the legacy global IPv6 accept_ra rule from %s\n' "$interfaces_file" >&2
            return 1
        fi
    fi

    temporary_file=$(mktemp "${interfaces_file}.tmp.XXXXXX") || return 1
    if ! awk -v "rule=${legacy_global_ra_rule}" '$0 !~ rule' "$interfaces_file" >"$temporary_file"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    if ! cat "$temporary_file" >"$interfaces_file"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    rm -f -- "$temporary_file"
}

write_scoped_ra_sysctl() {
    local interface_name="$1" temporary_file
    mkdir -p "$(dirname "$ra_sysctl_file")" || return 1
    temporary_file=$(mktemp "${ra_sysctl_file}.tmp.XXXXXX") || return 1
    if ! printf 'net.ipv6.conf.%s.accept_ra=2\n' "$interface_name" >"$temporary_file"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    chmod 0644 "$temporary_file"
    mv -f -- "$temporary_file" "$ra_sysctl_file"
}

apply_scoped_ra_sysctl() {
    local interface_name="$1"
    if command -v sysctl >/dev/null 2>&1 && ! sysctl -q -w "net.ipv6.conf.${interface_name}.accept_ra=2"; then
        printf 'Unable to apply IPv6 accept_ra=2 on %s; it will be retried at boot\n' "$interface_name" >&2
    fi
}

reload_network_configuration() {
    if command -v ifreload >/dev/null 2>&1 && ! ifreload -ad; then
        printf 'ifreload -ad failed; the scoped IPv6 RA sysctl has still been saved\n' >&2
    fi
}

main() {
    local ipv6_uplink
    if ! ipv6_uplink=$(select_ipv6_uplink); then
        printf 'No usable IPv6 uplink found; skipping IPv6 RA configuration\n' >&2
        return 0
    fi

    if ! remove_legacy_global_ra_rule; then
        return 1
    fi
    if ! write_scoped_ra_sysctl "$ipv6_uplink"; then
        printf 'Unable to persist IPv6 accept_ra=2 for %s\n' "$ipv6_uplink" >&2
        return 1
    fi
    apply_scoped_ra_sysctl "$ipv6_uplink"
    reload_network_configuration
}

main "$@"
