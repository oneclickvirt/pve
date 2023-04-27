#!/bin/bash
#from https://github.com/spiritLHLS/pve

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

# 创建资源池
POOL_ID="mypool"
if pvesh get /pools/$POOL_ID > /dev/null 2>&1 ; then
    _green "资源池 $POOL_ID 已经存在！"
else
    # 如果不存在则创建
    _green "正在创建资源池 $POOL_ID..."
    pvesh create /pools --poolid $POOL_ID
    _green "资源池 $POOL_ID 已创建！"
fi

# 移除订阅弹窗
pve_version=$(dpkg-query -f '${Version}' -W proxmox-ve 2>/dev/null | cut -d'-' -f1)
if [[ "$pve_version" == 7.* ]]; then
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
       _green "已设置硬件直通"
    fi
fi

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
    _yellow "AppArmor 仍未加载，需要执行 reboot 重新启动系统加载"
fi
