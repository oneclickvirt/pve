#!/usr/bin/env bash
set -Eeuo pipefail

major=${1:?PVE major version is required}
. /etc/os-release
architecture=$(dpkg --print-architecture)
case "$major:$VERSION_CODENAME:$architecture" in
    7:bullseye:amd64|8:bookworm:amd64|9:trixie:amd64|8:bookworm:arm64|9:trixie:arm64) ;;
    *) echo 'Use Debian 11/12/13 for amd64 PVE 7/8/9, or Debian 12/13 for ARM64 PXVIRT 8/9' >&2; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive
if [[ "$major" == 7 ]]; then
    # Debian 11 security packages moved to the signed Debian archive after LTS.
    # Keep APT signature and package checksum verification enabled.
    for source_list in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$source_list" ]] || continue
        sed -E -i 's#https?://(deb|security)\.debian\.org/debian-security#http://archive.debian.org/debian-security#g' "$source_list"
    done
fi
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
apt-get update
apt-get upgrade -y
apt-get install -y --no-install-recommends ca-certificates curl gnupg systemd-sysv dbus openssh-server \
    iproute2 iputils-ping procps python3 locales
if [[ "$architecture" == arm64 ]]; then
    # Proxmox does not publish ARM64 packages. PXVIRT is the community fork
    # succeeding Proxmox-Port; record that distinction in every ARM image.
    distribution=pxvirt
    repository=https://mirrors.lierfang.com/pxcloud/pxvirt
    curl --fail --silent --show-error --location --retry 3 \
        "$repository/pveport.gpg" -o /usr/share/keyrings/proxmox-container.gpg
    gpg --batch --show-keys /usr/share/keyrings/proxmox-container.gpg >/dev/null
    printf 'deb [signed-by=/usr/share/keyrings/proxmox-container.gpg] %s %s main\n' \
        "$repository" "$VERSION_CODENAME" > /etc/apt/sources.list.d/pve-container.list
else
    distribution=proxmox-ve
    repository=http://download.proxmox.com/debian/pve
    case "$major" in
        7) key=proxmox-release-bullseye.gpg ;;
        8) key=proxmox-release-bookworm.gpg ;;
        9) key=proxmox-archive-keyring-trixie.gpg ;;
    esac
    curl --fail --silent --show-error --location --retry 3 \
        "https://enterprise.proxmox.com/debian/$key" -o /usr/share/keyrings/proxmox-container.gpg
    gpg --batch --show-keys /usr/share/keyrings/proxmox-container.gpg >/dev/null
    # APT verifies the signed Release and package checksums over HTTP.
    printf 'deb [signed-by=/usr/share/keyrings/proxmox-container.gpg] %s %s pve-no-subscription\n' \
        "$repository" "$VERSION_CODENAME" > /etc/apt/sources.list.d/pve-container.list
fi
apt-get update -o APT::Update::Error-Mode=any -o Acquire::Retries=3
firmware_candidate=$(LC_ALL=C apt-cache policy python3-virt-firmware | awk '/Candidate:/{print $2}')
if [[ "$architecture:$major" == arm64:8 && ( -z "$firmware_candidate" || "$firmware_candidate" == '(none)' ) ]]; then
    # PXVIRT's newest bookworm qemu-server requires an unavailable dependency.
    # Select the newest fully installable ARM package without bypassing dpkg.
    compatible=
    while read -r candidate; do
        dependencies=$(apt-cache show "qemu-server=$candidate" | sed -n '/^Depends:/{p;q;}')
        if [[ -n "$dependencies" && "$dependencies" != *python3-virt-firmware* ]]; then
            compatible=$candidate
            break
        fi
    done < <(apt-cache madison qemu-server | awk '{print $3}')
    [[ -n "$compatible" ]] || { echo 'No installable ARM64 qemu-server package' >&2; exit 1; }
    printf 'Package: qemu-server\nPin: version %s\nPin-Priority: 1001\n' "$compatible" \
        > /etc/apt/preferences.d/pve-arm-qemu-server-compat.pref
    echo "ARM64 bookworm compatibility: qemu-server=$compatible"
