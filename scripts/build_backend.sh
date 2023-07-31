#!/bin/bash
# from 
# https://github.com/spiritLHLS/pve
# 2023.07.30


# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
  echo "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
  echo "Locale set to $utf8_locale"
fi

if [ -f "/root/build_backend_pve.txt" ]; then
    _green "You have already executed this script, if you have already rebooted your system, please execute the subsequent script commands to automatically configure the gateway, if you have not rebooted your system, please reboot your system"
    _grenn "Do not run this script repeatedly"
    _green "你已执行过本脚本，如果已重启过系统，请执行后续的自动配置网关的脚本命令，如果未重启过系统，请重启系统"
    _grenn "不要重复运行本脚本"
    exit 1
fi

# 创建资源池
POOL_ID="mypool"
if pvesh get /pools/$POOL_ID > /dev/null 2>&1 ; then
    _green "Resource pool $POOL_ID already exists!"
    _green "资源池 $POOL_ID 已经存在！"
else
    # 如果不存在则创建
    _green "Creating resource pool $POOL_ID..."
    _green "正在创建资源池 $POOL_ID..."
    pvesh create /pools --poolid $POOL_ID
    _green "Resource pool $POOL_ID has been created!"
    _green "资源池 $POOL_ID 已创建！"
fi

# 移除订阅弹窗
pve_version=$(dpkg-query -f '${Version}' -W proxmox-ve 2>/dev/null | cut -d'-' -f1)
if [[ "$pve_version" == 8.* ]]; then
    # pve8.x
    cp -rf /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak
    sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
elif [[ "$pve_version" == 7.* ]]; then
    # pve7.x
    cp -rf /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak
    sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
elif [[ "$pve_version" == 6.* ]]; then
    # pve6.x
    cp -rf /usr/share/pve-manager/js/pvemanagerlib.js /usr/share/pve-manager/js/pvemanagerlib.js.bak
    sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/pve-manager/js/pvemanagerlib.js
else
    # 不支持的版本
    echo "Unsupported Proxmox VE version: $pve_version"
fi

# 开启硬件直通
if [ `dmesg | grep -e DMAR -e IOMMU|wc -l` = 0 ];then
    _yellow "Hardware does not support passthrough"
    _yellow "硬件不支持直通"
else
    if [ `cat /proc/cpuinfo|grep Intel|wc -l` = 0 ];then
       iommu="amd_iommu=on"
    else
       iommu="intel_iommu=on"
    fi
    if [ `grep $iommu /etc/default/grub|wc -l` = 0 ];then
        sed -i 's|quiet|quiet '$iommu'|' /etc/default/grub
        update-grub
        if [ `grep "vfio" /etc/modules|wc -l` = 0 ];then
            echo 'vfio
            vfio_iommu_type1
            vfio_pci
            vfio_virqfd' >> /etc/modules
        fi
    else
        _green "Hardware passthrough is set"
        _green "已设置硬件直通"
    fi
fi

# 检测AppArmor模块
if ! dpkg -s apparmor > /dev/null 2>&1; then
    _green "AppArmor is being installed..."
    _green "正在安装 AppArmor..."
    apt-get update
    apt-get install -y apparmor
fi
if [ $? -ne 0 ]; then
    apt-get install -y apparmor --fix-missing
fi
if ! systemctl is-active --quiet apparmor.service; then
    _green "Starting the AppArmor service..."
    _green "启动 AppArmor 服务..."
    systemctl enable apparmor.service
    systemctl start apparmor.service
fi
if ! lsmod | grep -q apparmor; then
    _green "Loading AppArmor kernel module..."
    _green "正在加载 AppArmor 内核模块..."
    modprobe apparmor
fi
sleep 3
installed_kernels=($(dpkg -l 'pve-kernel-*' | awk '/^ii/ {print $2}' | cut -d'-' -f3- | sort -V))
if [ ${#installed_kernels[@]} -gt 0 ]; then
    latest_kernel=${installed_kernels[-1]}
    _green "PVE latest kernel: $latest_kernel"
    _yellow "Please execute reboot to reboot the system to load the PVE kernel."
    _yellow "请执行 reboot 重新启动系统加载PVE内核"
else
    _yellow "The current kernel is already a PVE kernel, no need to reboot the system to update the kernel"
    _yellow "当前内核已是PVE内核，无需重启系统更新内核"
fi
echo "1" > "/root/build_backend_pve.txt"
