# PVE

只适配Debian且Ubuntu未测试

系统要求：Debian 8+

硬件要求：2核2G内存x86_64架构服务器

可开KVM的硬件要求：VM-X或AMD-V支持

遇到选项不会选的可无脑回车安装，所有脚本内置国内外IP自动判断，使用的是不同的安装源

### 检测硬件环境

检测环境是否可嵌套虚拟化KVM类型的服务器

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/check_kernal.sh)
```

### PVE

安装的是当下apt源最新的PVE(比如debian10则是pve6.4，debian11则是pve7.2)

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/install_pve6.sh -o install_pve6.sh && chmod +x install_pve6.sh && bash install_pve6.sh
```

### 下载系统镜像

下载KVM或LXC模板到PVE的ISO/CT列表中

下载完成后请web端查看 pve > local(pve) > ISO Images/CT Templates 刷新一下记录，直接去创建虚拟机是看不到已下载的

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/install_iso.sh -o install_iso.sh && chmod +x install_iso.sh && bash install_iso.sh
```

### 开虚拟机环境预设置

自测中，勿要使用，未完成

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/build_backend.sh)
```

### 废弃

#### pve7

废弃，因为apt源最新版本不支持7.x

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/install_pve7.sh -o install_pve7.sh && chmod +x install_pve7.sh && bash install_pve7.sh
```

#### pve6升级为最新的pve7

废弃，PVE7基于debian11开发，仅升级PVE没有任何用处

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/pve6_to_pve7.sh -o pve6_to_pve7.sh && chmod +x pve6_to_pve7.sh && bash pve6_to_pve7.sh
```

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs
