#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/buildct.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

extract_function() {
    sed -n "/^$1() {/,/^}/p" "$script"
}

validate_storage_name() { :; }
eval "$(extract_function init)"
eval "$(extract_function save_container_info)"

export PVE_CT_METADATA_DIR="$test_dir/metadata"
export PVE_CT_CONFIG_DIR="$test_dir/lxc"
mkdir -p "$PVE_CT_METADATA_DIR" "$PVE_CT_CONFIG_DIR"

(
    cd "$test_dir"
    printf '%s\n' 'keep this file' >ct150
    init 150 test-password 1 512 5 20001 20002 20003 29975 30000 debian12 local y
    [ "$(cat ct150)" = 'keep this file' ]
)

printf '%s\n' 'net0: name=eth0,bridge=vmbr1' >"$PVE_CT_CONFIG_DIR/150.conf"
CTID=150
password='test-password-do-not-print'
core=1
memory=512
disk=5
sshn=20001
web1_port=20002
web2_port=20003
port_first=29975
port_last=30000
system_ori=debian12
storage=local
independent_ipv6_status=NAT66
ct_internal_ipv6='fd42:5339:296f:1f00::96'
output_file="$test_dir/save-output"
save_container_info >"$output_file"
[ -s "$PVE_CT_METADATA_DIR/ct150" ]
grep -Fq "$password" "$PVE_CT_METADATA_DIR/ct150"
if grep -Fq "$password" "$output_file" "$PVE_CT_CONFIG_DIR/150.conf"; then
    echo 'container root password was printed or copied into the PVE config' >&2
    exit 1
fi
python3 - "$PVE_CT_METADATA_DIR/ct150" <<'PY'
import os
import sys
assert os.stat(sys.argv[1]).st_mode & 0o777 == 0o600
PY

printf '%s\n' 'preserve existing metadata' >"$PVE_CT_METADATA_DIR/ct151"
CTID=151
if save_container_info >/dev/null 2>&1; then
    echo 'container metadata save replaced an existing file' >&2
    exit 1
fi
[ "$(cat "$PVE_CT_METADATA_DIR/ct151")" = 'preserve existing metadata' ]

printf '%s\n' 'existing metadata' >"$PVE_CT_METADATA_DIR/ct152"
if init 152 test-password 1 512 5 20001 20002 20003 29975 30000 debian12 local N >/dev/null 2>&1; then
    echo 'container init accepted an existing metadata file' >&2
    exit 1
fi
[ "$(cat "$PVE_CT_METADATA_DIR/ct152")" = 'existing metadata' ]

if init '../../tmp/unsafe' test-password 1 512 5 20001 20002 20003 29975 30000 debian12 local N >/dev/null 2>&1; then
    echo 'container init accepted an unsafe CTID' >&2
    exit 1
fi

printf 'PVE CT metadata preservation and password redaction tests passed\n'
