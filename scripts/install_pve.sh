#!/bin/bash
# from 
# https://github.com/spiritLHLS/pve
# 2023.06.22

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
  echo "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
  echo "Locale set to $utf8_locale"
fi
temp_file_apt_fix="/tmp/apt_fix.txt"

# 前置环境安装
if [ "$(id -u)" != "0" ]; then
   _red "This script must be run as root" 1>&2
   exit 1
fi
apt-get update -y
apt-get upgrade -y systemd
if [ $? -ne 0 ]; then
   dpkg --configure -a
   apt-get update -y
fi
if [ $? -ne 0 ]; then
   apt-get install gnupg -y
fi
apt_update_output=$(apt-get update 2>&1)
echo "$apt_update_output" > "$temp_file_apt_fix"
if grep -q 'NO_PUBKEY' "$temp_file_apt_fix"; then
    public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file_apt_fix" | awk '{ print $2 }')
    joined_keys=$(echo "$public_keys" | paste -sd " ")
    _yellow "No Public Keys: ${joined_keys}"
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${joined_keys}
    apt-get update
    if [ $? -eq 0 ]; then
        _green "Fixed"
    fi
fi
rm "$temp_file_apt_fix"

remove_duplicate_lines() {
  # 去除重复行并跳过空行
  if [ -f "$1" ];then
      awk '!NF || !x[$0]++' "$1" > "$1.tmp" && mv -f "$1.tmp" "$1"
  fi
}

install_package() {
    package_name=$1
    if command -v $package_name > /dev/null 2>&1 ; then
        _green "$package_name 已经安装"
    else
        apt-get install -y $package_name
        if [ $? -ne 0 ]; then
                  apt-get install -y $package_name --fix-missing
              fi
        _green "$package_name 已尝试安装"
    fi
}

check_cdn() {
  local o_url=$1
  for cdn_url in "${cdn_urls[@]}"; do
    if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" > /dev/null 2>&1; then
      export cdn_success_url="$cdn_url"
      return
    fi
    sleep 0.5
  done
  export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, no use CDN"
    fi
}

cdn_urls=("https://cdn.spiritlhl.workers.dev/" "https://cdn3.spiritlhl.net/" "https://cdn1.spiritlhl.net/" "https://ghproxy.com/" "https://cdn2.spiritlhl.net/")
install_package wget
install_package curl
install_package sudo
install_package bc
install_package iptables
check_cdn_file

# cloud-init文件修改
rebuild_cloud_init(){
if [ -f "/etc/cloud/cloud.cfg" ]; then
  chattr -i /etc/cloud/cloud.cfg
  if grep -q "preserve_hostname: true" "/etc/cloud/cloud.cfg"; then
    :
  else
    sed -E -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' "/etc/cloud/cloud.cfg"
    echo "change preserve_hostname to true"
  fi
  if grep -q "disable_root: false" "/etc/cloud/cloud.cfg"; then
    :
  else
    sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' "/etc/cloud/cloud.cfg"
    echo "change disable_root to false"
  fi
  chattr -i /etc/cloud/cloud.cfg
  content=$(cat /etc/cloud/cloud.cfg)
  line_number=$(grep -n "^system_info:" "/etc/cloud/cloud.cfg" | cut -d ':' -f 1)
  if [ -n "$line_number" ]; then
    lines_after_system_info=$(echo "$content" | sed -n "$((line_number+1)),\$p")
    if [ -n "$lines_after_system_info" ]; then
      updated_content=$(echo "$content" | sed "$((line_number+1)),\$d")
      echo "$updated_content" > "/etc/cloud/cloud.cfg"
    fi
  fi
  sed -i '/^\s*- set-passwords/s/^/#/' /etc/cloud/cloud.cfg
  chattr +i /etc/cloud/cloud.cfg
fi
}
rebuild_cloud_init

# 检测IPV4
ip=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)

# /etc/hosts文件修改
hostname=$(hostname)
if [ "${hostname}" != "pve" ]; then
    chattr -i /etc/hosts
    hosts=$(grep -E "^[^#]*\s+${hostname}\s+${hostname}\$" /etc/hosts | grep -v "${ip}")
    if [ -n "${hosts}" ]; then
        # 注释掉查询到的行
        sudo sed -i "s/^$(echo ${hosts} | sed 's/\//\\\//g')/# &/" /etc/hosts
        # 添加新行
        # echo "${ip} ${hostname} ${hostname}" | sudo tee -a /etc/hosts > /dev/null
        # _green "已将 ${ip} ${hostname} ${hostname} 添加到 /etc/hosts 文件中"
    else
        _blue "已存在 ${ip} ${hostname} ${hostname} 的记录，无需添加"
    fi
    chattr -i /etc/hostname
    hostnamectl set-hostname pve
    chattr +i /etc/hostname
    hostname=$(hostname)
    if ! grep -q "::1 localhost" /etc/hosts; then
        echo "::1 localhost" >> /etc/hosts
        echo "Added ::1 localhost to /etc/hosts"
    fi
    if grep -q "^127\.0\.1\.1" /etc/hosts; then
        sed -i '/^127\.0\.1\.1/s/^/#/' /etc/hosts
        echo "Commented out lines starting with 127.0.1.1 in /etc/hosts"
    fi
    if ! grep -q "^127\.0\.0\.1 localhost\.localdomain localhost$" /etc/hosts; then
        # 127.0.1.1
        echo "${ip} ${hostname}.localdomain ${hostname}" >> /etc/hosts
        echo "Added ${ip} ${hostname}.localdomain ${hostname} to /etc/hosts"
    fi
    chattr +i /etc/hosts
fi

## 更改网络优先级为IPV4优先
sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf && systemctl restart networking

## ChinaIP检测
if [[ -z "${CN}" ]]; then
  if [[ $(curl -m 10 -s https://ipapi.co/json | grep 'China') != "" ]]; then
      _yellow "根据ipapi.co提供的信息，当前IP可能在中国"
      read -e -r -p "是否选用中国镜像完成安装? [Y/n] " input
      case $input in
          [yY][eE][sS] | [yY])
              echo "使用中国镜像"
              CN=true
          ;;
          [nN][oO] | [nN])
              echo "不使用中国镜像"
          ;;
          *)
              echo "使用中国镜像"
              CN=true
          ;;
      esac
  fi
fi

# 再次预检查 
apt-get install gnupg -y
if [ $(uname -m) != "x86_64" ] || [ ! -f /etc/debian_version ] || [ $(grep MemTotal /proc/meminfo | awk '{print $2}') -lt 2000000 ] || [ $(grep -c ^processor /proc/cpuinfo) -lt 2 ] || [ $(ping -c 3 google.com > /dev/null 2>&1; echo $?) -ne 0 ]; then
  _red "Error: This system does not meet the minimum requirements for Proxmox VE installation."
  reading "是否要继续安装(非Debian系或不满足最低的配置安装要求会爆上面这个警告)？(回车则默认不继续安装) [y/n] " confirm
  echo ""
  if [ "$confirm" != "y" ]; then
    exit 1
  fi
else
  _green "The system meets the minimum requirements for Proxmox VE installation."
fi

# 新增pve源
apt-get install lsb-release -y
version=$(lsb_release -cs)
case $version in
  stretch|buster|bullseye)
    repo_url="deb http://download.proxmox.com/debian/pve ${version} pve-no-subscription"
    if [[ -n "${CN}" ]]; then
      repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve ${version} pve-no-subscription"
    fi
    ;;
  bookworm)
    repo_url="deb http://download.proxmox.com/debian/pve ${version} pvetest"
    if [[ -n "${CN}" ]]; then
      repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve ${version} pvetest"
    fi
    ;;
  *)
    _red "Error: Unsupported Debian version"
    reading "是否要继续安装(非Debian系会爆上面这个警告)？(回车则默认不继续安装) [y/n] " confirm
    echo ""
    if [ "$confirm" != "y" ]; then
      exit 1
    fi
    repo_url="deb http://download.proxmox.com/debian/pve bullseye pve-no-subscription"
    if [[ -n "${CN}" ]]; then
      repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve bullseye pve-no-subscription"
    fi
    ;;
esac

case $version in
  stretch)
    if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-4.x.gpg" ]; then
      wget http://download.proxmox.com/debian/proxmox-ve-release-4.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-4.x.gpg
      chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-4.x.gpg
    fi
    if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg" ]; then
      wget http://download.proxmox.com/debian/proxmox-ve-release-6.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
      chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
    fi
    ;;
  buster)
    if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-5.x.gpg" ]; then
      wget http://download.proxmox.com/debian/proxmox-ve-release-5.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-5.x.gpg
      chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-5.x.gpg
    fi
    if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg" ]; then
      wget http://download.proxmox.com/debian/proxmox-ve-release-6.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
      chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
    fi
    ;;
  bullseye)
    if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg" ]; then
      wget http://download.proxmox.com/debian/proxmox-ve-release-6.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
      chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
    fi
    if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg" ]; then
      wget http://download.proxmox.com/debian/proxmox-release-bullseye.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
      chmod +r /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
    fi
    ;;
  bookworm)
    if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg" ]; then
      wget http://download.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
      chmod +r /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
    fi
    ;;
  *)
    _red "Error: Unsupported Debian version"
    reading "是否要继续安装(非Debian系会爆上面这个警告)？(回车则默认不继续安装) [y/n] " confirm
    echo ""
    if [ "$confirm" != "y" ]; then
      exit 1
    fi
    ;;
esac

if ! grep -q "^deb.*pve-no-subscription" /etc/apt/sources.list; then
    echo "$repo_url" >> /etc/apt/sources.list
fi

# 备份网络设置
cp /etc/network/interfaces /etc/network/interfaces.bak
cp /etc/network/interfaces.new /etc/network/interfaces.new.bak
cp /etc/network/interfaces.d/50-cloud-init /etc/network/interfaces.d/50-cloud-init.bak
rebuild_interfaces

rebuild_interfaces(){
# 修复部分网络加载未空
if [ ! -e /run/network/interfaces.d/* ]; then
    if [ -f "/etc/network/interfaces" ];then
        chattr -i /etc/network/interfaces
        sed -i '/source-directory \/run\/network\/interfaces.d/s/^/#/' /etc/network/interfaces
        chattr +i /etc/network/interfaces
    fi
    if [ -f "/etc/network/interfaces.new" ];then
        chattr -i /etc/network/interfaces.new
        sed -i '/source-directory \/run\/network\/interfaces.d/s/^/#/' /etc/network/interfaces.new
        chattr +i /etc/network/interfaces.new
    fi
fi
# 修复部分网络加载没实时加载
if [[ -f "/etc/network/interfaces.new" && -f "/etc/network/interfaces" ]]; then
    chattr -i /etc/network/interfaces
    cp -f /etc/network/interfaces.new /etc/network/interfaces
    chattr +i /etc/network/interfaces
fi
# 修复部分网络加载中有重复内容
if [[ -f "/etc/network/interfaces.d/50-cloud-init" && -f "/etc/network/interfaces" ]]; then
    if grep -q "auto lo" "/etc/network/interfaces.d/50-cloud-init" && grep -q "iface lo inet loopback" "/etc/network/interfaces.d/50-cloud-init" && grep -q "auto lo" "/etc/network/interfaces" && grep -q "iface lo inet loopback" "/etc/network/interfaces"; then
        # 从 /etc/network/interfaces.d/50-cloud-init 中删除指定的行
        chattr -i /etc/network/interfaces.d/50-cloud-init
        sed -i '/auto lo/d' "/etc/network/interfaces.d/50-cloud-init"
        sed -i '/iface lo inet loopback/d' "/etc/network/interfaces.d/50-cloud-init"
        chattr +i /etc/network/interfaces.d/50-cloud-init
    fi
fi
# 去除空行之外的重复行
remove_duplicate_lines "/etc/network/interfaces"
remove_duplicate_lines "/etc/network/interfaces.new"
remove_duplicate_lines "/etc/network/interfaces.d/50-cloud-init"
}

# 下载pve
apt-get update -y && apt-get full-upgrade -y
if [ $? -ne 0 ]; then
    apt-get install debian-keyring debian-archive-keyring -y
    apt-get update -y && apt-get full-upgrade -y
fi
apt_update_output=$(apt-get update 2>&1)
echo "$apt_update_output" > "$temp_file_apt_fix"
if grep -q 'NO_PUBKEY' "$temp_file_apt_fix"; then
    public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file_apt_fix" | awk '{ print $2 }')
    joined_keys=$(echo "$public_keys" | paste -sd " ")
    _yellow "No Public Keys: ${joined_keys}"
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${joined_keys}
    apt-get update
    if [ $? -eq 0 ]; then
        _green "Fixed"
    fi
fi
rm "$temp_file_apt_fix"
output=$(apt-get update 2>&1)
if echo $output | grep -q "NO_PUBKEY"; then
    _yellow "try sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys missing key"
    exit 1
fi
install_package proxmox-ve
install_package postfix
install_package open-iscsi
rebuild_interfaces

# 如果是国内服务器则替换CT源为国内镜像源
if [[ -n "${CN}" ]]; then
    cp -rf /usr/share/perl5/PVE/APLInfo.pm /usr/share/perl5/PVE/APLInfo.pm.bak
    sed -i 's|http://download.proxmox.com|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
	  sed -i 's|http://mirrors.ustc.edu.cn/proxmox|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
fi

# 安装必备模块并替换apt源中的无效订阅
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak
# echo "deb http://download.proxmox.com/debian/pve $(lsb_release -sc) pve-no-subscription" > /etc/apt/sources.list.d/pve-enterprise.list
rm -rf /etc/apt/sources.list.d/pve-enterprise.list
apt-get update
install_package sudo
install_package lshw
install_package iproute2
install_package ifupdown2
install_package net-tools
install_package novnc
install_package cloud-init
rebuild_cloud_init
# install_package isc-dhcp-server

# 打印内核
running_kernel=$(uname -r)
_green "Running kernel: $(pveversion)"
installed_kernels=($(dpkg -l 'pve-kernel-*' | awk '/^ii/ {print $2}' | cut -d'-' -f3- | sort -V))
latest_kernel=${installed_kernels[-1]}
_green "PVE latest kernel: $latest_kernel"
# update-grub
install_package ipcalc
# 检查/etc/network/interfaces是否有source /etc/network/interfaces.d/*行
if grep -q "source /etc/network/interfaces.d/*" /etc/network/interfaces; then
  # 检查/etc/network/interfaces.d/文件夹下是否有50-cloud-init文件
  if [ -f /etc/network/interfaces.d/50-cloud-init ]; then
    # 检查50-cloud-init文件中是否有iface eth0 inet dhcp行 - 看来还是得转动态为静态判断东西
    if grep -q "iface eth0 inet dhcp" /etc/network/interfaces.d/50-cloud-init; then
      # 获取ipv4、subnet、gateway信息
      gateway=$(ip route | awk '/default/ {print $3}')
      eth0info=$(ip -o -4 addr show dev eth0 | awk '{print $4}')
      ipv4=$(echo $eth0info | cut -d'/' -f1)
      subnet=$(echo $eth0info | cut -d'/' -f2)
      subnet=$(ipcalc -n "$ipv4/$subnet" | grep -oP 'Netmask:\s+\K.*' | awk '{print $1}')
      chattr -i /etc/network/interfaces.d/50-cloud-init
      sed -i "/iface eth0 inet dhcp/c\
        iface eth0 inet static\n\
        address $ipv4\n\
        netmask $subnet\n\
        gateway $gateway\n\
        dns-nameservers 8.8.8.8 8.8.4.4" /etc/network/interfaces.d/50-cloud-init
    fi
    if ! grep -q "iface ${interface} inet manual" "$interfaces_file" && ! grep -q "iface ${interface} inet manual" /etc/network/interfaces.d/50-cloud-init; then
	echo "Can not find 'iface ${interface} inet manual' in ${interfaces_file} or /etc/network/interfaces.d/50-cloud-init"
	echo "iface ${interface} inet manual" >> "$interfaces_file"
    fi
    chattr +i /etc/network/interfaces.d/50-cloud-init
  fi
fi
systemctl restart networking
if [ ! -s "/etc/resolv.conf" ]
then
    cp /etc/resolv.conf /etc/resolv.conf.bak
    chattr -i /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    chattr +i /etc/resolv.conf
fi
wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/check-dns.sh -O /usr/local/bin/check-dns.sh
wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/check-dns.service -O /etc/systemd/system/check-dns.service
chmod +x /usr/local/bin/check-dns.sh
chmod +x /etc/systemd/system/check-dns.service
systemctl daemon-reload
systemctl enable check-dns.service
systemctl start check-dns.service
# 打印安装后的信息
url="https://${ip}:8006/"
_green "安装完毕，请打开HTTPS网页 $url"
_green "用户名、密码就是服务器所使用的用户名、密码(如root和root用户的密码)"
_green "如果登录无误请不要急着重启系统，去执行预配置环境的命令后再重启系统"
