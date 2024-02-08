# PVE

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2FspiritLHLS%2Fpve&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

感谢 Proxmox VE 的免费订阅支持

如果有未适配的商家或机器欢迎联系[@spiritlhl_bot](https://t.me/spiritlhl_bot)，有空会尝试支持一下

待开发内容：

- KVM/LXC模板加载部分自定义的限制，避免机器用于滥用发包

## 更新

2024.02.08

- LXC模板构建自定义的模板提前初始化好部分内容，避免原始模板过于干净导致初始化时间过长，优先级：自修补镜像 > 官方镜像
- 已预先安装设置模板的容器仓库：[https://github.com/oneclickvirt/pve_lxc_images](https://github.com/oneclickvirt/pve_lxc_images)
- 修复镜像在下载后重复使用可能重复下载的问题
- 增加适配 alpine fedora archlinux 待适配 devuan opensuse gentoo
- 大幅缩短LXC容器开设时间(在使用自修补镜像时)

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
