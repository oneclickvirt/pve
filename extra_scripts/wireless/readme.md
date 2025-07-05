
```
fdisk -l
mount /dev/sdx1 /mnt
```

```
bash /mnt/
wireless.sh
```


```shell
version=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
sed -i 's|^deb |# deb |' /etc/apt/sources.list.d/pve-enterprise.list
cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve ${version} pve-no-subscription
EOF
bash <(curl -sSL https://linuxmirrors.cn/main.sh) \
  --source mirrors.aliyun.com \
  --branch debian
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
apt autoremove -y
apt autoclean
```
