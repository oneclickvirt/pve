#!/usr/bin/env bash
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

# Systemd units that execute downloaded scripts must retain the explicit mode
# hardening in the installer.  These checks prevent a future regression where
# wget leaves an ExecStart script non-executable.
grep -Fq 'chmod 755 /usr/local/bin/install_ifupdown2.sh' ./scripts/install_pve.sh
grep -Fq 'chmod 755 /usr/local/bin/check-dns.sh' ./scripts/install_pve.sh
grep -Fq 'chmod 755 /usr/local/bin/clear_interface_route_cache.sh' ./scripts/install_pve.sh
grep -Fq 'TimeoutStartSec=30min' ./extra_scripts/ifupdown2-install.service

printf 'static shell inventory passed (%s scripts)\n' "${#shell_files[@]}"
