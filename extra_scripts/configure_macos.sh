#!/bin/bash
# from https://github.com/oneclickvirt/pve
# 2025.05.08

echo 1 | tee /sys/module/kvm/parameters/ignore_msrs
grep -Fxq 'options kvm ignore_msrs=Y' /etc/modprobe.d/kvm.conf || echo 'options kvm ignore_msrs=Y' >> /etc/modprobe.d/kvm.conf && update-initramfs -k all -u
if [ "$(lscpu | grep -i 'Vendor ID' | grep -i amd | wc -l)" -eq 1 ]; then
    CPU_TYPE="AMD"
else
    CPU_TYPE="INTEL"
fi
if [ ! -e /etc/pve/qemu-server/.macos_preset ]; then
    echo "未检测到预设配置，正在安装依赖与配置系统（Installing prerequisites and configuring system）..."
    apt update && apt install -y vim sysstat parted iptraf
    if [ $? -ne 0 ]; then
        echo "软件包安装失败（Package installation failed）"
        exit 1
    fi
    echo "set mouse-=a" > ~/.vimrc
    sed -i 's/GRUB_TIMEOUT=5/GRUB_TIMEOUT=0/g' /etc/default/grub
    PVE_VERSION=$(pveversion)
    if [ "$CPU_TYPE" == "AMD" ]; then
        if echo "$PVE_VERSION" | grep -qE '7\.[2-4]|8\.[0-4]'; then
            CMDLINE='quiet amd_iommu=on iommu=pt video=vesafb:off video=efifb:off initcall_blacklist=sysfb_init'
        else
            CMDLINE='quiet amd_iommu=on iommu=pt video=vesafb:off video=efifb:off'
        fi
        echo "options kvm-amd nested=1" > /etc/modprobe.d/kvm-amd.conf
    else
        if echo "$PVE_VERSION" | grep -qE '7\.[2-4]|8\.[0-4]'; then
            CMDLINE='quiet intel_iommu=on iommu=pt video=vesafb:off video=efifb:off initcall_blacklist=sysfb_init'
        else
            CMDLINE='quiet intel_iommu=on iommu=pt video=vesafb:off video=efifb:off'
        fi
        echo "options kvm-intel nested=Y" > /etc/modprobe.d/kvm-intel.conf
    fi
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE\"/g" /etc/default/grub
    cat <<EOF >> /etc/modules
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF
    cat <<EOF >> /etc/modprobe.d/pve-blacklist.conf
blacklist nouveau
blacklist nvidia
blacklist snd_hda_codec_hdmi
blacklist snd_hda_intel
blacklist snd_hda_codec
blacklist snd_hda_core
blacklist radeon
blacklist amdgpu
EOF
    echo "options kvm ignore_msrs=Y report_ignored_msrs=0" > /etc/modprobe.d/kvm.conf
    echo "options vfio_iommu_type1 allow_unsafe_interrupts=1" > /etc/modprobe.d/iommu_unsafe_interrupts.conf
    sed -i.backup -z "s/res === null || res === undefined || \!res || res\n\t\t\t.data.status.toLowerCase() \!== 'active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    touch /etc/pve/qemu-server/.macos_preset
    update-grub
    echo "配置完成，15 秒后重启（Configuration completed. Rebooting in 15 seconds）..."
    sleep 15 && reboot
fi
