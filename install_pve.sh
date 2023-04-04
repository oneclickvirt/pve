#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }

# 前置环境安装
if [ "$(id -u)" != "0" ]; then
   _red "This script must be run as root" 1>&2
   exit 1
fi
apt-get update -y
if [ $? -ne 0 ]; then
   dpkg --configure -a
   apt-get update -y
fi
if [ $? -ne 0 ]; then
   apt-get install gnupg -y
fi
output=$(apt-get update 2>&1)
if echo $output | grep -q "NO_PUBKEY"; then
   _yellow "try “ sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys missing key ” to fix"
   exit 1
fi
if ! command -v wget > /dev/null 2>&1; then
      apt-get install -y wget
fi
if ! command -v curl > /dev/null 2>&1; then
      apt-get install -y curl
fi
if ! command -v sudo > /dev/null 2>&1; then
      apt-get install -y sudo
fi
if ! command -v bc > /dev/null 2>&1; then
      apt-get install -y bc
fi
if ! command -v iptables > /dev/null 2>&1; then
      apt-get install -y iptables
fi

# /etc/hosts文件修改
ip=$(curl -s ipv4.ip.sb)
hostname=$(hostname)
if [ "${hostname}" != "pve" ]; then
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
   hostnamectl set-hostname pve
   hostname=$(hostname)
   if ! grep -q "::1 localhost" /etc/hosts; then
       echo "::1 localhost" >> /etc/hosts
       echo "Added ::1 localhost to /etc/hosts"
   fi
   # if grep -q "^127\.0\.0\.1 localhost$" /etc/hosts; then
   #     sed -i '/^127\.0\.0\.1 localhost$/ s/^/#/' /etc/hosts
   #     echo "Commented out 127.0.0.1 localhost in /etc/hosts"
   # fi
   if ! grep -q "^127\.0\.0\.1 localhost\.localdomain localhost$" /etc/hosts; then
       # 127.0.1.1
       echo "${ip} ${hostname}.localdomain ${hostname}" >> /etc/hosts
       echo "Added ${ip} ${hostname}.localdomain ${hostname} to /etc/hosts"
   fi
   # if ! grep -q "${ip} pve.proxmox.com pve" /etc/hosts; then
   #     echo "${ip} pve.proxmox.com pve" >> /etc/hosts
   #     echo "Added ${ip} pve.proxmox.com pve to /etc/hosts"
   # fi
   sudo chattr +i /etc/hosts
fi

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

# 6.x
if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg" ]; then
  wget http://download.proxmox.com/debian/proxmox-ve-release-6.x.gpg -O /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
  chmod +r /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
fi

# 7.x
if [ ! -f "/etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg" ]; then
  wget http://download.proxmox.com/debian/proxmox-release-bullseye.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
  chmod +r /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
fi

if ! grep -q "^deb.*pve-no-subscription" /etc/apt/sources.list; then
   echo "$repo_url" >> /etc/apt/sources.list
fi

# 下载pve
apt-get update -y && apt-get full-upgrade -y
if [ $? -ne 0 ]; then
   apt-get install debian-keyring debian-archive-keyring -y
   apt-get update -y && apt-get full-upgrade -y
fi
output=$(apt-get update 2>&1)
if echo $output | grep -q "NO_PUBKEY"; then
  echo "Some keys are missing, attempting to retrieve them now..."
  missing_keys=$(echo $output | grep "NO_PUBKEY" | awk -F' ' '{print $NF}')
  for key in $missing_keys; do
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys $key
  done
  apt-get update
else
  echo "All keys are present."
fi
output=$(apt-get update 2>&1)
if echo $output | grep -q "NO_PUBKEY"; then
   _yellow "try sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys missing key"
   exit 1
fi
apt-get install -y proxmox-ve postfix open-iscsi

# 安装必备模块并替换apt源中的无效订阅
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak
echo "deb http://download.proxmox.com/debian/pve $(lsb_release -sc) pve-no-subscription" > /etc/apt/sources.list.d/pve-enterprise.list
apt-get update
install_required_modules() {
    modules=("sudo" "ifupdown2" "lshw" "iproute2" "net-tools" "cloud-init" "novnc" "isc-dhcp-server")
    for module in "${modules[@]}"
    do
        if dpkg -s $module > /dev/null 2>&1 ; then
            _green "$module 已经安装！"
        else
            apt-get install -y $module
            _green "$module 已成功安装！"
        fi
    done
}
install_required_modules

# 更新内核
# apt-get install -y pve-kernel-5.4.98-1-pve
update-grub
# apt-get remove -y linux-image*

# 打印安装后的信息
url="https://${ip}:8006/"
_green "安装完毕，请打开HTTPS网页 $url"
_green "用户名、密码就是服务器所使用的用户名、密码(如root和root用户的密码)"


