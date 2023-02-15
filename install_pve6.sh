#!/bin/bash
#from https://github.com/spiritLHLS/pve
# pve 6

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 前置环境安装
if [ "$(id -u)" != "0" ]; then
   _red "This script must be run as root" 1>&2
   exit 1
fi
if ! command -v wget > /dev/null 2>&1; then
      apt-get install -y wget
fi
if ! command -v curl > /dev/null 2>&1; then
      apt-get install -y curl
fi
curl -L https://raw.githubusercontent.com/spiritLHLS/one-click-installation-script/main/check_sudo.sh -o check_sudo.sh && chmod +x check_sudo.sh && bash check_sudo.sh > /dev/null 2>&1
hostnamectl set-hostname pve
ip=$(curl -s ipv4.ip.sb)
echo "127.0.0.1 localhost.localdomain localhost" | tee -a /etc/hosts
echo "${ip} pve.proxmox.com pve" | tee -a /etc/hosts

# 再次预检查 
apt-get install gnupg -y
if [ $(uname -m) != "x86_64" ] || [ ! -f /etc/debian_version ] || [ $(grep MemTotal /proc/meminfo | awk '{print $2}') -lt 2000000 ] || [ $(grep -c ^processor /proc/cpuinfo) -lt 2 ] || [ $(ping -c 3 google.com > /dev/null 2>&1; echo $?) -ne 0 ]; then
  _red "Error: This system does not meet the minimum requirements for Proxmox VE installation."
  exit 1
else
  _green "The system meets the minimum requirements for Proxmox VE installation."
fi

# 新增pve源
version=$(lsb_release -cs)
if [ "$version" == "jessie" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve jessie pve-no-subscription"
elif [ "$version" == "stretch" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve stretch pve-no-subscription"
elif [ "$version" == "buster" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve buster pve-no-subscription"
elif [ "$version" == "bullseye" ]; then
  repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve bullseye pve-no-subscription"
else
  _red "Error: Unsupported Debian version"
  exit 1
fi
wget http://download.proxmox.com/debian/proxmox-ve-release-6.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
echo "$repo_url" >> /etc/apt/sources.list

# 下载pve
apt-get update -y && apt-get full-upgrade -y
if [ $? -ne 0 ]; then
   apt-get install debian-keyring debian-archive-keyring -y
   apt-get update -y && apt-get full-upgrade -y
fi
apt -y install proxmox-ve postfix open-iscsi

# 打印安装后的信息
url="https://${ip}:8006/"
_green "安装完毕，请打开HTTPS网页 $url"
_green "用户名、密码就是服务器所使用的用户名、密码"


