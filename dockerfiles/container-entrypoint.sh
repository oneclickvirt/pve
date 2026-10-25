#!/usr/bin/env bash
set -Eeuo pipefail

state=/var/lib/pve-container/root-password-initialized
if [[ ! -f "$state" && -n "${PVE_ROOT_PASSWORD_FILE:-}" ]]; then
    [[ -f "$PVE_ROOT_PASSWORD_FILE" && -s "$PVE_ROOT_PASSWORD_FILE" ]] || {
        echo 'PVE_ROOT_PASSWORD_FILE must point to a nonempty mounted secret file' >&2
        exit 1
    }
    password=$(cat -- "$PVE_ROOT_PASSWORD_FILE")
    [[ -n "$password" && "$password" != *$'\n'* && "$password" != *$'\r'* && "$password" != *:* ]] || {
        echo 'The root password must not contain line breaks or colons' >&2
        exit 1
    }
    printf 'root:%s\n' "$password" | chpasswd
    unset password
    mkdir -p "$(dirname "$state")"
    (umask 077; : >"$state")
fi
ssh-keygen -A >/dev/null
exec /sbin/init "$@"
