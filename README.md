# PVE

只适配Debian且Ubuntu未测试

### 检测硬件环境

检测环境是否可嵌套虚拟化KVM类型的服务器

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/check_kernal.sh)
```

### pve 6

apt源版本为6.4-15

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/install_pve6.sh -o install_pve6.sh && chmod +x install_pve6.sh && bash install_pve6.sh
```

### pve6升级为最新的pve7

自测中，勿要使用，未完成

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/pve6_to_pve7.sh -o pve6_to_pve7.sh && chmod +x pve6_to_pve7.sh && bash pve6_to_pve7.sh
```

### 下载系统镜像

自测中，勿要使用，未完成

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/install_iso.sh -o install_iso.sh && chmod +x install_iso.sh && bash install_iso.sh
```

### 开虚拟机环境预设置

自测中，勿要使用，未完成

```
bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/spiritLHLS/pve/main/build_backend.sh)
```

### pve 7

废弃，因为apt源最新版本不支持7.x

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/install_pve7.sh -o install_pve7.sh && chmod +x install_pve7.sh && bash install_pve7.sh
```
