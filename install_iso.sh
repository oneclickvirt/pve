#!/bin/bash
#from https://github.com/spiritLHLS/pve

echo "请选择要下载到的模板目录："
echo "1. Proxmox VE 的模板目录（/var/lib/vz/template/iso/）"
echo "2. LXC 的模板目录（/var/lib/vz/template/cache/）"
echo "3. 全都要"
read -p "请输入选项编号（1或2）: " choice

# 下载Ubuntu和Debian的最新系统镜像
wget -P /root/ https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
wget -P /root/ https://github.com/spiritLHLS/pve/releases/download/debian-11.6.0-amd64-netinst.iso/debian-11.6.0-amd64-netinst.iso

# 将镜像文件移动到Proxmox VE的模板目录中
case "$choice" in
  1)
    mv /root/focal-server-cloudimg-amd64.img /var/lib/vz/template/iso/
    mv /root/debian-11.6.0-amd64-netinst.iso /var/lib/vz/template/iso/
    echo "已将镜像文件移动到 Proxmox VE 的模板目录"
    ;;
  2)
    mv /root/focal-server-cloudimg-amd64.img /var/lib/vz/template/cache/
    mv /root/debian-11.6.0-amd64-netinst.iso /var/lib/vz/template/cache/
    echo "已将镜像文件移动到 LXC 的模板目录"
    ;;
  3)
    cp /root/focal-server-cloudimg-amd64.img /var/lib/vz/template/iso/
    cp /root/debian-11.6.0-amd64-netinst.iso /var/lib/vz/template/iso/
    mv /root/focal-server-cloudimg-amd64.img /var/lib/vz/template/cache/
    mv /root/debian-11.6.0-amd64-netinst.iso /var/lib/vz/template/cache/
    ;;
  *)
    echo "无效的选项，程序退出"
    ;;
esac
