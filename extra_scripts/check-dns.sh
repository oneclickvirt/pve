#!/bin/bash
set -euo pipefail

RESOLV_CONF="${PVE_RESOLV_CONF:-/etc/resolv.conf}"
state_dir="${PVE_STATE_DIR:-/usr/local/bin}"

# Keep provider DNS, resolved stubs and resolv.conf symlinks intact. Supply
# fallback resolvers only when no nameserver is configured at all.
if ! grep -Eq '^[[:space:]]*nameserver[[:space:]]+[^#[:space:]]+' "$RESOLV_CONF" 2>/dev/null; then
    printf '\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n' >>"$RESOLV_CONF"
    if [ -s "$state_dir/pve_check_ipv6" ] && [ -s "$state_dir/pve_ipv6_gateway" ]; then
        printf 'nameserver 2606:4700:4700::1111\n' >>"$RESOLV_CONF"
    fi
fi

# resolvconf is optional on Debian 13. Its absence must not fail boot or an
# otherwise working PVE installation.
if command -v resolvconf >/dev/null 2>&1 && ip link show vmbr0 >/dev/null 2>&1; then
    resolvconf -a vmbr0 <"$RESOLV_CONF"
fi
printf 'DNS configuration is available in %s\n' "$RESOLV_CONF"
