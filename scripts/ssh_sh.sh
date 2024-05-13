#!/bin/sh
# from
# https://github.com/oneclickvirt/pve
# 2024.03.12

if [ -f "/etc/resolv.conf" ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak
    echo "nameserver 8.8.8.8" | tee -a /etc/resolv.conf >/dev/null
    echo "nameserver 8.8.4.4" | tee -a /etc/resolv.conf >/dev/null
fi
config_dir="/etc/ssh/sshd_config.d/"
for file in "$config_dir"*
do
    if [ -f "$file" ] && [ -r "$file" ]; then
        if grep -q "PasswordAuthentication no" "$file"; then
            sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file"
            echo "File $file updated"
        fi
    fi
done
if [ "$(cat /etc/os-release | grep -E '^ID=' | cut -d '=' -f 2 | tr -d '"')" == "alpine" ]; then
    apk update
    apk add --no-cache openssh-server
    apk add --no-cache sshpass
    apk add --no-cache openssh-keygen
    apk add --no-cache bash
    apk add --no-cache curl
    apk add --no-cache wget
    apk add --no-cache lsof
    cd /etc/ssh
    ssh-keygen -A
    chattr -i /etc/ssh/sshd_config
    sed -i '/^#PermitRootLogin\|PermitRootLogin/c PermitRootLogin yes' /etc/ssh/sshd_config
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config
    sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
    sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
    sed -i '/^#AddressFamily\|AddressFamily/c AddressFamily any' /etc/ssh/sshd_config
    sed -i "s/^#\?\(Port\).*/\1 22/" /etc/ssh/sshd_config
    sed -i -E 's/^#?(Port).*/\1 22/' /etc/ssh/sshd_config
    sed -i '/^#UsePAM\|UsePAM/c #UsePAM no' /etc/ssh/sshd_config
    sed -E -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
    sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' /etc/cloud/cloud.cfg
    sed -E -i 's/ssh_pwauth:[[:space:]]*false/ssh_pwauth:   true/g' /etc/cloud/cloud.cfg
    /usr/sbin/sshd
    rc-update add sshd default
    chattr +i /etc/ssh/sshd_config
elif [ "$(cat /etc/os-release | grep -E '^ID=' | cut -d '=' -f 2 | tr -d '"')" == "openwrt" ]; then
    opkg update
    opkg install openssh-server
    opkg install bash
    opkg install openssh-keygen
    opkg install shadow-chpasswd
    opkg install chattr
    opkg install cronie
    opkg install cron
    /etc/init.d/sshd enable
    /etc/init.d/sshd start
    cd /etc/ssh
    ssh-keygen -A
    chattr -i /etc/ssh/sshd_config
    sed -i "s/^#\?Port.*/Port 22/g" /etc/ssh/sshd_config
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config
    sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
    sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
    sed -i 's/#AddressFamily any/AddressFamily any/' /etc/ssh/sshd_config
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/g" /etc/ssh/sshd_config
    sed -i '/^AuthorizedKeysFile/s/^/#/' /etc/ssh/sshd_config
    chattr +i /etc/ssh/sshd_config
    /etc/init.d/sshd restart
elif [ "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" =~ *"Arch"* ]; then
    curl -slk https://raw.githubusercontent.com/SuperManito/LinuxMirrors/main/ChangeMirrors.sh -o ChangeMirrors.sh
    chmod 777 ChangeMirrors.sh
    ./ChangeMirrors.sh --use-official-source --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
    rm -rf /etc/pacman.d/gnupg/
    pacman-key --init
    pacman-key --populate archlinux
    pacman -Syyuu
    pacman -Sy --needed openssh
    pacman -Sy --needed bash
    pacman -Sy --needed chattr
    pacman -Sy --needed cronie
    pacman -Sy --needed cron
    systemctl enable sshd
    systemctl start sshd
    chattr -i /etc/ssh/sshd_config
    sed -i "s/^#\?Port.*/Port 22/g" /etc/ssh/sshd_config
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config
    sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
    sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
    sed -i 's/#AddressFamily any/AddressFamily any/' /etc/ssh/sshd_config
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/g" /etc/ssh/sshd_config
    sed -i '/^AuthorizedKeysFile/s/^/#/' /etc/ssh/sshd_config
    chattr +i /etc/ssh/sshd_config
    systemctl restart sshd
fi
# gentoo
/etc/init.d/cron enable || true
/etc/init.d/cron start || true
if [ -f "/etc/motd" ]; then
    echo '' >/etc/motd
    echo 'Related repo https://github.com/oneclickvirt/pve_lxc_images' >>/etc/motd
    echo '--by https://t.me/spiritlhl' >>/etc/motd
fi
if [ -f "/etc/banner" ]; then
    echo '' >/etc/banner
    echo 'Related repo https://github.com/oneclickvirt/pve_lxc_images' >>/etc/banner
    echo '--by https://t.me/spiritlhl' >>/etc/banner
fi
rm -f "$0"
