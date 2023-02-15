#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 检查CPU是否支持硬件虚拟化
if [ "$(egrep -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    echo "CPU不支持硬件虚拟化，无法嵌套虚拟化KVM服务器"
    exit 1
fi

# 检查虚拟化选项是否启用
if [ "$(grep -E -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    echo "BIOS中未启用硬件虚拟化，无法嵌套虚拟化KVM服务器"
    exit 1
fi

# 检查KVM模块是否已加载
if lsmod | grep -q kvm; then
    echo "KVM模块已经加载"
else
    # 加载KVM模块并将其添加到/etc/modules文件中
    modprobe kvm
    echo "kvm" >> /etc/modules
    echo "KVM模块已加载并添加到 /etc/modules"
fi
