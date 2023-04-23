# PVE

感谢 Proxmox VE 的免费订阅支持

[中文](README.md) | [English](README_EN.md)

### 前言

如果脚本有任何问题或者任何修复系统的需求，可在issues中提出，有空会解决或者回答

**请确保使用前机器可以重装系统，不保证本套脚本不造成任何BUG!!!**

**如果服务器是VPS而不是独服，可能会出现各种各样的BUG，请做好部署失败重装服务器的准备!!!**

待开发内容:

- 文档以及脚本输出修改支持双语
- 批量开设CT容器并自定义批量开设的配置
- 创建带IPV6独立地址的VM或CT容器

# 目录

* [系统要求与配置](#系统要求与配置)
    * [建议debian在使用前尽量使用最新的系统](#建议debian在使用前尽量使用最新的系统)
    * [检测硬件环境](#检测硬件环境)
    * [PVE基础安装](#PVE基础安装)
    * [预配置环境](#预配置环境)
    * [自动配置IPV4的NAT网关](#自动配置IPV4的NAT网关)
* [一键生成KVM虚拟化的NAT服务器](#一键生成KVM虚拟化的NAT服务器)
    * [单独生成KVM虚拟化的VM](#单独生成KVM虚拟化的VM)
    * [使用方法](#使用方法)
    * [示例](#示例)
    * [删除示例](#删除示例)
    * [相关qcow2镜像](#相关qcow2镜像)
* [批量开设NAT的KVM虚拟化的VM](#批量开设NAT的KVM虚拟化的VM)
    * [使用方法](#使用方法)
    * [删除所有虚拟机](#删除所有虚拟机)
    * [注意事项](#注意事项)
* [一键创建单个CT也就是LXC虚拟化的NAT容器](#一键创建单个CT也就是LXC虚拟化的NAT容器)
    * [使用方法](#使用方法)
    * [示例](#示例)
    * [删除示例](#删除示例)
* [致谢](#致谢)

### 系统要求与配置

#### 建议debian在使用前尽量使用最新的系统

非debian11可使用 [debian一键升级](https://github.com/spiritLHLS/one-click-installation-script#%E4%B8%80%E9%94%AE%E5%8D%87%E7%BA%A7%E4%BD%8E%E7%89%88%E6%9C%ACdebian%E4%B8%BAdebian11) 来升级系统

当然不使用最新的debian系统也没问题，只不过得不到官方支持。只适配Debian系统(非Debian无法通过APT源安装，官方只给了Debian的镜像，其他系统只能使用ISO安装)

- 系统要求：Debian 8+
- 最低的硬件要求：2核2G内存x86_64架构服务器硬盘至少20G
- 可开KVM的硬件要求：VM-X或AMD-V支持-(部分VPS和全部独服支持)
- 如果硬件需求不满足，可使用LXD批量开LXC的[跳转](https://github.com/spiritLHLS/lxc)

遇到选项不会选的可无脑回车安装，所有脚本内置国内外IP自动判断，使用的是不同的安装源与配置文件

#### 检测硬件环境

- 本仓库脚本执行前务必执行本脚本检测环境，如果不符合安装PVE的要求则无法使用后续的脚本
- 检测硬件配置是否满足最低要求
- 检测硬件环境是否可嵌套虚拟化KVM类型的服务器
- 检测系统环境是否可嵌套虚拟化KVM类型的服务器
- 不可嵌套虚拟化KVM类型的服务器也可以开LXC虚拟化的服务器

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/check_kernal.sh)
```

#### PVE基础安装

- 安装的是当下apt源最新的PVE
- 比如debian10则是pve6.4，debian11则是pve7.x
- /etc/hosts文件修改(修正商家hostname设置错误以及新增PVE所需的内容)
- 已设置```/etc/hosts```为只读模式，避免重启后文件被覆写，如需修改请使用```chattr -i /etc/hosts```取消只读锁定，修改完毕请执行```chattr +i /etc/hosts```只读锁定
- 检测是否为中国IP，如果为中国IP使用清华镜像源，否则使用官方源
- 安装PVE开虚拟机需要的必备工具包
- 替换apt源中的企业订阅为社区源
- 打印查询Linux系统内核和PVE内核是否已安装
- 查询网络配置是否为dhcp配置的V4网络，如果是则转换为静态地址避免重启后dhcp失效，已设置为只读模式，如需修改请使用```chattr -i /etc/network/interfaces.d/50-cloud-init```取消只读锁定，修改完毕请执行```chattr +i /etc/network/interfaces.d/50-cloud-init```只读锁定
- 检测```/etc/resolv.conf```是否为空，为空则设置检测```8.8.8.8```的开机自启添加DNS的systemd服务
- 新增PVE的APT源链接后，下载PVE并打印输出登陆信息
- 配置完毕需要重启系统加载新内核

#### 一键安装PVE

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/install_pve.sh -o install_pve.sh && chmod +x install_pve.sh && bash install_pve.sh
```

- 安装过程中可能会退出安装，需要手动修复apt源，如下图所示修复完毕后再次执行本脚本

![图片](https://user-images.githubusercontent.com/103393591/220104992-9eed2601-c170-46b9-b8b7-de141eeb6da4.png)

![图片](https://user-images.githubusercontent.com/103393591/220105032-72623188-4c44-43c0-b3f1-7ce267163687.png)

### 预配置环境

- 创建资源池mypool
- 移除订阅弹窗
- 尝试开启硬件直通
- 检测AppArmor模块并试图安装

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/build_backend.sh)
```

### 自动配置IPV4的NAT网关

- **使用前请保证重启过服务器且PVE能正常使用WEB端再执行**
- 创建vmbr0
- 创建vmbr1(NAT网关)
- 开NAT虚拟机时网关（IPV4）使用```172.16.1.1```，IPV4/CIDR使用```172.16.1.x/24```，这里的x不能是1
- 可能需要web端手动点应用配置按钮应用一下
- 想查看完整设置可以执行```cat /etc/network/interfaces```查看
- 加载iptables并设置回源且允许NAT端口转发

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/build_nat_network.sh)
```

## 一键生成KVM虚拟化的NAT服务器

使用前记得**执行本仓库的第一个个命令，那个检测硬件环境的命令**，展示如下

![图片](https://user-images.githubusercontent.com/103393591/231160050-79945d07-b3d0-4e8d-9315-74e4fbb24f9d.png)

查询如上的只需使用下面的一键脚本自动创建虚拟机即可，无需手动再修改WEB端设置

![图片](https://user-images.githubusercontent.com/103393591/231160070-c317607c-8b0c-4aa4-bfa2-e75ec6626b24.png)

查询如上的在使用后续脚本创建了虚拟机后，需要手动修改WEB端设置，需要关闭对应每个虚拟机的硬件嵌套虚拟化，如下图

![图片](https://user-images.githubusercontent.com/103393591/231160449-82911a57-4b49-47ec-8fad-2100c6059017.png)

先停止虚拟机再修改，修改完后再开机才能使用NOVNC，不关闭可能导致这个虚拟机有BUG无法使用

### 单独生成KVM虚拟化的VM

- 自动开设NAT服务器，默认使用Debian10镜像，因为该镜像占用最小
- 可在命令中自定义需要使用的镜像，这里有给出配置好的镜像，镜像自带空间是2G硬盘，所以最少需要在命令中设置硬盘到3G
- 自定义内存大小推荐512MB内存，需要注意的是母鸡内存记得开点swap免得机器炸了[开SWAP点我跳转](https://github.com/spiritLHLS/addswap)
- 自动进行内外网端口映射，含22，80，443端口以及其他25个内外网端口号一样的端口
- 生成后需要等待一段时间虚拟机内部的cloudinit配置好网络以及登陆信息，大概需要5分钟

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/buildvm.sh -o buildvm.sh && chmod +x buildvm.sh
```

#### 使用方法

- 系统支持：详见 [跳转](https://github.com/spiritLHLS/Images/releases/tag/v1.0) 中列出的系统，使用时只需写文件名字，不需要.qcow2尾缀
- **注意这里的用户名不能是纯数字，会造成cloudinit出问题，最好是纯英文或英文开头**

```
./buildvm.sh VMID 用户名 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统
```

#### 示例

测试开一个NAT服务器

以下示例开设VMID为102的虚拟机，用户名是test1，密码是1234567，CPU是1核，内存是512MB，硬盘是5G，SSH端口是40001，80端口是40002，443端口是40003

同时内外网映射端口一致的区间是50000到50025，系统使用的是ubuntu20

```
./buildvm.sh 102 test1 1234567 1 512 5 40001 40002 40003 50000 50025 ubuntu20
```

开设完毕可执行

```
cat vm102
```

查看信息

#### 删除示例

- 删除端口映射删除测试机器

```
qm stop 102
qm destroy 102
iptables -t nat -F
iptables -t filter -F
service networking restart
systemctl restart networking.service
rm -rf vm102
```

#### 相关qcow2镜像

- 已预安装开启cloudinit，开启SSH登陆，预设值SSH监听V4和V6的22端口，开启允许密码验证登陆，开启允许ROOT登陆

https://github.com/spiritLHLS/Images/releases/tag/v1.0

### 批量开设NAT的KVM虚拟化的VM

- **初次使用前需要保证当前PVE未有任何虚拟机未有进行任何端口映射，否则可能出现BUG**
- **开设前请使用screen挂起执行，避免批量开设时间过长，SSH不稳定导致中间执行中断，推荐使用PVE自带的Shell操作母鸡**
- 可多次运行批量生成VM，但需要注意的是母鸡内存记得开点swap免得机器炸了[开SWAP点我跳转](https://github.com/spiritLHLS/addswap)
- 自动开设NAT服务器，默认使用Debian10镜像，因为该镜像占用最小
- 自动进行内外网端口映射，含22，80，443端口以及其他25个内外网端口号一样的端口
- 生成后需要等待一段时间虚拟机内部的cloudinit配置好网络以及登陆信息，大概需要5分钟
- 默认批量开设的虚拟机网络配置为：22，80，443端口及一个25个端口区间的内外网映射
- 可自定义批量开设的核心数，内存大小，硬盘大小，记得自己计算好空闲资源开设

#### 使用方法

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/create_vm.sh -o create_vm.sh && chmod +x create_vm.sh && bash create_vm.sh
```

开设完毕可执行

```
cat vmlog
```

查看信息

#### 删除所有虚拟机

```
for vmid in $(qm list | awk '{if(NR>1) print $1}'); do qm stop $vmid; qm destroy $vmid; rm -rf /var/lib/vz/images/$vmid*; done
iptables -t nat -F
iptables -t filter -F
service networking restart
systemctl restart networking.service
rm -rf vmlog
```

### 注意事项

PVE修改虚拟机配置前都得停机先，再修改配置，修改完再启动，免得出现配置重载错误

## 一键创建单个CT也就是LXC虚拟化的NAT容器

(LXC虚拟化的容器-自带内外网映射)

- **初次使用前需要保证当前PVE未有任何虚拟机未有进行任何端口映射，否则可能出现BUG**
- **开设前请使用screen挂起执行，避免批量开设时间过长，SSH不稳定导致中间执行中断，推荐使用PVE自带的Shell操作母鸡**
- 可多次运行批量生成VM，但需要注意的是母鸡内存记得开点swap免得机器炸了[开SWAP点我跳转](https://github.com/spiritLHLS/addswap)
- 自动开设NAT服务器，默认使用Debian11镜像
- 自动进行内外网端口映射，含22，80，443端口以及其他25个内外网端口号一样的端口
- 生成后需要等待一段时间虚拟机内部配置好网络以及登陆信息，大概需要3分钟
- 默认批量开设的虚拟机网络配置为：22，80，443端口及一个25个端口区间的内外网映射
- 可自定义批量开设的核心数，内存大小，硬盘大小，记得自己计算好空闲资源开设

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/buildct.sh -o buildct.sh && chmod +x buildct.sh
```

#### 使用方法

- 系统支持：debian10，debian11，ubuntu18，ubuntu20，ubuntu22
- 其他系统可能支持可能不支持，自行测试
- 默认用户名是root

```
./buildct.sh CTID 密码 CPU核数 内存 硬盘 SSH端口 80端口 443端口 外网端口起 外网端口止 系统
```

#### 示例

测试开一个NAT服务器

以下示例开设CTID为102的虚拟机，用户名是root，密码是1234567，CPU是1核，内存是512MB，硬盘是5G，SSH端口是40001，80端口是40002，443端口是40003

同时内外网映射端口一致的区间是50000到50025，系统使用的是debian10

```
./buildct.sh 102 1234567 1 512 5 40001 40002 40003 50000 50025 debian10
```

开设完毕可执行

```
cat ct102
```

查看信息

#### 删除示例

以下命令将删除所有ct容器和所有的log文件

```
pct list | awk 'NR>1{print $1}' | xargs -I {} sh -c 'pct stop {}; pct destroy {}'
rm -rf ct*
```

## 致谢

https://blog.ilolicon.com/archives/615

https://github.com/Ella-Alinda/somescripts/blob/main/nat.sh

https://pve.proxmox.com/pve-docs/qm.1.html

https://down.idc.wiki/Image/realServer-Template/

https://mirrors.tuna.tsinghua.edu.cn/proxmox/

https://github.com/roacn/pve/blob/main/pve.sh

https://github.com/spiritLHLS/lxc

感谢 [@Ella-Alinda](https://github.com/Ella-Alinda) 提供的PVE指导

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs
