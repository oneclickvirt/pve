#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$repo_root/scripts/default_vm_config.sh"
ver=""
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
_blue() { :; }; _red() { :; }; _yellow() { :; }
assert_eq() { [[ "$1" == "$2" ]] || { printf 'mismatch: %s != %s\n' "$1" "$2" >&2; exit 1; }; }
# Save the real atomic downloader before stubbing selection I/O.
eval "$(declare -f _download_with_retry | sed '1s/_download_with_retry/real_download/')"
_download_with_retry() { calls+=("$1"); [[ "$1" == "$accepted" ]]; }
cdn_success_url=""; file_path="$work_dir/image"; system=ubuntu22; sys_family=ubuntu
sys_tag_images=(ubuntu2204); new_images=(ubuntu22); calls=()
accepted="https://github.com/oneclickvirt/pve_kvm_images/releases/download/ubuntu/ubuntu2204.qcow2"
download_x86_image >/dev/null
assert_eq "${calls[0]}" "$accepted"; assert_eq "$ver" system_tag
accepted="https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/ubuntu22.qcow2"; calls=()
download_x86_image >/dev/null
assert_eq "${calls[1]}" "$accepted"; assert_eq "$ver" auto_build
sys_tag_images=(); new_images=(); calls=()
accepted="https://github.com/oneclickvirt/pve_kvm_images/releases/download/ubuntu/ubuntu2204.qcow2"
download_x86_image >/dev/null
assert_eq "${calls[0]}" "$accepted"
system=centos9-stream
assert_eq "$(_maintained_image_name "$system")" centos9
system=debian12
if _image_matches_requested_system debian120; then echo 'wrong version accepted' >&2; exit 1; fi
# An unsupported system must not accidentally select the final legacy tag.
system=missing99; sys_family=missing; calls=(); accepted=unavailable
if download_x86_image >/dev/null; then exit 1; fi
for url in "${calls[@]}"; do [[ "$url" != *kvm_images/releases/download/v1.0/missing99* ]]; done
# Test failure propagation through the preparation entry point.
get_new_images() { return 1; }; get_system_tag_images() { return 1; }
if prepare_x86_image >/dev/null; then exit 1; fi
# Exercise the real atomic downloader: HTTP failure preserves the old cache,
# while a CDN failure falls back to the direct origin before retrying.
sleep() { :; }; cdn_success_url=https://cdn.invalid/
accepted=https://origin.invalid/image.qcow2; calls=()
curl() {
    local output="" url="${!#}"
    calls+=("$url")
    while (($#)); do
        if [[ "$1" == -o ]]; then output="$2"; shift; fi
        shift
    done
    printf 'partial' >"$output"
    [[ "$url" == "$accepted" ]] || return 22
    printf 'valid-image' >"$output"
}
printf existing >"$work_dir/image"
real_download "${cdn_success_url}${accepted}" "$work_dir/image"
assert_eq "${#calls[@]}" 2; assert_eq "$(cat "$work_dir/image")" valid-image
accepted=unavailable
if real_download https://origin.invalid/image.qcow2 "$work_dir/image"; then exit 1; fi
assert_eq "$(cat "$work_dir/image")" valid-image
# Source CT definitions only; intercept the destination before touching PVE.
# shellcheck source=/dev/null
source "$repo_root/scripts/default_ct_config.sh"
system_name=""
en_system=ubuntu; num_system=26.04; cdn_success_url=""
_fetch_list_with_retry() { fetch_list_response=ubuntu_26.04_resolute_arm64_cloud.tar.xz; }
_download_with_retry() { calls+=("$1"); }
calls=(); find_and_download_system_image_arm
assert_eq "$system_name" ubuntu_26.04_resolute_arm64_cloud.tar.xz
assert_eq "${calls[0]}" https://github.com/oneclickvirt/lxc_arm_images/releases/download/ubuntu/ubuntu_26.04_resolute_arm64_cloud.tar.xz
echo 'PVE published image selection, failure and ARM metadata tests passed'
