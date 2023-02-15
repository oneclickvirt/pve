#!/bin/bash
#from https://github.com/spiritLHLS/pve

# 下载Ubuntu和Debian的最新系统镜像
wget -P /root/ https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
wget -P /root/ https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-11.1.0-amd64-netinst.iso

# 将镜像文件移动到Proxmox VE的模板目录中
mv /root/focal-server-cloudimg-amd64.img /var/lib/vz/template/iso/
mv /root/debian-11.1.0-amd64-netinst.iso /var/lib/vz/template/iso/
