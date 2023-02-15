#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 检查CPU是否支持硬件虚拟化
if [ "$(egrep -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    echo "ERROR: CPU does not support hardware virtualization"
    exit 1
fi

# 检查虚拟化选项是否启用
if [ "$(grep -E -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    echo "ERROR: Hardware virtualization is not enabled in the BIOS"
    exit 1
fi

# 检查KVM模块是否已加载
if lsmod | grep -q kvm; then
    echo "KVM module is already loaded"
else
    # 加载KVM模块并将其添加到/etc/modules文件中
    modprobe kvm
    echo "kvm" >> /etc/modules
    echo "KVM module has been loaded and added to /etc/modules"
fi
