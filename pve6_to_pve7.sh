#!/bin/bash
#from https://github.com/spiritLHLS/pve
# pve 6 to pve 7

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 删除企业源
rm -rf /etc/apt/sources.list.d/pve-enterprise.list

# 检测是否可升级
output=$(pve6to7)
if echo "$output" | grep -q "FAILURES: 0" > /dev/null 2>&1; then
  _green "支持升级PVE7"
else
  echo "$output"
  _red "不支持升级PVE7"
  exit 1
fi

# 升级PVE7
apt update && apt dist-upgrade -y

# 卸载无关内核
current_kernel=$(uname -r)
_yellow "当前内核: $current_kernel"
installed_kernels=$(dpkg -l | grep -E 'linux-(image|headers)-[0-9]+' | grep -v "$current_kernel" | awk '{print $2}')
if [ -z "$installed_kernels" ]; then
  _blue "无闲置的内核"
else
  _yellow "Uninstalling unused kernels..."
  for kernel in $installed_kernels; do
    _yellow "Uninstalling kernel: $kernel"
    dpkg --purge --force-remove-essential $kernel
    apt-get remove -y $kernel > /dev/null 2>&1
  done
  _green "闲置内核已卸载完毕"
fi

# 升级内核
update-grub

# 打印信息
_green "请执行reboot启用新内核"
