#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/install_pve.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

for name in installed_pve_kernel_versions verify_pve_kernel_boot_files finalize_pve_kernel_installation verify_pve_installation preserve_boot_kernels rollback_failed_pve_install disable_pve_enterprise_sources; do
    eval "$(sed -n "/^${name}() {/,/^}/p" "$installer")"
done
PVE_BOOT_DIR="$tmp_dir/boot"
PVE_MODULES_DIR="$tmp_dir/modules"
mkdir -p "$PVE_BOOT_DIR" "$PVE_MODULES_DIR"
_red() { :; }
_yellow() { :; }
system_arch=x86
package_installed() { return 0; }
pveversion() { :; }
pvesh() { :; }
qm() { :; }
pct() { :; }
dpkg-query() { printf '%s\n' "$package_state"; }
lsinitramfs() { grep -qx valid "$1"; }
apt-mark() { printf '%s\n' "$*" >>"$tmp_dir/apt-mark"; }
apt-get() { printf '%s\n' "$*" >>"$tmp_dir/apt-get"; return 1; }
dpkg() { [[ "$*" == --audit ]]; }
depmod() { printf '%s\n' "$*" >>"$tmp_dir/depmod"; }
run-parts() {
    [[ ! -e "$PROXMOX_INSTALL_MODE_FILE" ]] || return 1
    [[ "${TEST_HOOK_FAILURE:-false}" != true ]] || return 1
    local version="${3#--arg=}"
    printf 'valid\n' >"$PVE_BOOT_DIR/initrd.img-$version"
    printf valid >"$PVE_MODULES_DIR/$version/modules.dep"
    printf '%s\n' "$*" >>"$tmp_dir/hooks"
}

reject_install() {
    if verify_pve_installation; then
        printf 'FAIL: accepted incomplete kernel: %s\n' "$1" >&2
        exit 1
    fi
}

for package_name in pve-kernel-5.15.180-1-pve proxmox-kernel-6.8.12-1-pve proxmox-kernel-7.0.14-24-pve-signed; do
    package_state="ii  $package_name"
    version="${package_name#*-kernel-}"
    version="${version%-signed}"
    printf valid >"$PVE_BOOT_DIR/vmlinuz-$version"
    printf 'valid\n' >"$PVE_BOOT_DIR/initrd.img-$version"
    mkdir -p "$PVE_MODULES_DIR/$version"
    printf valid >"$PVE_MODULES_DIR/$version/modules.dep"
    verify_pve_installation
    printf corrupt >"$PVE_BOOT_DIR/initrd.img-$version"
    reject_install 'corrupt initramfs'
    printf 'valid\n' >"$PVE_BOOT_DIR/initrd.img-$version"
    rm "$PVE_MODULES_DIR/$version/modules.dep"
    reject_install 'missing modules'
done

# A valid previous kernel is recovery capacity, not proof that the default
# newest PVE kernel is bootable.
package_state=$'ii  proxmox-kernel-6.8.12-1-pve\nii  proxmox-kernel-7.0.14-24-pve-signed'
printf valid >"$PVE_BOOT_DIR/vmlinuz-6.8.12-1-pve"
printf 'valid\n' >"$PVE_BOOT_DIR/initrd.img-6.8.12-1-pve"
printf valid >"$PVE_MODULES_DIR/6.8.12-1-pve/modules.dep"
rm -f "$PVE_BOOT_DIR/initrd.img-7.0.14-24-pve"
reject_install 'newest kernel incomplete despite a healthy previous kernel'

# Installed package status alone is insufficient: install mode suppresses the
# actual kernel hooks. Finalization must regenerate boot files outside it.
PROXMOX_INSTALL_MODE_FILE="$tmp_dir/install-mode"
package_state='ii  proxmox-kernel-7.0.14-24-pve-signed'
version=7.0.14-24-pve
rm -f "$PVE_BOOT_DIR/initrd.img-$version"
touch "$PROXMOX_INSTALL_MODE_FILE"
if finalize_pve_kernel_installation replay; then
    echo 'FAIL: finalization under external install mode was accepted' >&2
    exit 1
fi
rm "$PROXMOX_INSTALL_MODE_FILE"
finalize_pve_kernel_installation replay
verify_pve_installation
grep -Fxq '7.0.14-24-pve' "$tmp_dir/depmod"
grep -Fq -- '--arg=7.0.14-24-pve --arg=' "$tmp_dir/hooks"
TEST_HOOK_FAILURE=true
if finalize_pve_kernel_installation replay; then
    echo 'FAIL: failed boot hooks were accepted' >&2
    exit 1
fi
TEST_HOOK_FAILURE=false

PVE_APT_SOURCES_DIR="$tmp_dir/sources"
mkdir -p "$PVE_APT_SOURCES_DIR"
printf 'URIs: https://enterprise.proxmox.com/debian/pve\n' >"$PVE_APT_SOURCES_DIR/pve-enterprise.sources"
printf 'deb https://custom.example/ceph trixie main\n' >"$PVE_APT_SOURCES_DIR/ceph.list"
disable_pve_enterprise_sources
[[ -f "$PVE_APT_SOURCES_DIR/pve-enterprise.sources.ocv-disabled" ]]
[[ ! -e "$PVE_APT_SOURCES_DIR/pve-enterprise.sources" ]]
grep -Fq custom.example "$PVE_APT_SOURCES_DIR/ceph.list"
disable_pve_enterprise_sources

for package_state in 'ii  proxmox-default-kernel' 'ii  proxmox-kernel-7.0' 'rc  proxmox-kernel-7.0.14-24-pve-signed' 'iF  proxmox-kernel-7.0.14-24-pve-signed' 'un  pve-kernel-5.15.180-1-pve'; do
    reject_install 'meta package or non-installed concrete kernel'
done
package_state=$'ii  linux-image-6.12.107+deb13-amd64\nrc  linux-image-6.12.1-amd64\nii  proxmox-kernel-7.0.14-24-pve-signed'
preserve_boot_kernels
grep -Fxq 'manual linux-image-6.12.107+deb13-amd64 proxmox-kernel-7.0.14-24-pve-signed' "$tmp_dir/apt-mark"
rollback_failed_pve_install
[[ ! -e "$tmp_dir/apt-get" ]] || { echo 'FAIL: failure cleanup ran a package removal transaction' >&2; exit 1; }
echo 'PVE kernel names, installed state, boot files and non-destructive failure recovery passed'
