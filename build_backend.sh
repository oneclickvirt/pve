#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 打印信息
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

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

# 安装必备模块并替换apt源中的无效订阅
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak
echo "deb http://download.proxmox.com/debian/pve $(lsb_release -sc) pve-no-subscription" > /etc/apt/sources.list.d/pve-enterprise.list
apt-get update
install_required_modules() {
    modules=("sudo" "ifupdown2" "lshw" "iproute2" "net-tools" "cloud-init" "novnc" "isc-dhcp-server")
    for module in "${modules[@]}"
    do
        if dpkg -s $module > /dev/null 2>&1 ; then
            _green "$module 已经安装！"
        else
            apt-get install -y $module
            _green "$module 已成功安装！"
        fi
    done
}
install_required_modules

# 更新内核
# apt-get install -y pve-kernel-5.4.98-1-pve
update-grub
apt-get remove -y linux-image*

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
    _yellow "AppArmor 仍未加载，需要重新启动系统加载"
fi
