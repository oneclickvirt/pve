#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.03.04

########## 输出颜色函数

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }

export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    echo "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
fi

########## 权限检查

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root"
    _red "本脚本必须以 root 用户运行"
    exit 1
fi

########## 确认卸载

_yellow "==========================================="
_yellow " Proxmox VE Uninstall Script"
_yellow " PVE 一键卸载脚本"
_yellow "==========================================="
echo ""
_red "WARNING: This script will completely remove Proxmox VE and all related configurations!"
_red "警告：本脚本将彻底卸载 Proxmox VE 及所有相关配置！"
_red "All VMs and containers data under /var/lib/vz/ will be DELETED."
_red "所有位于 /var/lib/vz/ 下的虚拟机和容器数据将被删除。"
echo ""
reading "Are you sure you want to uninstall PVE? (Type 'yes' to confirm / 确认卸载请输入 yes): " confirm
if [ "$confirm" != "yes" ]; then
    _green "Uninstall cancelled."
    _green "已取消卸载。"
    exit 0
fi

echo ""
_yellow "Starting PVE uninstall process..."
_yellow "开始卸载 PVE..."
echo ""

########## 停止并删除所有虚拟机和容器

_yellow "[1/9] Stopping and removing all VMs and containers..."
_yellow "[1/9] 停止并删除所有虚拟机和容器..."

if command -v qm &>/dev/null; then
    vm_ids=$(qm list 2>/dev/null | awk 'NR>1 {print $1}')
    for vmid in $vm_ids; do
        _blue "Stopping VM $vmid..."
        qm stop "$vmid" --skiplock 1 2>/dev/null || true
        sleep 2
        qm destroy "$vmid" --purge 1 --skiplock 1 2>/dev/null || true
        _green "VM $vmid removed."
    done
fi

if command -v pct &>/dev/null; then
    ct_ids=$(pct list 2>/dev/null | awk 'NR>1 {print $1}')
    for ctid in $ct_ids; do
        _blue "Stopping CT $ctid..."
        pct stop "$ctid" 2>/dev/null || true
        sleep 2
        pct destroy "$ctid" 2>/dev/null || true
        _green "CT $ctid removed."
    done
fi

########## 停止 PVE 相关服务

_yellow "[2/9] Stopping PVE services..."
_yellow "[2/9] 停止 PVE 相关服务..."

pve_services=(
    pvedaemon pveproxy pvestatd pve-cluster
    pve-firewall pve-ha-crm pve-ha-lrm
    pvesr pvescheduler pve-guests
    spiceproxy
)
for svc in "${pve_services[@]}"; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
        systemctl stop "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
    fi
done

# 停止本项目安装时添加的辅助服务
extra_services=(
    check-dns
    ifupdown2-install
    clear_interface_route_cache
)
for svc in "${extra_services[@]}"; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
        systemctl stop "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
    fi
done

########## 恢复网络接口配置文件（仅修改文件，不操作运行中的网络接口，避免 SSH 断连）

_yellow "[3/9] Restoring network interface configuration (file-only, no live network changes)..."
_yellow "[3/9] 恢复网络接口配置（仅修改文件，不操作运行中网络，避免 SSH 断连）..."

# 解除 chattr 不可变属性
for f in /etc/network/interfaces /etc/network/interfaces.new; do
    [ -f "$f" ] && chattr -i "$f" 2>/dev/null || true
done

# 优先从安装时备份恢复原始网卡配置
if [ -f /etc/network/interfaces.bak ]; then
    cp -f /etc/network/interfaces.bak /etc/network/interfaces
    _green "Restored /etc/network/interfaces from backup."
elif [ -f /etc/network/interfaces_nat.bak ]; then
    cp -f /etc/network/interfaces_nat.bak /etc/network/interfaces
    _green "Restored /etc/network/interfaces from nat backup."
else
    # 无备份时：从当前 interfaces 文件中删除 vmbr0 相关块
    # 目的是让重启后物理网卡直接接管，而不是通过 vmbr0
    if grep -q "vmbr0" /etc/network/interfaces 2>/dev/null; then
        _yellow "No backup found, stripping vmbr0 blocks from /etc/network/interfaces..."
        tmp_if=$(mktemp)
        awk '
            /^(auto|iface|allow-hotplug)[[:space:]]+vmbr/ { skip=1 }
            skip && /^[[:space:]]/ { next }
            skip && /^[^[:space:]]/ { skip=0 }
            !skip { print }
        ' /etc/network/interfaces > "$tmp_if"
        mv -f "$tmp_if" /etc/network/interfaces
        _green "Removed vmbr0 blocks from /etc/network/interfaces."
    fi
fi

if [ -f /etc/network/interfaces.new.bak ]; then
    cp -f /etc/network/interfaces.new.bak /etc/network/interfaces.new
    _green "Restored /etc/network/interfaces.new from backup."
elif [ -f /etc/network/interfaces ]; then
    # 保持 interfaces.new 与 interfaces 同步
    cp -f /etc/network/interfaces /etc/network/interfaces.new 2>/dev/null || true
fi

_yellow "NOTE: vmbr0 will be fully removed after reboot. Do NOT reboot until this script finishes."
_yellow "注意：vmbr0 将在重启后自动消失，请勿在脚本执行完成前重启。"

########## 恢复其他系统配置备份

_yellow "[4/9] Restoring system configuration backups..."
_yellow "[4/9] 恢复系统配置备份..."

# 恢复 resolv.conf
if [ -f /etc/resolv.conf.bak ]; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cp -f /etc/resolv.conf.bak /etc/resolv.conf
    _green "Restored /etc/resolv.conf from backup."
fi

# 恢复 hostname
if [ -f /etc/hostname.bak ]; then
    chattr -i /etc/hostname 2>/dev/null || true
    cp -f /etc/hostname.bak /etc/hostname
    hostnamectl set-hostname "$(cat /etc/hostname.bak)"
    _green "Restored /etc/hostname from backup."
fi

# 恢复 hosts
if [ -f /etc/hosts.bak ]; then
    chattr -i /etc/hosts 2>/dev/null || true
    cp -f /etc/hosts.bak /etc/hosts
    _green "Restored /etc/hosts from backup."
fi

# 恢复 cloud.cfg
if [ -f /etc/cloud/cloud.cfg.bak ]; then
    chattr -i /etc/cloud/cloud.cfg 2>/dev/null || true
    cp -f /etc/cloud/cloud.cfg.bak /etc/cloud/cloud.cfg
    _green "Restored /etc/cloud/cloud.cfg from backup."
fi
# 清理 cloud-init 禁用标记
rm -f /etc/cloud/cloud-init.disabled

# 恢复 APT sources.list 备份
if [ -f /etc/apt/sources.list.bak ]; then
    cp -f /etc/apt/sources.list.bak /etc/apt/sources.list
    _green "Restored /etc/apt/sources.list from backup."
fi

########## 卸载 PVE 相关软件包

_yellow "[5/9] Purging PVE and related packages..."
_yellow "[5/9] 清除 PVE 及相关软件包..."

pve_packages=(
    proxmox-ve
    pve-manager
    pve-kernel-helper
    pve-cluster
    pve-container
    pve-docs
    pve-firewall
    pve-ha-manager
    pve-headers
    pve-i18n
    pve-xtermjs
    pve-edk2-firmware
    pve-edk2-firmware-aarch64
    proxmox-backup-file-restore
    proxmox-mini-journalreader
    proxmox-widget-toolkit
    pve-qemu-kvm
    corosync
    libpve-access-control
    libpve-cluster-perl
    libpve-common-perl
    libpve-guest-common-perl
    libpve-http-server-perl
    libpve-storage-perl
    libpve-network-perl
    libpve-rs-perl
    libproxmox-rs-perl
    libpve-apiclient-perl
    postfix
    open-iscsi
    novnc
    ifupdown2
    ufw
    apparmor
    pxvirt
)

# 批量卸载，忽略未安装的包
for pkg in "${pve_packages[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        apt-get purge -y "$pkg" 2>/dev/null || true
    fi
done

# 批量卸载所有 pve-kernel-* 内核包
pve_kernel_pkgs=$(dpkg -l 'pve-kernel-*' 2>/dev/null | awk '/^ii/ {print $2}')
if [ -n "$pve_kernel_pkgs" ]; then
    apt-get purge -y $pve_kernel_pkgs 2>/dev/null || true
fi

# 自动清理依赖
apt-get autoremove -y 2>/dev/null || true
apt-get autoclean -y 2>/dev/null || true

########## 删除 PVE APT 源和 GPG 密钥

_yellow "[6/9] Removing PVE APT sources and GPG keys..."
_yellow "[6/9] 删除 PVE APT 源和 GPG 密钥..."

# 从 /etc/apt/sources.list 删除 PVE 相关行
if [ -f /etc/apt/sources.list ]; then
    sed -i '/download\.proxmox\.com/d' /etc/apt/sources.list
    sed -i '/mirrors\.tuna\.tsinghua\.edu\.cn\/proxmox/d' /etc/apt/sources.list
    sed -i '/mirrors\.bfsu\.edu\.cn\/proxmox/d' /etc/apt/sources.list
    sed -i '/mirrors\.nju\.edu\.cn\/proxmox/d' /etc/apt/sources.list
    sed -i '/mirrors\.lierfang\.com\/pxcloud/d' /etc/apt/sources.list
    sed -i '/pve-no-subscription/d' /etc/apt/sources.list
    sed -i '/pve-test/d' /etc/apt/sources.list
    _green "Cleaned PVE entries from /etc/apt/sources.list."
fi

# 删除 PVE 专用 source 文件
pve_source_files=(
    /etc/apt/sources.list.d/pve-enterprise.list
    /etc/apt/sources.list.d/pve-enterprise.sources
    /etc/apt/sources.list.d/ceph.list
    /etc/apt/sources.list.d/ceph.sources
    /etc/apt/sources.list.d/pxvirt-sources.list
    /etc/apt/sources.list.d/proxmox-trixie.sources
)
for f in "${pve_source_files[@]}"; do
    [ -f "$f" ] && rm -f "$f" && _green "Removed $f."
done

# 删除 GPG 密钥
gpg_keys=(
    /etc/apt/trusted.gpg.d/proxmox-ve-release-4.x.gpg
    /etc/apt/trusted.gpg.d/proxmox-ve-release-5.x.gpg
    /etc/apt/trusted.gpg.d/proxmox-ve-release-6.x.gpg
    /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
    /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
    /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg
    /etc/apt/trusted.gpg.d/lierfang.gpg
)
for key in "${gpg_keys[@]}"; do
    [ -f "$key" ] && rm -f "$key" && _green "Removed $key."
done

########## 删除 PVE 数据目录和相关文件

_yellow "[7/9] Removing PVE data directories and files..."
_yellow "[7/9] 删除 PVE 数据目录及相关文件..."

# PVE 数据目录
pve_dirs=(
    /var/lib/vz
    /var/lib/pve-cluster
    /var/lib/pve-manager
    /var/lib/pve_firewall
    /var/log/pve
    /etc/pve
)
for d in "${pve_dirs[@]}"; do
    if [ -d "$d" ]; then
        rm -rf "$d"
        _green "Removed directory $d."
    fi
done

# 删除 systemd 服务文件
systemd_service_files=(
    /etc/systemd/system/check-dns.service
    /etc/systemd/system/ifupdown2-install.service
    /etc/systemd/system/clear_interface_route_cache.service
)
for f in "${systemd_service_files[@]}"; do
    [ -f "$f" ] && rm -f "$f" && _green "Removed service file $f."
done

# 删除持久化网络接口配置
[ -f /etc/systemd/network/10-persistent-net.link ] && rm -f /etc/systemd/network/10-persistent-net.link && _green "Removed 10-persistent-net.link."

# 删除 /usr/local/bin/ 下由本项目生成的文件
pve_local_files=(
    /usr/local/bin/pve_main_ipv4
    /usr/local/bin/pve_ipv4_address
    /usr/local/bin/pve_ipv4_gateway
    /usr/local/bin/pve_ipv4_subnet
    /usr/local/bin/pve_mac_address
    /usr/local/bin/pve_ipv6_gateway
    /usr/local/bin/pve_ipv6_prefixlen
    /usr/local/bin/pve_ipv6_real_prefixlen
    /usr/local/bin/pve_check_ipv6
    /usr/local/bin/pve_last_ipv6
    /usr/local/bin/pve_slaac_status
    /usr/local/bin/pve_maximum_subset
    /usr/local/bin/pve_appended_content.txt
    /usr/local/bin/fix_interfaces_ipv6_auto_type
    /usr/local/bin/build_backend_pve.txt
    /usr/local/bin/reboot_pve.txt
    /usr/local/bin/ifupdown2_installed.txt
    /usr/local/bin/check-dns.sh
    /usr/local/bin/install_ifupdown2.sh
    /usr/local/bin/clear_interface_route_cache.sh
)
for f in "${pve_local_files[@]}"; do
    [ -f "$f" ] && rm -f "$f" && _green "Removed $f."
done

# 恢复 APLInfo.pm 备份
if [ -f /usr/share/perl5/PVE/APLInfo.pm.bak ]; then
    cp -f /usr/share/perl5/PVE/APLInfo.pm.bak /usr/share/perl5/PVE/APLInfo.pm
    _green "Restored /usr/share/perl5/PVE/APLInfo.pm from backup."
fi

# 删除其他备份文件和临时文件
misc_files=(
    /etc/network/interfaces.bak
    /etc/network/interfaces.new.bak
    /etc/network/interfaces_nat.bak
    /etc/resolv.conf.bak
    /etc/hostname.bak
    /etc/hosts.bak
    /etc/apt/sources.list.bak
    /etc/cloud/cloud.cfg.bak
    /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak
    /tmp/apt_fix.txt
)
for f in "${misc_files[@]}"; do
    [ -f "$f" ] && rm -f "$f" && _green "Removed backup $f."
done

########## 恢复 gai.conf（IPv4优先级调整）

_yellow "[8/9] Restoring /etc/gai.conf..."
_yellow "[8/9] 恢复 /etc/gai.conf..."

if [ -f /etc/gai.conf ]; then
    sed -i 's/^precedence ::ffff:0:0\/96.*$/# precedence ::ffff:0:0\/96  100/' /etc/gai.conf
    _green "Reverted gai.conf IPv4 priority setting."
fi

# 删除 pveproxy 配置
[ -f /etc/default/pveproxy ] && rm -f /etc/default/pveproxy && _green "Removed /etc/default/pveproxy."

########## 重新加载 systemd 并更新 APT

_yellow "[9/9] Reloading systemd and updating APT..."
_yellow "[9/9] 重新加载 systemd 并更新 APT 缓存..."

systemctl daemon-reload
apt-get update -y 2>/dev/null || true

########## 完成

echo ""
_green "==========================================="
_green " PVE has been successfully uninstalled!"
_green " PVE 已成功卸载！"
_green "==========================================="
echo ""
_yellow "Please reboot the system to ensure all changes take effect."
_yellow "请重启系统以确保所有更改生效。"
_yellow "Execute: reboot"
_yellow "执行: reboot"
echo ""
