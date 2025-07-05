
## 无线环境安装

挂载U盘

```
fdisk -l
mount /dev/sdx1 /mnt
```

U盘内的wireless.zip已解压，打开可见其中的deb文件

此时直接执行一键配置

```
bash /mnt/wireless.sh
```

配置完毕会自动重启系统，重启后会有网络

配置脚本执行过程中会提示输入WIFI的名字和密码，由于纯CI环境无中文输入法，WIFI的名字必须仅英文数字组成，密码也是

## 其他初始设置

```shell
cp -rf /usr/share/perl5/PVE/APLInfo.pm /usr/share/perl5/PVE/APLInfo.pm.bak
sed -i 's|http://download.proxmox.com|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
sed -i 's|http://mirrors.ustc.edu.cn/proxmox|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak
rm -rf /etc/apt/sources.list.d/pve-enterprise.list
cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve ${version} pve-no-subscription
EOF
if command -v ceph >/dev/null 2>&1; then
  ceph_version_full=$(ceph -v 2>/dev/null)
  ceph_version=$(echo "$ceph_version_full" | grep -oP '\(\K[^)]+' | head -1)
else
  ceph_version=""
fi
if [ -n "$ceph_version" ] && [ -f /etc/apt/sources.list.d/ceph.list ]; then
  cp /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak
  cat > /etc/apt/sources.list.d/ceph.list <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/ceph/debian-${ceph_version} ${version} main
EOF
fi
pve_version=$(dpkg-query -f '${Version}' -W proxmox-ve 2>/dev/null | cut -d'-' -f1)
cp -rf /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak
sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
sed -i.bak "s/data.status !== 'Active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
chmod 777 ChangeMirrors.sh
./ChangeMirrors.sh --source mirrors.aliyun.com --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null > /dev/null
rm -rf ChangeMirrors.sh
if lvdisplay /dev/pve/data > /dev/null 2>&1; then
  lvremove -y /dev/pve/data
  lvextend -l +100%FREE /dev/mapper/pve-root
  resize2fs /dev/mapper/pve-root
  sed -i '/^lvmthin: local-lvm/,/^$/d' /etc/pve/storage.cfg
fi
apt update
apt install -y xorg xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
apt install -y fonts-wqy-zenhei fonts-wqy-microhei fonts-noto-cjk
apt install -y fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-gtk2
apt install -y firefox-esr
cat > /etc/environment << 'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/fcitx5.desktop << 'EOF'
[Desktop Entry]
Type=Application
Exec=fcitx5
NoDisplay=true
EOF
systemctl enable lightdm
if ! dpkg -s apparmor >/dev/null 2>&1; then
    apt-get install -y apparmor
fi
if [ $? -ne 0 ]; then
    apt-get install -y apparmor --fix-missing
fi
if ! systemctl is-active --quiet apparmor.service; then
    systemctl enable apparmor.service
    systemctl start apparmor.service
fi
if ! lsmod | grep -q apparmor; then
    modprobe apparmor
fi
apt autoremove -y
apt autoclean
```
