
### 存档的脚本 - 勿要使用 - 全是BUG

#### pve6.4升级为最新的pve7.x

自测中，勿要使用，未完成

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/pve6_to_pve7.sh -o pve6_to_pve7.sh && chmod +x pve6_to_pve7.sh && bash pve6_to_pve7.sh
```

### 加载系统模板

- 加载KVM或LXC模板到PVE的ISO/CT列表中(debian11，ubuntu20)
- 加载完成后请web端查看 pve > local(pve) > ISO Images/CT Templates 刷新一下记录，直接去创建虚拟机是可能看不到已加载的

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/install_iso.sh -o install_iso.sh && chmod +x install_iso.sh && bash install_iso.sh
```

### 替换qcow2

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/back/rebuild.sh -o rebuild.sh && chmod +x rebuild.sh && bash rebuild.sh
```

```
guestfish -a xxx -i -c "cat /etc/ssh/sshd_config"
```

```
qm exec 虚拟机ID /bin/bash
```

### 卸载所有虚拟机

```
for vmid in $(qm list | awk '{if(NR>1) print $1}'); do qm stop $vmid; qm destroy $vmid; rm -rf /var/lib/vz/images/$vmid*; done
iptables -t nat -F
iptables -t filter -F
service networking restart
systemctl restart networking.service
rm -rf vm*
```

### 卸载PVE整体环境

尝试失败，因为已自动替换过为PVE的内核，如需卸载需要先替换为原生内核

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/back/uninstallpve.sh -o uninstallpve.sh && chmod +x uninstallpve.sh && bash uninstallpve.sh
```

