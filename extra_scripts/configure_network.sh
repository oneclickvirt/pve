#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.06.25

# 检查是否存在 "iface eth0 inet6 auto" 行
if ! grep -q "iface eth0 inet6 auto" /etc/network/interfaces; then
    # 追加 "iface eth0 inet6 auto" 行到文件末尾
    chattr -i /etc/network/interfaces
    echo "iface eth0 inet6 auto" >>/etc/network/interfaces
    chattr +i /etc/network/interfaces
fi

if ! grep -q "pre-up echo 2 > /proc/sys/net/ipv6/conf/all/accept_ra" /etc/network/interfaces; then
    # 追加 "pre-up echo 2 > /proc/sys/net/ipv6/conf/all/accept_ra" 行到文件末尾
    chattr -i /etc/network/interfaces
    echo "pre-up echo 2 > /proc/sys/net/ipv6/conf/all/accept_ra" >>/etc/network/interfaces
    chattr +i /etc/network/interfaces
fi

# 重新加载网络配置
ifreload -ad
