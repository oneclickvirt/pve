#!/bin/bash
#from https://github.com/spiritLHLS/pve

for vmid in $(qm list | awk '{if(NR>1) print $1}'); do qm stop $vmid; qm destroy $vmid; rm -rf /var/lib/vz/images/$vmid*; done
iptables -t nat -F
iptables -t filter -F
service networking restart
systemctl restart networking.service
rm -rf vm*
pct list | awk 'NR>1{print $1}' | xargs -I {} sh -c 'pct stop {}; pct destroy {}'
rm -rf ct*
iptables -t nat -F
iptables -t filter -F
service networking restart
systemctl restart networking.service
systemctl stop pve-cluster.service
systemctl stop pvedaemon.service
systemctl stop pvestatd.service
systemctl stop pveproxy.service
# apt-get remove --purge -y proxmox-ve 
apt-get remove --purge -y pve-manager 
apt-get remove --purge -y pve-kernel-4.15 
apt-get remove --purge -y pve-kernel-5.11
apt-get remove --purge -y postfix
apt-get remove --purge -y open-iscsi
touch '/please-remove-proxmox-ve'
apt-get purge proxmox-ve -y
apt-get autoremove -y
sudo dpkg --configure -a
sudo apt-get install -f
sudo dpkg --remove --force-remove-reinstreq initramfs-tools
sudo apt-get purge initramfs-tools

if [ -f /etc/network/interfaces.d/50-cloud-init.bak ]; then
    chattr -i /etc/network/interfaces.d/50-cloud-init
    mv /etc/network/interfaces.d/50-cloud-init.bak /etc/network/interfaces.d/50-cloud-init
    chattr +i /etc/network/interfaces.d/50-cloud-init
fi
systemctl stop check-dns.service
systemctl disable check-dns.service
rm /usr/local/bin/check-dns.sh
rm /etc/systemd/system/check-dns.service
if [ -f /etc/resolv.conf.bak ]; then
    chattr -i /etc/resolv.conf
    mv /etc/resolv.conf.bak /etc/resolv.conf
    chattr +i /etc/resolv.conf
fi
systemctl daemon-reload
systemctl restart networking
sed -i '/^deb.*pve-no-subscription/d' /etc/apt/sources.list
rm -f /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
rm -f /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
rm -rf /etc/pve/
rm -rf /var/lib/vz/
rm -rf /var/lib/mysql/
rm -rf /var/log/pve/
rm -rf /var/log/mysql/
rm -rf /var/spool/postfix/
apt-get autoremove -y
# reboot
