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
if ! command -v curl > /dev/null 2>&1; then
      apt-get install -y curl
fi

ip=$(curl -s ip.sb)
echo "$ip pve.proxmox.com pve" >> /etc/hosts

version=$(lsb_release -cs)
if [ "$version" == "jessie" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve jessie pve-no-subscription"
elif [ "$version" == "stretch" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve stretch pve-no-subscription"
elif [ "$version" == "buster" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve buster pve-no-subscription"
elif [ "$version" == "bullseye" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve bullseye pve-no-subscription"
  wget http://download.proxmox.com/debian/proxmox-release-bullseye.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
  apt-key add /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
else
  echo "Error: Unsupported Debian version"
  exit 1
fi
# echo "deb http://download.proxmox.com/debian/pve buster pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
echo "$repo_url" >> /etc/apt/sources.list

apt-get update
apt-get install debian-keyring debian-archive-keyring -y
apt-get autoremove
apt-get update
apt-get install -y proxmox-ve
rm /etc/apt/sources.list.d/pve-install-repo.list

