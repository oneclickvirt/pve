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

ip=$(curl -s ipv4.ip.sb)
line_number=$(tac /etc/hosts | grep -n "^127\.0\.0\.1" | head -n 1 | awk -F: '{print $1}')
echo "$ip pve.proxmox.com pve" | tee -a /etc/hosts > /dev/null
sed -i "${line_number} a $ip pve.proxmox.com pve" /etc/hosts

version=$(lsb_release -cs)
if [ "$version" == "jessie" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve jessie pve-no-subscription"
elif [ "$version" == "stretch" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve stretch pve-no-subscription"
elif [ "$version" == "buster" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve buster pve-no-subscription"
  wget https://github.com/spiritLHLS/pve/raw/main/gpg/proxmox-release-buster.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-buster.gpg
  apt-key add /etc/apt/trusted.gpg.d/proxmox-release-buster.gpg
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

apt-get update && apt-get full-upgrade
apt-get install debian-keyring debian-archive-keyring -y
apt-get autoremove
apt-get update
apt-get -y install proxmox-ve postfix open-iscsi
# rm /etc/apt/sources.list.d/pve-install-repo.list

