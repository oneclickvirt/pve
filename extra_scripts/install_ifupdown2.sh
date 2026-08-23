#!/usr/bin/env bash
set -euo pipefail
# from
# https://github.com/oneclickvirt/pve
# 2024.03.12

# 安装ifupdown2
export DEBIAN_FRONTEND=noninteractive
apt-get install -o Dpkg::Options::="--force-confold" -y --no-install-recommends ifupdown2

# Only publish the completion marker after apt/dpkg has succeeded.  The
# installer harness uses this marker to distinguish a finished bootstrap from
# a service that still needs to run after the next boot.
marker_tmp=$(mktemp /usr/local/bin/ifupdown2_installed.txt.tmp.XXXXXX)
printf '1\n' >"$marker_tmp"
chmod 0644 "$marker_tmp"
mv -f -- "$marker_tmp" /usr/local/bin/ifupdown2_installed.txt

# 删除Systemd服务
systemctl disable ifupdown2-install.service >/dev/null 2>&1 || true
rm -f -- /etc/systemd/system/ifupdown2-install.service
systemctl daemon-reload >/dev/null 2>&1 || true

# 删除自身
rm -f -- "$0"
