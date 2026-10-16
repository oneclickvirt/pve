#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
cleanup() {
    if [[ -f "$test_dir/child-pid" ]]; then kill "$(cat "$test_dir/child-pid")" 2>/dev/null || true; fi
    rm -rf "$test_dir"
}
trap cleanup EXIT
command -v flock >/dev/null
cat >"$test_dir/helper.py" <<'PY'
print('198.51.100.218\n27\n198.51.100.193\n198.51.100.194')
PY
# Model qm start leaving a running child which inherited the allocator FD.
# The allocation must become available when its shell finishes, while that
# child is still alive. Closing only the parent FD does not release flock.
(
    # shellcheck source=/dev/null
    source "$repo_root/scripts/default_vm_config.sh"
    export PVE_PUBLIC_IPV4_LOCK_FILE="$test_dir/lock"
    export PVE_PUBLIC_IPV4_HELPER_FILE="$test_dir/helper.py"
    pve_public_ipv4_config fullnat 198.51.100.218
    sleep 30 >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$test_dir/child-pid"
)
kill -0 "$(cat "$test_dir/child-pid")"
flock -n "$test_dir/lock" true
printf 'Public IPv4 allocator releases locks inherited by guest processes\n'
