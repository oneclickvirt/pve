#!/bin/bash
# by https://github.com/spiritLHLS/pve

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'")
RELEASE=("debian" "ubuntu" "centos" "centos")
PACKAGE_UPDATE=("apt -y update" "apt -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove")

[[ $EUID -ne 0 ]] && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")
for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
done

[[ -z $SYSTEM ]] && exit 1
sshport=22
service iptables stop 2> /dev/null ; chkconfig iptables off 2> /dev/null ;
sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/sysconfig/selinux;
sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/selinux/config;
setenforce 0;
apt-get install sshpass -y;
apt-get install openssh-server -y;
sed -i "s/^#\?Port.*/Port $sshport/g" /etc/ssh/sshd_config;
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config;
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config;
sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
sed -i 's/#AddressFamily any/AddressFamily any/' /etc/ssh/sshd_config
service ssh restart
service sshd restart
rm -rf "$0"
