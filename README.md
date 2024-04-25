# PVE

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2FspiritLHLS%2Fpve&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

感谢 Proxmox VE 的免费订阅支持

如果有未适配的商家或机器欢迎联系[@spiritlhl_bot](https://t.me/spiritlhl_bot)，有空会尝试支持一下

待开发内容：

- KVM/LXC模板加载部分自定义的限制，避免机器用于滥用发包

## 更新

2024.04.25

- 修复 hostname 可能设置失败的问题
- 修复面板地址可能绑定到IPV6上的问题，强制监听IPV4的端口
- 修复KVM开设独立IPV4的虚拟机时，可能遇到的查询宿主机IP区间和网关地址失败的问题
- 优化独立IPV4地址的虚拟机开设的脚本，强制要求手动附加地址的时候附加IP非同子网，而自动附加时需要附加IP同子网
- 优化手动附加地址的时候附加IPV4可指定MAC地址
- 上述脚本错选时增加更换脚本的提示

[更新日志](CHANGELOG.md)

## 说明文档

国内(China Docs)：

[https://virt.spiritlhl.net/](https://virt.spiritlhl.net/)

国际(English Docs)：

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

说明文档中 Proxmox VE 分区内容

自修补虚拟机镜像源：

[https://github.com/oneclickvirt/pve_kvm_images](https://github.com/oneclickvirt/pve_kvm_images)

[https://github.com/oneclickvirt/kvm_images](https://github.com/oneclickvirt/kvm_images)

自修补容器镜像源：

[https://github.com/oneclickvirt/lxc_amd64_images](https://github.com/oneclickvirt/lxc_amd64_images)

[https://github.com/oneclickvirt/pve_lxc_images](https://github.com/oneclickvirt/pve_lxc_images)

[https://github.com/oneclickvirt/lxc_arm_images](https://github.com/oneclickvirt/lxc_arm_images)

## Introduce

English Docs:

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

Description of the **Proxmox VE** partition contents in the documentation

Self-patching VM image sources:

[https://github.com/oneclickvirt/pve_kvm_images](https://github.com/oneclickvirt/pve_kvm_images)

[https://github.com/oneclickvirt/pve_lxc_images](https://github.com/oneclickvirt/pve_lxc_images)

[https://github.com/oneclickvirt/kvm_images](https://github.com/oneclickvirt/kvm_images)

Self-patching container image source:

[https://github.com/oneclickvirt/lxc_amd64_images](https://github.com/oneclickvirt/lxc_amd64_images)

[https://github.com/oneclickvirt/lxc_arm_images](https://github.com/oneclickvirt/lxc_arm_images)


## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/pve.svg)](https://starchart.cc/oneclickvirt/pve)

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs
