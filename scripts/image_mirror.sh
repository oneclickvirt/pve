#!/bin/sh
# Shared POSIX helpers for node-first image downloads.
# Existing callers pass their CDN and upstream URLs after the node candidate.

: "${DUFS_MIRROR_BASE:=${ONECLICKVIRT_IMAGE_MIRROR_URL:-https://www.spiritlhl.com}}"

image_mirror_system() {
    _mirror_name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    for _mirror_os in rockylinux almalinux openwrt openeuler opensuse archlinux debian ubuntu alpine centos oracle fedora gentoo kali void freebsd devuan windows macos; do
        case "$_mirror_name" in
            *"$_mirror_os"*) printf '%s\n' "$_mirror_os"; return 0 ;;
        esac
    done
    printf '%s\n' misc
}

image_mirror_arch() {
    _mirror_name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$_mirror_name" in
        *arm64*|*aarch64*) printf '%s\n' arm64 ;;
        *armv7*|*armhf*|*arm_*) printf '%s\n' arm ;;
        *) printf '%s\n' amd64 ;;
    esac
}

image_mirror_path_for_release() {
    _mirror_repo=$1
    _mirror_tag=$2
    _mirror_asset=$3
    case "$_mirror_repo" in
        template) printf 'pve/kvm/macos/amd64/%s\n' "$_mirror_asset"; return 0 ;;
        pve_kvm_images|kvm_images) _mirror_root=pve/kvm ;;
        pve_lxc_images|lxc_amd64_images|lxc_arm_images) _mirror_root=pve/lxc ;;
        incus_images|lxd_images)
            _mirror_kind=lxc
            case "$(printf '%s %s' "$_mirror_tag" "$_mirror_asset" | tr '[:upper:]' '[:lower:]')" in *kvm*) _mirror_kind=kvm ;; esac
            _mirror_root=${_mirror_repo%_images}/$_mirror_kind
            ;;
        docker|containerd|podman) _mirror_root=runtime/$_mirror_repo ;;
        *) return 1 ;;
    esac
    printf '%s/%s/%s/%s\n' "$_mirror_root" "$(image_mirror_system "$_mirror_asset")" "$(image_mirror_arch "$_mirror_asset")" "$_mirror_asset"
}

image_mirror_url() {
    [ "${ONECLICKVIRT_IMAGE_MIRROR_DISABLE:-false}" != true ] || return 0
    printf '%s/%s\n' "${DUFS_MIRROR_BASE%/}" "${1#/}"
}

# Print node URL, then every supplied CDN/upstream URL in the original order.
image_mirror_candidates_for_release() {
    _mirror_path=$(image_mirror_path_for_release "$1" "$2" "$3") || return 1
    image_mirror_url "$_mirror_path"
    shift 3
    for _mirror_url in "$@"; do
        [ -n "$_mirror_url" ] && printf '%s\n' "$_mirror_url"
    done
}

# Infer a release candidate list from an original URL.  CDN wrappers used by
# existing scripts often contain the GitHub URL after the CDN prefix; those
# wrappers are retained after the node candidate.
image_mirror_candidates_for_url() {
    _mirror_url=$1
    case "$_mirror_url" in
        *https://github.com/oneclickvirt/*/releases/download/*)
            _mirror_origin=${_mirror_url#*https://github.com/oneclickvirt/}
            _mirror_repo=${_mirror_origin%%/*}
            _mirror_release=${_mirror_origin#*/releases/download/}
            _mirror_tag=${_mirror_release%%/*}
            _mirror_asset=${_mirror_release#*/}
            _mirror_path=$(image_mirror_path_for_release "$_mirror_repo" "$_mirror_tag" "$_mirror_asset") || {
                printf '%s\n' "$_mirror_url"
                return 0
            }
            image_mirror_url "$_mirror_path"
            printf '%s\n' "$_mirror_url"
            _mirror_canonical="https://github.com/oneclickvirt/${_mirror_origin}"
            [ "$_mirror_canonical" = "$_mirror_url" ] || printf '%s\n' "$_mirror_canonical"
            ;;
        *https://cnb.cool/oneclickvirt/template/-/git/raw/*/macos/*)
            _mirror_asset=${_mirror_url##*/}
            image_mirror_url "pve/kvm/macos/amd64/$_mirror_asset"
            printf '%s\n' "$_mirror_url"
            _mirror_canonical="https://cnb.cool/oneclickvirt/template/-/git/raw/${_mirror_url#*https://cnb.cool/oneclickvirt/template/-/git/raw/}"
            [ "$_mirror_canonical" = "$_mirror_url" ] || printf '%s\n' "$_mirror_canonical"
            ;;
        *https://cnb.cool/oneclickvirt/template/-/lfs/*)
            _mirror_canonical="https://cnb.cool/oneclickvirt/template/-/lfs/${_mirror_url#*https://cnb.cool/oneclickvirt/template/-/lfs/}"
            image_mirror_url "__mirror/resolve?source=$_mirror_canonical"
            printf '%s\n' "$_mirror_url"
            [ "$_mirror_canonical" = "$_mirror_url" ] || printf '%s\n' "$_mirror_canonical"
            ;;
        *)
            printf '%s\n' "$_mirror_url"
            ;;
    esac
}

# Download with the node first.  The output is replaced only after a complete
# successful transfer; callers retain their historical fallback URLs.
image_mirror_download_release() (
    _mirror_output=$1
    _mirror_repo=$2
    _mirror_tag=$3
    _mirror_asset=$4
    shift 4
    image_mirror_download_candidates "$_mirror_output" <<EOF_CANDIDATES
$(image_mirror_candidates_for_release "$_mirror_repo" "$_mirror_tag" "$_mirror_asset" "$@")
EOF_CANDIDATES
)

image_mirror_download_url() (
    image_mirror_download_candidates "$1" <<EOF_CANDIDATES
$(image_mirror_candidates_for_url "$2")
EOF_CANDIDATES
)

# A subshell owns its temporary-file trap, leaving the caller's traps intact.
image_mirror_download_candidates() (
    _mirror_output=$1
    _mirror_tmp=$(mktemp "${_mirror_output}.dufs.XXXXXX") || return 1
    trap 'rm -f -- "$_mirror_tmp"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _mirror_seen='|'
    while IFS= read -r _mirror_candidate; do
        [ -n "$_mirror_candidate" ] || continue
        case "$_mirror_seen" in *"|$_mirror_candidate|"*) continue ;; esac
        _mirror_seen="$_mirror_seen$_mirror_candidate|"
        printf '[image-mirror] trying %s\n' "$_mirror_candidate" >&2
        # A failed primary must yield promptly to the historical sources.
        case "$_mirror_candidate" in
            "${DUFS_MIRROR_BASE%/}/"*)
                set -- --retry 0 --connect-timeout "${DUFS_MIRROR_CONNECT_TIMEOUT:-5}" \
                    --speed-time "${DUFS_MIRROR_IDLE_TIMEOUT:-30}" --speed-limit 1024 ;;
            *) set -- --retry 3 --retry-all-errors --connect-timeout 20 ;;
        esac
        if curl -fL "$@" --max-time "${DUFS_DOWNLOAD_MAX_TIME:-86400}" -o "$_mirror_tmp" "$_mirror_candidate" && [ -s "$_mirror_tmp" ]; then
            mv -f "$_mirror_tmp" "$_mirror_output"
            return 0
        fi
        rm -f "$_mirror_tmp"
    done
    printf '[image-mirror] all candidates failed for %s\n' "$_mirror_output" >&2
    return 1
)
