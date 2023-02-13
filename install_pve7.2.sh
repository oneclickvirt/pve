#!/bin/bash
#from https://github.com/spiritLHLS/pve
# pve 7.2


if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi
if ! command -v wget > /dev/null 2>&1; then
      apt-get install -y wget
fi
# echo "deb http://download.proxmox.com/debian/pve buster pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
echo "deb http://download.proxmox.com/debian/pve buster pve-no-subscription" >> /etc/apt/sources.list
wget http://download.proxmox.com/debian/proxmox-release-bullseye.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
apt-key add /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
# wget http://download.proxmox.com/debian/proxmox-release-buster.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-buster.gpg
# apt-key add /etc/apt/trusted.gpg.d/proxmox-release-buster.gpg
apt-get update
apt-get install debian-keyring debian-archive-keyring -y
apt-get autoremove
apt-get update
apt-get install proxmox-ve=7.2-1
rm /etc/apt/sources.list.d/pve-install-repo.list

