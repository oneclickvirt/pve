#!/usr/bin/env bash
set -euo pipefail
# from
# https://github.com/oneclickvirt/pve
# 2024.03.12

marker_file="${IFUPDOWN2_MARKER_FILE:-/usr/local/bin/ifupdown2_installed.txt}"
unit_file="${IFUPDOWN2_UNIT_FILE:-/etc/systemd/system/ifupdown2-install.service}"
service_name="${IFUPDOWN2_SERVICE_NAME:-ifupdown2-install.service}"

# 安装ifupdown2
export DEBIAN_FRONTEND=noninteractive
apt-get install -o Dpkg::Options::="--force-confold" -y --no-install-recommends ifupdown2

# Only publish the completion marker after apt/dpkg has succeeded.  The
# installer harness uses this marker to distinguish a finished bootstrap from
# a service that still needs to run after the next boot.
marker_dir=$(dirname -- "$marker_file")
mkdir -p -- "$marker_dir"
marker_tmp=$(mktemp "${marker_file}.tmp.XXXXXX")
printf '1\n' >"$marker_tmp"
chmod 0644 "$marker_tmp"
mv -f -- "$marker_tmp" "$marker_file"

# 删除Systemd服务
systemctl disable "$service_name" >/dev/null 2>&1 || true
rm -f -- "$unit_file"
systemctl daemon-reload >/dev/null 2>&1 || true

# 删除自身
rm -f -- "$0"
