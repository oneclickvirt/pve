#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2024.03.12

# 清理路由缓存
sleep 5
systemctl stop networking.service
ip addr flush dev eth0
systemctl start networking.service

# 删除Systemd服务
systemctl disable clear_interface_route_cache.service
rm /etc/systemd/system/clear_interface_route_cache.service

# 删除自身
rm $0
