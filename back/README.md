
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

### 创建一堆不同系统的虚拟机测试qcow2镜像

```
./buildvm.sh 102 test1 1234567 1 512 5 40001 41002 41003 50000 50001 ubuntu18
./buildvm.sh 103 test2 1234567 1 512 5 40002 42002 42003 50002 50003 ubuntu20
./buildvm.sh 104 test3 1234567 1 512 5 40003 43002 43003 50004 50005 ubuntu22
./buildvm.sh 105 test4 1234567 1 512 5 40004 44002 44003 50006 50007 debian9
./buildvm.sh 106 test5 1234567 1 512 5 40005 45002 45003 50008 50009 debian10
./buildvm.sh 107 test6 1234567 1 512 5 40006 46002 46003 50010 50011 debian11
./buildvm.sh 108 test7 1234567 1 512 5 40007 47002 47003 50012 50013 centos7
./buildvm.sh 109 test8 1234567 1 512 5 40008 48002 48003 50014 50015 centos8-stream
./buildvm.sh 110 test9 1234567 1 512 5 40009 49002 49903 50016 50017 centos9-stream
./buildvm.sh 111 test10 1234567 1 512 5 40010 49001 49993 50018 50019 almalinux8
./buildvm.sh 112 test11 1234567 1 512 5 40011 49003 48883 50020 50021 almalinux9
./buildvm.sh 113 test12 1234567 1 512 5 40012 49004 48873 50022 50023 archlinux
./buildvm.sh 114 test13 1234567 1 512 5 40013 49005 48863 50024 50025 alpinelinux_v3_15
./buildvm.sh 115 test14 1234567 1 512 5 40014 49006 48864 50026 50027 alpinelinux_v3_17
```

```
for vmid in $(qm list | awk '{if(NR>1) print $1}'); do qm stop $vmid; qm destroy $vmid; rm -rf /var/lib/vz/images/$vmid*; done
iptables -t nat -F
iptables -t filter -F
service networking restart
systemctl restart networking.service
rm -rf vm*
```
