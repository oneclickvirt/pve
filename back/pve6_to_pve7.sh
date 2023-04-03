#!/bin/bash
#from https://github.com/spiritLHLS/pve
# pve 6 to pve 7

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 用户执行脚本"
    exit 1
fi

# 删除企业源
rm -rf /etc/apt/sources.list.d/pve-enterprise.list

# 卸载无关内核
current_kernel=$(uname -r)
_yellow "当前内核: $current_kernel"
installed_kernels=$(dpkg -l | grep -E 'linux-(image|headers)-[0-9]+' | grep -v "$current_kernel" | awk '{print $2}')
if [ -z "$installed_kernels" ]; then
  _blue "无闲置的内核"
else
  _yellow "卸载闲置内核..."
  for kernel in $installed_kernels; do
    _yellow "卸载内核: $kernel"
    dpkg --purge --force-remove-essential $kernel
    apt-get remove -y $kernel > /dev/null 2>&1
  done
  _green "闲置内核已卸载完毕"
fi

# 升级为debian11系统
curl -L https://raw.githubusercontent.com/spiritLHLS/one-click-installation-script/main/todebian11.sh -o todebian11.sh && chmod +x todebian11.sh && bash todebian11.sh

# 检查 PVE 是否可以升级
if ! pve6to7 | grep -q "FAILURES: 0"; then
    _red "检测到 PVE 升级存在问题，请先解决问题后再执行升级"
    exit 1
fi

# 检查 PVE 版本是否为最新版本
if ! [ "$(pveversion -v)" = "$(pveversion -r)" ]; then
    _yellow "当前 PVE 版本不是最新版本，尝试升级到最新版本"
    apt-get update && apt-get dist-upgrade -y
    if [ $? -ne 0 ]; then
        _red "升级 PVE 失败，请检查网络或源配置"
        exit 1
    else
        _green "PVE 升级到最新版本成功"
        exit 1
    fi
fi
