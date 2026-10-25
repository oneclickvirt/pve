#!/usr/bin/env bash
set -Eeuo pipefail

major=${1:?PVE major version is required}
. /etc/os-release
case "$major:$VERSION_CODENAME:$(dpkg --print-architecture)" in
    7:bullseye:amd64|8:bookworm:amd64|9:trixie:amd64) ;;
    *) echo 'Use Debian 11/12/13 for PVE 7/8/9 respectively on amd64' >&2; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
apt-get update
apt-get upgrade -y
apt-get install -y --no-install-recommends ca-certificates curl gnupg systemd-sysv dbus openssh-server \
    iproute2 iputils-ping procps python3 locales
case "$major" in
    7) key=proxmox-release-bullseye.gpg ;;
    8) key=proxmox-release-bookworm.gpg ;;
    9) key=proxmox-archive-keyring-trixie.gpg ;;
esac
curl --fail --silent --show-error --location --retry 3 \
    "https://enterprise.proxmox.com/debian/$key" -o /usr/share/keyrings/proxmox-container.gpg
gpg --batch --show-keys /usr/share/keyrings/proxmox-container.gpg >/dev/null
# Proxmox's official no-subscription endpoint uses HTTP; APT verifies its
# signed Release and every package checksum against the HTTPS-fetched key.
printf 'deb [signed-by=/usr/share/keyrings/proxmox-container.gpg] http://download.proxmox.com/debian/pve %s pve-no-subscription\n' \
    "$VERSION_CODENAME" > /etc/apt/sources.list.d/pve-container.list
apt-get update
# pve-manager includes the VM and CT tools. The proxmox-ve metapackage would
# additionally install a host kernel, which a Docker container cannot boot.
apt-get install -y --no-install-recommends pve-manager
dpkg-query -W -f='${Status}\n' pve-manager | grep -qx 'install ok installed'
dpkg-query -W -f='${Version}\n' pve-manager | grep -E "^${major}\."
test -x /usr/sbin/qm
test -x /usr/sbin/pct
systemctl enable pve-cluster pvedaemon pveproxy pvestatd ssh
passwd -l root
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub /etc/machine-id /usr/sbin/policy-rc.d
touch /etc/machine-id
apt-get clean
rm -rf /var/lib/apt/lists/*
