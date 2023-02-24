#!/bin/bash
#from https://github.com/spiritLHLS/pve
# pve 7


# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 前置环境安装
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi
apt-get update -y
if ! command -v wget > /dev/null 2>&1; then
      apt-get install -y wget
fi
if ! command -v curl > /dev/null 2>&1; then
      apt-get install -y curl
fi
curl -L https://raw.githubusercontent.com/spiritLHLS/one-click-installation-script/main/check_sudo.sh -o check_sudo.sh && chmod +x check_sudo.sh && bash check_sudo.sh > /dev/null 2>&1
# sysctl -w net.ipv6.conf.all.disable_ipv6=1
# sysctl -w net.ipv6.conf.default.disable_ipv6=1

## China_IP
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

# 修改 /etc/hosts
hostnamectl set-hostname pve
ip=$(curl -s ipv4.ip.sb)
echo "127.0.0.1 localhost.localdomain localhost" | tee -a /etc/hosts
echo "${ip} pve.proxmox.com pve" | tee -a /etc/hosts

# 再次预检查 
apt-get install gnupg -y
if ! nc -z localhost 7789; then
  iptables -A INPUT -p tcp --dport 7789 -j ACCEPT
  iptables-save > /etc/iptables.rules
fi
if [ $(uname -m) != "x86_64" ] || [ ! -f /etc/debian_version ] || [ $(grep MemTotal /proc/meminfo | awk '{print $2}') -lt 2000000 ] || [ $(grep -c ^processor /proc/cpuinfo) -lt 2 ] || [ $(ping -c 3 google.com > /dev/null 2>&1; echo $?) -ne 0 ]; then
  _red "Error: This system does not meet the minimum requirements for Proxmox VE installation."
  exit 1
else
  _green "The system meets the minimum requirements for Proxmox VE installation."
fi

# 新增pve源
version=$(lsb_release -cs)
case $version in
  jessie|stretch|buster|bullseye)
    repo_url="deb http://download.proxmox.com/debian/pve ${version} pve-no-subscription"
    if [[ -n "${CN}" ]]; then
      repo_url="deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve ${version} pve-no-subscription"
    fi
    ;;
  *)
    _red "Error: Unsupported Debian version"
    exit 1
    ;;
esac
wget http://download.proxmox.com/debian/proxmox-release-bullseye.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
apt-key add /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
echo "$repo_url" >> /etc/apt/sources.list

# 下载pve
apt-get update && apt-get full-upgrade
if [ $? -ne 0 ]; then
   apt-get install debian-keyring debian-archive-keyring -y
   apt-get update && apt-get full-upgrade
fi
apt-get -y install postfix open-iscsi
apt-get -y install proxmox-ve 

# 打印安装后的信息
url="https://${ip}:8006/"
_green "安装完毕，请打开HTTPS网页 $url"
_green "用户名、密码就是服务器所使用的用户名、密码"


