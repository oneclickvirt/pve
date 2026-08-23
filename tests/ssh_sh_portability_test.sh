#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

os_release_file="${tmp_dir}/os-release"
issue_file="${tmp_dir}/issue"
helper_file="${tmp_dir}/helpers.sh"

{
    sed -n '/^get_os_id() {/,/^}/p' "${repo_root}/scripts/ssh_sh.sh"
    sed -n '/^is_arch_linux() {/,/^}/p' "${repo_root}/scripts/ssh_sh.sh"
} >"$helper_file"
printf 'os_release_file=%s\n' "$(printf '%q' "$os_release_file")" >>"$helper_file"
printf 'issue_file=%s\n' "$(printf '%q' "$issue_file")" >>"$helper_file"

printf 'ID=alpine\n' >"$os_release_file"
printf 'Alpine Linux \\r\\n' >"$issue_file"
printf 'get_os_id\n' >>"$helper_file"
printf 'is_arch_linux && printf ARCH || true\n' >>"$helper_file"
output=$(dash "$helper_file")
[[ "$output" == "alpine" ]] || {
    printf 'FAIL: POSIX OS detection returned %q\n' "$output" >&2
    exit 1
}

printf 'Arch Linux \\r\\n' >"$issue_file"
output=$(dash "$helper_file" | tail -n 1)
[[ "$output" == "ARCH" ]] || {
    printf 'FAIL: POSIX Arch detection returned %q\n' "$output" >&2
    exit 1
}

printf 'Debian GNU/Linux 12 \\n' >"$issue_file"
if dash "$helper_file" | grep -q '^ARCH$'; then
    printf 'FAIL: Debian issue banner was detected as Arch\n' >&2
    exit 1
fi

printf 'ssh_sh POSIX detection tests passed\n'
