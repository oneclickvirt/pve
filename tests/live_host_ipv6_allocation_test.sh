#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ctid="${PVE_TEST_CTID:-104}"
template_file="${PVE_CT_TEMPLATE_FILE:-}"
creation_started=false
work_dir=""
verify_existing=false

on_exit() {
    local status=$?
    if [ "$status" -ne 0 ] && [ "$creation_started" = true ]; then
        printf 'CT %s may be partially created; it was left intact.\n' "$ctid" >&2
        [ -n "$work_dir" ] && printf 'Private test log: %s/build.log\n' "$work_dir" >&2
    fi
}
trap on_exit EXIT

if ! [[ "$ctid" =~ ^[0-9]+$ ]] || [ "$ctid" -lt 100 ] || [ "$ctid" -gt 256 ]; then
    printf 'PVE_TEST_CTID must be between 100 and 256.\n' >&2
    exit 1
fi
if [[ ! "$template_file" =~ ^/var/lib/vz/template/cache/[A-Za-z0-9._-]+\.tar\.(xz|zst)$ ]] ||
   [ ! -f "$template_file" ]; then
    printf 'PVE_CT_TEMPLATE_FILE must name an existing Debian 12 template in the PVE cache.\n' >&2
    exit 1
fi

source "$repo_root/scripts/default_ct_config.sh"
CTID="$ctid"
existing_type=$(pve_existing_guest_type "$ctid") || exit 1
case "$existing_type" in
    none)
        validate_ctid || exit 1
        ;;
    ct)
        if [ "${PVE_TEST_REUSE_EXISTING:-false}" != true ] ||
           [ ! -f "${PVE_CT_METADATA_DIR:-/root}/ct${ctid}" ] ||
           [ "$(pct status "$ctid")" != 'status: running' ]; then
            printf 'CT %s already exists; refusing to create or alter it.\n' "$ctid" >&2
            exit 1
        fi
        verify_existing=true
        ;;
    vm)
        printf 'PVE VMID %s is occupied by a VM; refusing to alter it.\n' "$ctid" >&2
        exit 1
        ;;
    *)
        printf 'Unable to verify PVE VMID %s; refusing to continue.\n' "$ctid" >&2
        exit 1
        ;;
esac
metadata_file="${PVE_CT_METADATA_DIR:-/root}/ct${ctid}"
if [ "$verify_existing" = false ] && \
   { [ -e "$metadata_file" ] || [ -L "$metadata_file" ] || [ -e "/etc/pve/lxc/${ctid}.conf" ]; }; then
    printf 'Refusing to overwrite existing CT metadata or config for CT %s.\n' "$ctid" >&2
    exit 1
fi

load_nat_ipv4_config || exit 1
if ! pve_nat66_ready; then
    printf 'PVE NAT66 is not ready; stopped before creating CT %s.\n' "$ctid" >&2
    exit 1
fi

if ! tar -tf "$template_file" | python3 -c '
import pathlib
import sys

paths = []
for line in sys.stdin:
    value = line.rstrip("\n")
    if value.startswith("./"):
        value = value[2:]
    value = value.rstrip("/")
    if value in {"", "."}:
        continue
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit("unsafe template member path")
    paths.append(value)
print("template_paths_safe=true")
print("etc_network_present=" + str(any(p == "etc/network" or p.startswith("etc/network/") for p in paths)).lower())
'; then
    printf 'Cached template validation failed; stopped before creating CT %s.\n' "$ctid" >&2
    exit 1
fi

host_snapshot() {
    python3 - <<'PY'
import json
import os
import re
import subprocess

environment = os.environ.copy()
environment.update({'LC_ALL': 'C', 'NO_COLOR': '1'})
ansi_csi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
def ip_json(arguments):
    output = subprocess.check_output(['ip', *arguments], text=True, env=environment)
    return json.loads(ansi_csi.sub('', output))

addresses = ip_json(['-j', '-6', 'addr', 'show'])
routes = ip_json(['-j', '-6', 'route', 'show', 'default'])
addrs = sorted(
    (row.get('ifname'), info.get('local'), info.get('prefixlen'))
    for row in addresses for info in row.get('addr_info', [])
    if info.get('family') == 'inet6' and info.get('scope') == 'global'
    and not info.get('tentative') and not info.get('dadfailed')
    and not ({'tentative', 'dadfailed'} & set(info.get('flags') or []))
)
defaults = sorted((row.get('dev'), row.get('gateway'), row.get('dst')) for row in routes)
print(json.dumps([addrs, defaults], separators=(',', ':')))
PY
}

