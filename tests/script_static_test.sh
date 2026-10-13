#!/usr/bin/env bash
# The single-quoted grep patterns assert literal source text.
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

shell_files=()
while IFS= read -r -d '' script; do
    shell_files+=("$script")
    case "$script" in
    ./scripts/ssh_sh.sh)
        sh -n "$script"
        ;;
    *)
        bash -n "$script"
        ;;
    esac
done < <(find . -type f -name '*.sh' -not -path './.git/*' -print0)

if [[ "${#shell_files[@]}" -eq 0 ]]; then
    printf 'FAIL: no shell scripts were discovered\n' >&2
    exit 1
fi

# Block syntax/runtime errors without turning legacy advisory ShellCheck
# warnings into a breaking change.  The workflow still runs the focused test
# scripts with its historical warning suppressions.
shellcheck -S error "${shell_files[@]}"
shellcheck -s sh -S error ./scripts/ssh_sh.sh

# Systemd units that execute downloaded scripts must use the atomic downloader
# and explicit mode hardening. These checks prevent a truncated wget target
# from being mistaken for an installed service on the next run.
grep -Fq 'download_required_file' ./scripts/install_pve.sh
grep -Fq 'download_required_file "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/install_ifupdown2.sh" /usr/local/bin/install_ifupdown2.sh 755' ./scripts/install_pve.sh
grep -Fq 'download_required_file "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/check-dns.sh" /usr/local/bin/check-dns.sh 755' ./scripts/install_pve.sh
grep -Fq 'download_required_file "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/extra_scripts/clear_interface_route_cache.sh" /usr/local/bin/clear_interface_route_cache.sh 755' ./scripts/install_pve.sh
grep -Fq 'curl -fsSL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/buildct.sh"' ./scripts/create_ct.sh
grep -Fq 'curl -fsSL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/buildvm.sh"' ./scripts/create_vm.sh
grep -Fq 'pct exec "$CTID" -- curl -fsSL' ./scripts/buildct.sh
grep -Fq 'pct exec "$CTID" -- test -s ssh_bash.sh' ./scripts/buildct.sh
grep -Fq 'pct exec "$CTID" -- curl -fsSL' ./scripts/buildct_onlyv6.sh
grep -Fq 'pct exec "$CTID" -- test -s ssh_bash.sh' ./scripts/buildct_onlyv6.sh
grep -Fq 'TimeoutStartSec=30min' ./extra_scripts/ifupdown2-install.service

printf 'static shell inventory passed (%s scripts)\n' "${#shell_files[@]}"
