#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 创建资源池
_green "正在创建资源池 mypool..."
pvesh create /pools --poolid mypool
_green "资源池 mypool 已创建！"

# 安装必备模块
apt-get update
apt-get install -y sudo 
apt-get install -y ifupdown2
apt-get install -y lshw
apt-get install -y iproute2 
apt-get install -y net-tools
apt-get install -y cloud-init


# 检测AppArmor模块
if ! dpkg -s apparmor > /dev/null 2>&1; then
    _green "正在安装 AppArmor..."
    apt-get update
    apt-get install -y apparmor
fi
if ! systemctl is-active --quiet apparmor.service; then
    _green "启动 AppArmor 服务..."
    systemctl enable apparmor.service
    systemctl start apparmor.service
fi
if ! lsmod | grep -q apparmor; then
    _green "正在加载 AppArmor 内核模块..."
    modprobe apparmor
fi
if ! lsmod | grep -q apparmor; then
    _yellow "AppArmor 仍未加载，可能需要重新启动系统加载，但你可以在面板尝试创建并启动CT"
fi
