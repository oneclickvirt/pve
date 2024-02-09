#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2024.02.08

if [ -f "/etc/resolv.conf" ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak
    echo "nameserver 8.8.8.8" | tee -a /etc/resolv.conf >/dev/null
    echo "nameserver 8.8.4.4" | tee -a /etc/resolv.conf >/dev/null
fi
temp_file_apt_fix="/tmp/apt_fix.txt"
REGEX=("debian|astra|devuan" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "freebsd" "opensuse")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "FreeBSD" "opensuse")
PACKAGE_UPDATE=("! apt-get update && apt-get --fix-broken install -y && apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy" "pkg update" "zypper update")
PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install" "pacman -Sy --noconfirm --needed" "pkg install -y" "zypper install -y")
PACKAGE_REMOVE=("apt-get -y remove" "apt-get -y remove" "yum -y remove" "yum -y remove" "yum -y remove" "pacman -Rsc --noconfirm" "pkg delete" "zypper remove")
PACKAGE_UNINSTALL=("apt-get -y autoremove" "apt-get -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "" "pkg autoremove" "zypper autoremove")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(uname -s)")
SYS="${CMD[0]}"
[[ -n $SYS ]] || exit 1
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done
[[ -z $SYSTEM ]] && exit 1
[[ $EUID -ne 0 ]] && exit 1
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    echo "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    echo "Locale set to $utf8_locale"
fi

check_china() {
    echo "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            echo "根据ipapi.co提供的信息，当前IP可能在中国"
            CN=true
        else
            if [[ $? -ne 0 ]]; then
                if [[ $(curl -m 6 -s cip.cc) =~ "中国" ]]; then
                    echo "根据cip.cc提供的信息，当前IP可能在中国"
                    CN=true
                fi
            fi
        fi
    fi
}

change_debian_apt_sources() {
    cp /etc/apt/sources.list /etc/apt/sources.list.bak
    echo "backup the current /etc/apt/sources.list to /etc/apt/sources.list.bak"
    DEBIAN_VERSION=$(lsb_release -sr)
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        URL="http://deb.debian.org/debian"
    else
        # Use mirrors.aliyun.com sources list if IP is in China
        URL="http://mirrors.aliyun.com/debian"
    fi

    case $DEBIAN_VERSION in
    6*) DEBIAN_RELEASE="squeeze" ;;
    7*) DEBIAN_RELEASE="wheezy" ;;
    8*) DEBIAN_RELEASE="jessie" ;;
    9*) DEBIAN_RELEASE="stretch" ;;
    10*) DEBIAN_RELEASE="buster" ;;
    11*) DEBIAN_RELEASE="bullseye" ;;
    12*) DEBIAN_RELEASE="bookworm" ;;
    *) echo "The system is not Debian 6/7/8/9/10/11/12 . No changes were made to the apt-get sources." && return 1 ;;
    esac

    cat >/etc/apt/sources.list <<EOF
deb ${URL} ${DEBIAN_RELEASE} main contrib non-free
deb ${URL} ${DEBIAN_RELEASE}-updates main contrib non-free
deb ${URL} ${DEBIAN_RELEASE}-backports main contrib non-free
deb-src ${URL} ${DEBIAN_RELEASE} main contrib non-free
deb-src ${URL} ${DEBIAN_RELEASE}-updates main contrib non-free
deb-src ${URL} ${DEBIAN_RELEASE}-backports main contrib non-free
EOF
}

checkupdate() {
    if command -v apt-get >/dev/null 2>&1; then
        apt_update_output=$(apt-get update 2>&1)
        echo "$apt_update_output" >"$temp_file_apt_fix"
        if grep -q 'NO_PUBKEY' "$temp_file_apt_fix"; then
            public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file_apt_fix" | awk '{ print $2 }')
            joined_keys=$(echo "$public_keys" | paste -sd " ")
            echo "No Public Keys: ${joined_keys}"
            apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${joined_keys}
            apt-get update
            if [ $? -eq 0 ]; then
                _green "Fixed"
            fi
        fi
        rm "$temp_file_apt_fix"
    else
        ${PACKAGE_UPDATE[int]}
    fi
}

install_required_modules() {
    modules=("sshpass" "openssh-server")
    for module in "${modules[@]}"; do
        if command -v apt-get >/dev/null 2>&1; then
            if dpkg -s $module >/dev/null 2>&1; then
                echo "$module has benn installed."
            else
                apt-get install -y $module
                if [ $? -ne 0 ]; then
                    apt-get install -y $module --fix-missing
                fi
                echo "$module has been tried and installed!"
            fi
        else
            ${PACKAGE_INSTALL[int]} $module
        fi
    done
    if command -v apt-get >/dev/null 2>&1; then
        ${PACKAGE_INSTALL[int]} cron
    else
        ${PACKAGE_INSTALL[int]} cronie
    fi
}

remove_duplicate_lines() {
    awk '!NF || !x[$0]++' "$1" >"$1.tmp" && mv -f "$1.tmp" "$1"
}

check_china
if [[ "${CN}" == true ]]; then
    if [[ "${SYSTEM}" == "Debian" ]]; then
        change_debian_apt_sources
    fi
fi
checkupdate
install_required_modules
if [ -f "/etc/motd" ]; then
    echo '' >/etc/motd
    echo 'Related repo https://github.com/spiritLHLS/pve' >>/etc/motd
    echo '--by https://t.me/spiritlhl' >>/etc/motd
fi
service iptables stop 2>/dev/null
chkconfig iptables off 2>/dev/null
if [ -f "/etc/sysconfig/selinux" ]; then
    sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/sysconfig/selinux
fi
if [ -f "/etc/selinux/config" ]; then
    sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/selinux/config
fi
setenforce 0
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#\?Port.*/Port 22/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
    sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
    sed -i 's/#AddressFamily any/AddressFamily any/' /etc/ssh/sshd_config
    sed -i '/^#UsePAM\|UsePAM/c #UsePAM no' /etc/ssh/sshd_config
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/g' /etc/ssh/sshd_config
    sed -i '/^AuthorizedKeysFile/s/^/#/' /etc/ssh/sshd_config
fi
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
    sed -i "s/^#\?Port.*/Port 22/g" /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/#AddressFamily any/AddressFamily any/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i '/^#UsePAM\|UsePAM/c #UsePAM no' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/g" /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i '/^AuthorizedKeysFile/s/^/#/' /etc/ssh/sshd_config.d/50-cloud-init.conf
fi
remove_duplicate_lines "/etc/ssh/sshd_config"
if command -v service >/dev/null 2>&1; then
    service ssh restart
    service sshd restart
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart sshd
    systemctl restart ssh
fi
sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf
rm -rf "$0"
