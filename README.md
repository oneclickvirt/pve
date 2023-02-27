# PVE

### 前言

建议debian在使用前尽量使用最新的系统

非debian11可使用 [debian一键升级](https://github.com/spiritLHLS/one-click-installation-script#%E4%B8%80%E9%94%AE%E5%8D%87%E7%BA%A7%E4%BD%8E%E7%89%88%E6%9C%ACdebian%E4%B8%BAdebian11) 来升级系统

当然不使用最新的debian系统也没问题，只不过得不到官方支持

### 配置与系统要求

只适配Debian且Ubuntu未测试

系统要求：Debian 8+

硬件要求：2核2G内存x86_64架构服务器

可开KVM的硬件要求：VM-X或AMD-V支持-(部分VPS和全部独服支持)

遇到选项不会选的可无脑回车安装，所有脚本内置国内外IP自动判断，使用的是不同的安装源与配置文件

### 检测硬件环境

- 检测硬件环境是否可嵌套虚拟化KVM类型的服务器
- 检测系统环境是否可嵌套虚拟化KVM类型的服务器
- 不可嵌套虚拟化KVM类型的服务器也可以开LXC虚拟化的服务器

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/check_kernal.sh)
```

### PVE基础安装

- 安装的是当下apt源最新的PVE
- 比如debian10则是pve6.4，debian11则是pve7.x
- /etc/hosts文件修改(修正商家hostname设置错误以及新增PVE所需的内容)
- 已设置```/etc/hosts```为只读模式，避免重启后文件被覆写，如需修改请使用```chattr -i /etc/hosts```取消只读锁定，修改完毕请执行```chattr +i /etc/hosts```只读锁定
- 检测是否为中国IP，如果为中国IP使用清华镜像源，否则使用官方源
- 新增PVE的APT源链接后，下载PVE并打印输出登陆信息

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/install_pve.sh -o install_pve.sh && chmod +x install_pve.sh && bash install_pve.sh
```

- 安装过程中可能会退出安装，需要手动修复apt源，如下图所示修复完毕后再次执行本脚本

![图片](https://user-images.githubusercontent.com/103393591/220104992-9eed2601-c170-46b9-b8b7-de141eeb6da4.png)

![图片](https://user-images.githubusercontent.com/103393591/220105032-72623188-4c44-43c0-b3f1-7ce267163687.png)

### 预配置环境

- 创建资源池mypool
- 安装PVE开虚拟机需要的必备工具包
- 替换apt源中的企业订阅为社区源
- 删除无效的Linux系统内核
- 检测AppArmor模块并试图安装
- 配置完毕需要重启系统加载内核

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/build_backend.sh)
```

### 自动配置IPV4的NAT网关

- 创建vmbr0
- 创建vmbr1(NAT网关)
- 开NAT虚拟机时网关（IPV4）使用```172.16.1.1```，IPV4/CIDR使用```172.16.1.x/24```，这里的x不能是1
- 可能需要web端手动点应用配置按钮应用一下
- 想查看完整设置可以执行```cat /etc/network/interfaces```查看

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/build_nat_network.sh)
```

## 以下脚本测试开发中勿要使用

### 加载系统模板

自测中，勿要使用，未完成

- 加载KVM或LXC模板到PVE的ISO/CT列表中(debian11，ubuntu20)
- 加载完成后请web端查看 pve > local(pve) > ISO Images/CT Templates 刷新一下记录，直接去创建虚拟机是可能看不到已加载的

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/install_iso.sh -o install_iso.sh && chmod +x install_iso.sh && bash install_iso.sh
```

#### pve6.4升级为最新的pve7.x

自测中，勿要使用，未完成

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/pve6_to_pve7.sh -o pve6_to_pve7.sh && chmod +x pve6_to_pve7.sh && bash pve6_to_pve7.sh
```

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs
