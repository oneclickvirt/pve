#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

# The configuration file is intentionally function-only, so it can be sourced
# without invoking a PVE command.  Stub downloads and exercise the image
# selection branches in an isolated temporary path.
# shellcheck source=/dev/null
source "${repo_root}/scripts/default_vm_config.sh"

_blue() { :; }
_red() { :; }
_yellow() { :; }
download_calls=()
_download_with_retry() {
    download_calls+=("$1")
    : >"$2"
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL: %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

file_path="${tmp_dir}/debian12.qcow2"
system="debian12"
cdn_success_url=""
sys_family=""
sys_tag_images=()
# Keep an empty first element to cover the array-length bug that previously
# skipped valid images in later elements.
new_images=("" "debian12_20260822_cloud.qcow2")
ver=""
download_calls=()
download_x86_image >/dev/null
assert_eq "1" "${#download_calls[@]}" "new image download count"
assert_eq "https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/debian12_20260822_cloud.qcow2" "${download_calls[0]}" "new image URL"
assert_eq "auto_build" "$ver" "new image selection mode"

file_path="${tmp_dir}/debian10.qcow2"
system="debian10"
new_images=()
sys_tag_images=()
sys_family=""
ver=""
download_calls=()
download_x86_image >/dev/null
assert_eq "1" "${#download_calls[@]}" "legacy image download count"
assert_eq "https://github.com/oneclickvirt/kvm_images/releases/download/v1.1/debian10.qcow2" "${download_calls[0]}" "legacy image URL"
assert_eq "v1.1" "$ver" "legacy image selection mode"

printf 'default VM image selection tests passed\n'
