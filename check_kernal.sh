#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 检查CPU是否支持硬件虚拟化
if [ "$(egrep -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    _red "CPU不支持硬件虚拟化，无法嵌套虚拟化KVM服务器，但可以开LXC服务器(CT)"
    exit 1
fi

# 检查虚拟化选项是否启用
if [ "$(grep -E -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    _red "BIOS中未启用硬件虚拟化，无法嵌套虚拟化KVM服务器，但可以开LXC服务器(CT)"
    exit 1
fi

# 查询系统是否支持
if [ "$(cat /sys/module/kvm_intel/parameters/nested)" = "Y" ]; then
    _green "本机操作系统支持KVM硬件嵌套虚拟化，使用PVE虚拟化出来的KVM服务器可以在选项中开启KVM硬件虚拟化"
else
    _yellow "本机操作系统不支持KVM硬件嵌套虚拟化，使用PVE虚拟化出来的KVM服务器不能在选项中开启KVM硬件虚拟化"
fi

# 检查KVM模块是否已加载
if lsmod | grep -q kvm; then
    _green "KVM模块已经加载，可以使用PVE虚拟化KVM服务器"
else
    # 加载KVM模块并将其添加到/etc/modules文件中
    modprobe kvm
    echo "kvm" >> /etc/modules
    _green "KVM模块已加载并添加到 /etc/modules 可以使用PVE虚拟化KVM服务器，也可以开LXC服务器(CT)"
fi
