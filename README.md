# PVE

感谢 Proxmox VE 的免费订阅支持

待开发内容：

- 部分机器ifudown2安装有问题，原因在于PVE的MAC地址自动绑定错误，待修复(比如HostHatch)
- 创建带IPV6独立地址的VM虚拟机或CT容器
- KVM模板加载部分自定义的限制，避免机器用于滥用发包
- 增加arm64架构的一键安装功能
- 文档以及脚本输出修改支持双语

## 更新

2023.06.22

- PVE安装修复部分机器网络设置不立即重新加载的问题，增加网络设置备份
- 部分机器的IPV6物理接口使用auto类型，无法安装PVE，修改为static类型并重写配置
- 由于上面这条修复，已支持在Linode平台安装PVE了
- 修复低版本PVE还安装ifupdown2的问题，7.x以下版本使用ifupdown也足够了
- 由于上面这条修复，Hetzner的Debian10系统可以安装PVE了

[更新日志](CHANGELOG.md)

## 说明文档

[virt.spiritlhl.net](https://virt.spiritlhl.net/) 中 Proxmox VE 分区内容

## Stargazers over time

[![Stargazers over time](https://starchart.cc/spiritLHLS/pve.svg)](https://starchart.cc/spiritLHLS/pve)

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs
