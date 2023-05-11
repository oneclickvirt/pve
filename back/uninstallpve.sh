#!/bin/bash
#from https://github.com/spiritLHLS/pve

systemctl stop pve-cluster.service
systemctl stop pvedaemon.service
systemctl stop pvestatd.service
systemctl stop pveproxy.service
apt-get remove --purge -y proxmox-ve pve-manager pve-kernel-4.15 pve-kernel-5.11
apt-get remove --purge -y postfix
apt-get remove --purge -y open-iscsi
rm -rf /etc/pve/
rm -rf /var/lib/vz/
rm -rf /var/lib/mysql/
rm -rf /var/log/pve/
rm -rf /var/log/mysql/
rm -rf /var/spool/postfix/
# reboot
