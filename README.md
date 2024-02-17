# PVE

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2FspiritLHLS%2Fpve&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

感谢 Proxmox VE 的免费订阅支持

如果有未适配的商家或机器欢迎联系[@spiritlhl_bot](https://t.me/spiritlhl_bot)，有空会尝试支持一下

待开发内容：

- KVM/LXC模板加载部分自定义的限制，避免机器用于滥用发包

## 更新

2024.02.17

- 修复X86架构下，debian9安装的PVE无法解压zst格式的LXC容器预制模板的问题
- 测试发现ARM架构下纯IPV6的容器开设有问题，x86架构下批量重启容器会有内网错误重载的问题，待修复

[更新日志](CHANGELOG.md)

## 说明文档

国内(China)：

[https://virt.spiritlhl.net/](https://virt.spiritlhl.net/)

国际(Global)：

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

说明文档中 Proxmox VE 分区内容

[https://github.com/oneclickvirt/kvm_images](https://github.com/oneclickvirt/kvm_images) 为对应虚拟机镜像仓库

## Stargazers over time

[![Stargazers over time](https://starchart.cc/spiritLHLS/pve.svg)](https://starchart.cc/spiritLHLS/pve)

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs
