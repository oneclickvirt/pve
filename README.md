# PVE

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2FspiritLHLS%2Fpve&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

感谢 Proxmox VE 的免费订阅支持

如果有未适配的商家或机器欢迎联系[@spiritlhl_bot](https://t.me/spiritlhl_bot)，有空会尝试支持一下

待开发内容：

- 创建带IPV6独立地址的VM虚拟机或CT容器
- KVM模板加载部分自定义的限制，避免机器用于滥用发包

## 更新

2023.07.30

- 适配了ARM架构且已在hz的ARM机器上测试(Debian11及其更旧的系统)无问题，感谢[Proxmox-Arm64](https://github.com/jiangcuo/Proxmox-Arm64)提供的第三方补丁，本项目目前支持X86_64架构和ARM架构了
- 修改部分附加文件的存储位置至于```/usr/local/bin/```目录下
- CN的IP检测增加一个检测源，对CN的特殊处理增加对APT源的特殊处理
- 有些奇葩机器的apt源老有问题，增加自动修复的函数

[更新日志](CHANGELOG.md)

## 说明文档

[virt.spiritlhl.net](https://virt.spiritlhl.net/) 中 Proxmox VE 分区内容

## Stargazers over time

[![Stargazers over time](https://starchart.cc/spiritLHLS/pve.svg)](https://starchart.cc/spiritLHLS/pve)

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs
