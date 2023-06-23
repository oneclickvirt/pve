# PVE

感谢 Proxmox VE 的免费订阅支持

待开发内容：

- 创建带IPV6独立地址的VM虚拟机或CT容器
- KVM模板加载部分自定义的限制，避免机器用于滥用发包
- 增加arm64架构的一键安装功能
- 文档以及脚本输出修改支持双语

## 更新

2023.06.23

- 网关配置修改使用新结构，以便于适配大多数机器
- 调整安装的流程，升级软件包后需要重启一次系统，详见脚本的运行提示
- 解决了ifupdown2的安装问题，支持在更多商家的服务器上安装

[更新日志](CHANGELOG.md)

## 说明文档

[virt.spiritlhl.net](https://virt.spiritlhl.net/) 中 Proxmox VE 分区内容

## Stargazers over time

[![Stargazers over time](https://starchart.cc/spiritLHLS/pve.svg)](https://starchart.cc/spiritLHLS/pve)

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs
