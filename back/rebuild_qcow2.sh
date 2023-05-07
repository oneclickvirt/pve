#!/bin/bash
# from https://github.com/spiritLHLS/pve

if ! command -v virt-customize &> /dev/null
then
    echo "virt-customize not found, installing libguestfs-tools"
    sudo apt-get update
    sudo apt-get install -y libguestfs-tools
    sudo apt-get install -y libguestfs-tools --fix-missing
fi

if ! command -v rngd &> /dev/null
then
    echo "rng-tools not found, installing rng-tools"
    sudo apt-get update
    sudo apt-get install -y rng-tools
    sudo apt-get install -y rng-tools --fix-missing
fi

# export LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1
qcow_file=$1
echo "转换文件$qcow_file中......"
# if [[ "$qcow_file" == *"alpine"* ]]; then
#     virt-sysprep --enable alpine -a "$qcow_file"
# elif [[ "$qcow_file" == *"centos"* ]]; then
#     virt-sysprep --enable centos -a "$qcow_file"
# elif [[ "$qcow_file" == *"almalinux"* ]]; then
#     virt-sysprep --enable almalinux -a "$qcow_file"
# fi
if [[ "$qcow_file" == *"debian"* || "$qcow_file" == *"ubuntu"* || "$qcow_file" == *"arch"* ]]; then
    virt-customize -a $qcow_file --run-command "sed -i 's/ssh_pwauth:[[:space:]]*0/ssh_pwauth: 1/g' /etc/cloud/cloud.cfg"
    virt-customize -a $qcow_file --run-command "echo 'Modified from https://github.com/spiritLHLS/Images' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo 'Related repo https://github.com/spiritLHLS/pve' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo '--by https://t.me/spiritlhl' >> /etc/motd"
    echo "启用SSH功能..."
    virt-customize -a $qcow_file --run-command "systemctl enable ssh"
    virt-customize -a $qcow_file --run-command "systemctl start ssh"
    virt-customize -a $qcow_file --run-command "systemctl enable sshd"
    virt-customize -a $qcow_file --run-command "systemctl start sshd"
    echo "启用root登录..."
    virt-customize -a $qcow_file --run-command "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#Port 22/Port 22/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#AddressFamily any/AddressFamily any/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#ListenAddress ::/ListenAddress ::/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "service ssh restart"
    virt-customize -a $qcow_file --run-command "service sshd restart"
    virt-customize -a $qcow_file --run-command "systemctl restart sshd"
    virt-customize -a $qcow_file --run-command "systemctl restart ssh"
    if [[ "$qcow_file" == *"debian"* || "$qcow_file" == *"ubuntu"* ]]; then
        virt-customize -a $qcow_file --run-command "apt-get update -y && apt-get install qemu-guest-agent -y"
        virt-customize -a $qcow_file --run-command "systemctl start qemu-guest-agent"
    fi
elif [[ "$qcow_file" == *"alpine"* ]]; then
    virt-customize -a $qcow_file --run-command "sed -i 's/disable_root:[[:space:]]*1/disable_root: 0/g' /etc/cloud/cloud.cfg"
    virt-customize -a $qcow_file --run-command "sed -i 's/ssh_pwauth:[[:space:]]*0/ssh_pwauth: 1/g' /etc/cloud/cloud.cfg"
    virt-customize -a $qcow_file --run-command "echo 'Modified from https://github.com/spiritLHLS/Images' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo 'Related repo https://github.com/spiritLHLS/pve' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo '--by https://t.me/spiritlhl' >> /etc/motd"
    echo "启用SSH功能..."
    # virt-customize -a $qcow_file --run-command "apk update"
    # virt-customize -a $qcow_file --run-command "apk add --no-cache wget curl openssh-server sshpass"
    # virt-customize -a $qcow_file --run-command "cd /etc/ssh"
    # virt-customize -a $qcow_file --run-command "ssh-keygen -A"
    echo "启用root登录..."
    # virt-customize -a $qcow_file --run-command "sed -i.bak '/^#PermitRootLogin/c PermitRootLogin yes' /etc/ssh/sshd_config"
    # virt-customize -a $qcow_file --run-command "sed -i.bak '/^#PasswordAuthentication/c PasswordAuthentication yes' /etc/ssh/sshd_config"
    # virt-customize -a $qcow_file --run-command "sed -i.bak '/^#ListenAddress/c ListenAddress 0.0.0.0' /etc/ssh/sshd_config"
    # virt-customize -a $qcow_file --run-command "sed -i.bak '/^#AddressFamily/c AddressFamily any' /etc/ssh/sshd_config"
    # virt-customize -a $qcow_file --run-command "sed -i.bak 's/^#\?Port.*/Port 22/' /etc/ssh/sshd_config"
    # virt-customize -a $qcow_file --run-command "/usr/sbin/sshd"
elif [[ "$qcow_file" == *"almalinux9"* ]]; then
    virt-customize -a $qcow_file --run-command "sed -i 's/ssh_pwauth:[[:space:]]*0/ssh_pwauth: 1/g' /etc/cloud/cloud.cfg"
    virt-customize -a $qcow_file --run-command "echo 'Modified from https://github.com/spiritLHLS/Images' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo 'Related repo https://github.com/spiritLHLS/pve' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo '--by https://t.me/spiritlhl' >> /etc/motd"
    echo "启用SSH功能..."
    virt-customize -a $qcow_file --run-command "systemctl enable ssh"
    virt-customize -a $qcow_file --run-command "systemctl start ssh"
    virt-customize -a $qcow_file --run-command "systemctl enable sshd"
    virt-customize -a $qcow_file --run-command "systemctl start sshd"
    echo "启用root登录..."
    virt-customize -a $qcow_file --run-command "sed -i 's/ssh_pwauth:[[:space:]]*0/ssh_pwauth: 1/g' /etc/cloud/cloud.cfg"
    virt-customize -a $qcow_file --run-command "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/^ChallengeResponseAuthentication no/ChallengeResponseAuthentication yes/g' /etc/ssh/sshd_config.d/50-redhat.conf"
    virt-customize -a $qcow_file --run-command "sed -i 's/#Port 22/Port 22/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#AddressFamily any/AddressFamily any/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#ListenAddress ::/ListenAddress ::/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "service ssh restart"
    virt-customize -a $qcow_file --run-command "service sshd restart"
    virt-customize -a $qcow_file --run-command "systemctl restart sshd"
    virt-customize -a $qcow_file --run-command "systemctl restart ssh"
    virt-customize -a $qcow_file --run-command "yum update -y && yum install qemu-guest-agent -y"
    virt-customize -a $qcow_file --run-command "systemctl start qemu-guest-agent"
elif [[ "$qcow_file" == *"almalinux"* || "$qcow_file" == *"centos9-stream"* || "$qcow_file" == *"centos8-stream"* || "$qcow_file" == *"centos7"* ]]; then
    virt-customize -a $qcow_file --run-command "sed -i 's/ssh_pwauth:[[:space:]]*0/ssh_pwauth: 1/g' /etc/cloud/cloud.cfg"
    virt-customize -a $qcow_file --run-command "echo 'Modified from https://github.com/spiritLHLS/Images' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo 'Related repo https://github.com/spiritLHLS/pve' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo '--by https://t.me/spiritlhl' >> /etc/motd"
    echo "启用SSH功能..."
    virt-customize -a $qcow_file --run-command "systemctl enable ssh"
    virt-customize -a $qcow_file --run-command "systemctl start ssh"
    virt-customize -a $qcow_file --run-command "systemctl enable sshd"
    virt-customize -a $qcow_file --run-command "systemctl start sshd"
    echo "启用root登录..."
    virt-customize -a $qcow_file --run-command "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/^ChallengeResponseAuthentication no/ChallengeResponseAuthentication yes/g' /etc/ssh/sshd_config.d/50-redhat.conf"
    virt-customize -a $qcow_file --run-command "sed -i 's/#Port 22/Port 22/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#AddressFamily any/AddressFamily any/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#ListenAddress ::/ListenAddress ::/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "service ssh restart"
    virt-customize -a $qcow_file --run-command "service sshd restart"
    virt-customize -a $qcow_file --run-command "systemctl restart sshd"
    virt-customize -a $qcow_file --run-command "systemctl restart ssh"
    virt-customize -a $qcow_file --run-command "yum update -y && yum install qemu-guest-agent -y"
    virt-customize -a $qcow_file --run-command "systemctl start qemu-guest-agent"
else
    virt-customize -a $qcow_file --run-command "sed -i 's/disable_root:[[:space:]]*1/disable_root: 0/g' /etc/cloud/cloud.cfg"
    virt-customize -a $qcow_file --run-command "sed -i 's/ssh_pwauth:[[:space:]]*0/ssh_pwauth: 1/g' /etc/cloud/cloud.cfg"
    virt-customize -a $qcow_file --run-command "echo 'Modified from https://github.com/spiritLHLS/Images' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo 'Related repo https://github.com/spiritLHLS/pve' >> /etc/motd"
    virt-customize -a $qcow_file --run-command "echo '--by https://t.me/spiritlhl' >> /etc/motd"
    echo "启用SSH功能..."
    virt-customize -a $qcow_file --run-command "systemctl enable ssh"
    virt-customize -a $qcow_file --run-command "systemctl start ssh"
    virt-customize -a $qcow_file --run-command "systemctl enable sshd"
    virt-customize -a $qcow_file --run-command "systemctl start sshd"
    echo "启用root登录..."
    virt-customize -a $qcow_file --run-command "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#Port 22/Port 22/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#AddressFamily any/AddressFamily any/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "sed -i 's/#ListenAddress ::/ListenAddress ::/g' /etc/ssh/sshd_config"
    virt-customize -a $qcow_file --run-command "service ssh restart"
    virt-customize -a $qcow_file --run-command "service sshd restart"
    virt-customize -a $qcow_file --run-command "systemctl restart sshd"
    virt-customize -a $qcow_file --run-command "systemctl restart ssh"
fi
echo "创建备份..."
cp $qcow_file ${qcow_file}.bak
echo "复制新文件..."
cp $qcow_file ${qcow_file}.tmp
echo "覆盖原文件..."
mv ${qcow_file}.tmp $qcow_file
rm -rf *.bak
echo "$qcow_file修改完成"