fi
# pve-manager includes the VM and CT tools. The proxmox-ve metapackage would
# additionally install a host kernel, which a Docker container cannot boot.
if [[ "$major" == 7 ]]; then
    # PVE 7's ifupdown2 postinst uses this installer marker to defer ifreload.
    # A Docker image build must not apply network configuration.
    touch /proxmox_install_mode
fi
apt-get install -y --no-install-recommends pve-manager
if [[ "$architecture" == arm64 ]]; then
    # PXVIRT's manager package adds an unscoped, hard-coded bookworm source,
    # including on trixie. Keep only the signed source selected above.
    rm -f /etc/apt/sources.list.d/pxvirt-sources.list
    apt-get update -o APT::Update::Error-Mode=any -o Acquire::Retries=3
fi
if [[ "$major" == 7 ]]; then
    rm -f /proxmox_install_mode /tmp/.ifupdown2-first-install
fi
dpkg-query -W -f='${Status}\n' pve-manager | grep -qx 'install ok installed'
dpkg-query -W -f='${Version}\n' pve-manager | grep -E "^${major}\."
test -x /usr/sbin/qm
test -x /usr/sbin/pct
mkdir -p /usr/share/pve-container
python3 - "$distribution" "$repository" "$VERSION_CODENAME" "$architecture" <<'PY'
import json, subprocess, sys
from pathlib import Path
packages={name:subprocess.check_output(['dpkg-query','-W','-f=${Version}',name],text=True)
          for name in ['pve-manager','qemu-server','pve-qemu-kvm']}
Path('/usr/share/pve-container/build-info.json').write_text(json.dumps(dict(
    distribution=sys.argv[1],repository=sys.argv[2],suite=sys.argv[3],architecture=sys.argv[4],
    packages=packages),indent=2)+'\n')
PY
if [[ "$architecture" == arm64 ]]; then
    # Older PXVIRT CA generators omit keyCertSign, rejected by Python 3.13+
    # and other clients using strict X.509 validation. Only future CA creation
    # is amended; existing cluster certificates are never replaced here.
    if [[ "$major" == 9 ]]; then
        python3 /usr/local/lib/pve-container/patch-arm-ca.py /usr/share/perl5/PVE/Cluster/Setup.pm
        # Debian's ARM rrdcached package only supplies a SysV init script.
        # Use its default paths/options in a native unit for container boots.
        if [[ ! -f /usr/lib/systemd/system/rrdcached.service ]]; then
            cat > /etc/systemd/system/rrdcached.service <<'EOF'
[Unit]
Description=RRD cache daemon
After=local-fs.target
Before=pve-cluster.service

[Service]
Type=forking
PIDFile=/run/rrdcached.pid
ExecStartPre=/usr/bin/install -d /var/lib/rrdcached/db /var/lib/rrdcached/journal
ExecStart=/usr/bin/rrdcached -B -b /var/lib/rrdcached/db/ -j /var/lib/rrdcached/journal/ -p /run/rrdcached.pid -l unix:/run/rrdcached.sock
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
            systemctl enable rrdcached
        fi
    fi
    mkdir -p /etc/systemd/system/pveproxy.service.d
    cat > /etc/systemd/system/pveproxy.service.d/container-certificates.conf <<'EOF'
[Service]
ExecStartPre=
ExecStartPre=-/usr/bin/pvecm updatecerts --silent
ExecStartPre=/usr/local/sbin/pve-container-certificates
TimeoutStartSec=180
EOF
fi
systemctl enable pve-cluster pvedaemon pveproxy pvestatd ssh
passwd -l root
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub /etc/machine-id /usr/sbin/policy-rc.d
touch /etc/machine-id
apt-get clean
rm -rf /var/lib/apt/lists/*
