#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.07.31

# 安装ifupdown2
apt-get install -y ifupdown2
echo "1" >"/usr/local/bin/ifupdown2_installed.txt"

# 删除Systemd服务
systemctl disable ifupdown2-install.service
rm /etc/systemd/system/ifupdown2-install.service

# 删除自身
rm $0
