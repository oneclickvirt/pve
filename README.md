# PVE

[![Hits](https://hits.spiritlhl.net/pve.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%230eecf8&edge_flat=false)](https://hits.spiritlhl.net)

感谢 Proxmox VE 的免费订阅支持

如果有未适配的商家的机器欢迎联系[@spiritlhl_bot](https://t.me/spiritlhl_bot)，有空会尝试支持一下

## 更新

2026.08.27

- 收窄 NDP 代理到参与拓扑的桥接接口，并移除 NAT66 网桥停止时关闭全局 IPv6 转发的行为；保留 SLAAC RA、已委派前缀和 HE/6in4 隧道的可用性
- 网络初始化改为识别实际 IPv6 上联并仅设置对应接口的 RA 接收参数；移除旧版对 `eth0` 和全局 `all` 的硬编码，避免桥接与多前缀主机的 IPv6 配置互相影响
- PVE 首次将物理网口迁入 `vmbr0` 时，NDP 与 RA 持久化配置会跟随迁移后的逻辑上联；未桥接的自定义上联仍按实际 IPv6 默认路由处理
- 修复删除 VM/CT 时直连 IPv6 防火墙规则的地址推导：优先使用持久化委派前缀与实例实际地址，正确处理非 nibble `/38`、小前缀和网关碰撞；旧安装仍兼容宿主地址状态


[更新日志](CHANGELOG.md)

## 说明文档

国内(China Docs)：

[https://virt.spiritlhl.net/](https://virt.spiritlhl.net/)

国际(English Docs)：

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

说明文档中 Proxmox VE 分区内容

## 无交互模式

需要跳过脚本确认和输入提示时，统一使用：

```bash
export noninteractive=true
```

安装和批量创建流程仍可通过环境变量覆盖默认值，例如 `CN=true`、`PVE_MAIN_INTERFACE=enp3s0`、`PVE_HOSTNAME=mypve`、`USE_PRIVATE_IP=true`、`USE_MAX_IPV6_SUBNET=false`、`PVE_CREATE_COUNT=1`、`PVE_CREATE_CPU=1`、`PVE_CREATE_MEMORY=512`、`PVE_CREATE_DISK=5`、`PVE_CREATE_STORAGE=local`、`PVE_CREATE_SYSTEM=debian11`、`PVE_CREATE_IPV6=n`。

卸载脚本中 `noninteractive=true` 等同于 `AUTO_CONFIRM=yes`，会跳过卸载确认。

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

The installer preserves the selected interface IPv4 prefix across reboots and
uses an installation-mode marker while core packages are configured so a
remote bridge is not reloaded before it is complete. The OneClickVirt
integration harness waits for the optional `ifupdown2-install.service`
bootstrap reboot before starting the post-reboot pass. The repository's
`tests/` directory covers syntax, ShellCheck, network state, and install-mode
regressions, including isolated ifupdown2 lifecycle, image selection, and
POSIX `ssh_sh.sh` detection checks.

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
