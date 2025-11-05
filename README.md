# PVE

[![Hits](https://hits.spiritlhl.net/pve.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%230eecf8&edge_flat=false)](https://hits.spiritlhl.net)

感谢 Proxmox VE 的免费订阅支持

如果有未适配的商家的机器欢迎联系[@spiritlhl_bot](https://t.me/spiritlhl_bot)，有空会尝试支持一下

## 更新

2025.11.05

- 适配部分独立服务器安装过程中的热插拔，识别allow-hotplug热插拔的情况，避免重启断网
- 通过ndisc6确保在SLAAC分配IPV6子网时可能出现的子网识别大小错误的问题，直接从路由器中获取真实的大小
- 确保文件之间无前后顺序依赖，避免IPV6子网掩码检测从未从路由器实际检测过，确保至少执行过一次

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

[https://github.com/oneclickvirt/macos](https://github.com/oneclickvirt/macos)

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

[https://github.com/oneclickvirt/kvm_images](https://github.com/oneclickvirt/kvm_images)

[https://github.com/oneclickvirt/macos](https://github.com/oneclickvirt/macos)

Self-patching container image source:

[https://github.com/oneclickvirt/lxc_amd64_images](https://github.com/oneclickvirt/lxc_amd64_images)

[https://github.com/oneclickvirt/pve_lxc_images](https://github.com/oneclickvirt/pve_lxc_images)

[https://github.com/oneclickvirt/lxc_arm_images](https://github.com/oneclickvirt/lxc_arm_images)

## 友链

VPS融合怪测评脚本

https://github.com/oneclickvirt/ecs

https://github.com/spiritLHLS/ecs

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/pve.svg)](https://github.com/oneclickvirt/ecs)
