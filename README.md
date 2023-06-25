# PVE

感谢 Proxmox VE 的免费订阅支持

待开发内容：

- 创建带IPV6独立地址的VM虚拟机或CT容器
- KVM模板加载部分自定义的限制，避免机器用于滥用发包
- 增加arm64架构的一键安装功能
- 文档以及脚本输出修改支持双语

## 更新

2023.06.25

- 特化修复在Hetzner上安装需要DD系统再安装的问题，现在安装原生debian系统也支持了
- 修复部分机器使用浮动IP，没有/etc/network/interfaces文件的问题，自动生成对应文件
- 修复部分机器启动后，DNS检测失败的问题，确保在网关添加后必自动检测一次保证DNS无问题

[更新日志](CHANGELOG.md)

## 说明文档

[virt.spiritlhl.net](https://virt.spiritlhl.net/) 中 Proxmox VE 分区内容

## Stargazers over time

[![Stargazers over time](https://starchart.cc/spiritLHLS/pve.svg)](https://starchart.cc/spiritLHLS/pve)

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs
