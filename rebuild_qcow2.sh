#!/bin/bash

apt-get update
apt-get install libguestfs-tools
sudo apt-get install rng-tools

qcow_file=/root/qcow/ubuntu22.qcow2
echo "启用SSH功能..."
virt-customize -a $qcow_file --run-command "systemctl enable ssh"
virt-customize -a $qcow_file --run-command "systemctl start ssh"
echo "启用root登录..."
virt-customize -a $qcow_file --run-command "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config"
virt-customize -a $qcow_file --run-command "systemctl restart sshd"
echo "创建备份..."
cp $qcow_file ${qcow_file}.bak
echo "复制新文件..."
cp $qcow_file ${qcow_file}.tmp
echo "覆盖原文件..."
mv ${qcow_file}.tmp $qcow_file
rm -rf *.bak
echo "修改完成"