host_before=$(host_snapshot)
host_egress_before=$(curl -6 -fsS --max-time 12 https://api64.ipify.org)
[ -n "$host_egress_before" ]
if [ "$verify_existing" = true ] && [ -n "${PVE_EXPECTED_HOST_SNAPSHOT:-}" ] &&
   [ "$host_before" != "$PVE_EXPECTED_HOST_SNAPSHOT" ]; then
    printf 'Host IPv6 address/prefix or default route differs from the pre-create baseline.\n' >&2
    exit 1
fi
printf 'host_snapshot_before=%s\n' "$host_before"
printf 'host_ipv6_egress_before=%s\n' "$host_egress_before"

if [ "$verify_existing" = false ]; then
    work_dir=$(mktemp -d "/root/.ocv-host-ipv6-ct${ctid}.XXXXXX")
    chmod 700 "$work_dir"
    creation_started=true
    if PVE_CT_TEMPLATE_FILE="$template_file" PVE_DEFAULT_CT_CONFIG_FILE="$repo_root/scripts/default_ct_config.sh" \
       PVE_CT_METADATA_DIR="${PVE_CT_METADATA_DIR:-/root}" \
       PVE_CT_CONFIG_DIR=/etc/pve/lxc WITHOUTCDN=TRUE noninteractive=true \
       bash "$repo_root/scripts/buildct.sh" \
       "$ctid" '' 1 768 5 42022 42080 42443 42000 42025 debian12 local y \
       >"$work_dir/build.log" 2>&1; then
        build_status=0
    else
        build_status=$?
    fi
    if [ "$build_status" -ne 0 ]; then
        printf 'buildct_exit=%s\n' "$build_status" >&2
        secret=$(awk 'NR == 1 {print $2}' "$metadata_file" 2>/dev/null || true)
        BUILD_SECRET="$secret" python3 - "$work_dir/build.log" <<'PY' >&2
import os
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(errors='replace')
secret = os.environ.get('BUILD_SECRET', '')
if secret:
    text = text.replace(secret, '[redacted]')
print('\n'.join(text.splitlines()[-45:]))
PY
        exit "$build_status"
    fi
fi

[ "$(pct status "$ctid")" = 'status: running' ]
pct config "$ctid" | LC_ALL=C NO_COLOR=1 grep --color=never -E '^(net[01]|onboot):'
ct_ipv6=$(pct exec "$ctid" -- env LC_ALL=C NO_COLOR=1 ip -j -6 addr show dev eth1 | python3 -c '
import ipaddress
import json
import re
import sys
raw = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", sys.stdin.read())
rows = json.loads(raw)
found = [a["local"] for r in rows for a in r.get("addr_info", [])
         if a.get("family") == "inet6" and a.get("scope") == "global"
         and not a.get("tentative") and not a.get("dadfailed")
         and not ({"tentative", "dadfailed"} & set(a.get("flags") or []))]
assert len(found) == 1
assert ipaddress.IPv6Address(found[0]).is_private
print(found[0])
')
ct_route=$(pct exec "$ctid" -- env LC_ALL=C NO_COLOR=1 ip -j -6 route show default | python3 -c '
import json
import re
import sys
raw = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", sys.stdin.read())
rows = json.loads(raw)
assert rows and rows[0].get("dev") == "eth1"
print(json.dumps(rows[0], separators=(",", ":")))
')
ct_egress=$(pct exec "$ctid" -- curl -6 -fsS --connect-timeout 10 --max-time 30 https://api64.ipify.org)
[ "$ct_egress" = "$host_egress_before" ]

host_after=$(host_snapshot)
host_egress_after=$(curl -6 -fsS --max-time 12 https://api64.ipify.org)
[ "$host_after" = "$host_before" ]
[ -n "$host_egress_after" ]

if [ "$verify_existing" = false ]; then
    secret=$(awk 'NR == 1 {print $2}' "$metadata_file")
    BUILD_SECRET="$secret" python3 - "$work_dir/build.log" <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(errors='replace')
secret = os.environ.get('BUILD_SECRET', '')
if secret:
    text = text.replace(secret, '[redacted]')
path.write_text(text)
os.chmod(path, 0o600)
PY
fi

printf 'ct_id=%s\n' "$ctid"
printf 'ct_ipv6=%s\n' "$ct_ipv6"
printf 'ct_default_route=%s\n' "$ct_route"
printf 'ct_ipv6_egress=%s\n' "$ct_egress"
printf 'host_snapshot_after=%s\n' "$host_after"
printf 'host_ipv6_egress_after=%s\n' "$host_egress_after"
printf 'host_ipv6_preserved=true\n'
printf 'ct_remains_running=true\n'
