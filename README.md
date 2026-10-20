# PVE

[![Hits](https://hits.spiritlhl.net/pve.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%230eecf8&edge_flat=false)](https://hits.spiritlhl.net)

感谢 Proxmox VE 的免费订阅支持

如果有未适配的商家的机器欢迎联系[@spiritlhl_bot](https://t.me/spiritlhl_bot)，有空会尝试支持一下

## 更新

2026.10.17

- Debian 13 / PVE 9 安装重放内核安装钩子，检查 initramfs、模块与引导项，保留可用恢复内核。
- 宿主网桥迁移保留递归接口配置，语法检查和连通性检查失败时由独立定时器回滚。
- 独立 IPv4 按真实前缀和网关分配，检查 ARP 冲突；分配锁在启动 QEMU 前释放，全端口 NAT 持久化地址占用。
- 纯 IPv6 CT/VM 使用 IPv6 DNS；直连、NAT66 和一对一映射分别校验，不能满足条件时停止创建。
- 兼容以 `-` 开头的密码；密码仅保存到本机权限为 600 的元数据文件，IPv6 删除规则按完整地址匹配。

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

## 配置已委派的 IPv6 前缀 / Configure a delegated IPv6 prefix

静态 IPv6 前缀和已有直连网桥会自动识别。如果服务商单独提供了路由前缀，将下面的前缀（包含 `/长度`）和宿主机网关替换成实际值，再重新运行 `build_nat_network.sh`。

Static IPv6 prefixes and existing direct bridges are detected automatically. If your provider supplies a separate routed prefix, replace the prefix (including its /length) and host gateway below, then rerun `build_nat_network.sh`.

```bash
export PVE_IPV6_ROUTED_PREFIX='YOUR_DELEGATED_PREFIX_WITH_LENGTH'
export PVE_IPV6_DIRECT_GATEWAY='YOUR_HOST_IPV6_GATEWAY'
export PVE_IPV6_DIRECT_MODE=routed
```

已有网桥会保留，并使用其 IPv6 地址作为容器网关。如需另选网桥或网关，可设置 `PVE_IPV6_DIRECT_BRIDGE` 和 `PVE_IPV6_BRIDGE_GATEWAY`。配置文件只读或无法解锁时，请先解决写入权限后再重试。

Existing bridges are preserved, and their IPv6 address is used as the guest gateway. Use `PVE_IPV6_DIRECT_BRIDGE` and `PVE_IPV6_BRIDGE_GATEWAY` to choose a different bridge or gateway. If the configuration file is read-only or cannot be unlocked, fix its write access before retrying.

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

PVE kernel verification accepts both `pve-kernel-*` and `proxmox-kernel-*`
concrete installed packages (including signed kernels), and checks their kernel
image, initramfs and modules before reporting success. The working distribution
kernel is retained as a recovery option. Failed installation checks preserve
installed packages instead of purging PVE and automatically removing kernels.
After the installation-mode marker is removed, kernel installation hooks are
replayed to generate the initramfs and boot entries. An incomplete existing
installation can be resumed with `PVE_REPAIR_EXISTING=true`; this preserves
guests and recovery kernels. Default enterprise sources are backed up and
disabled before retrying the signed no-subscription repository.

Network preconfiguration uses an ifupdown2 reload with a syntax check, a copy
of recursively sourced interface files and an independent rollback timer. Host
IPv4 and, when previously present, IPv6 HTTPS connectivity must survive the
change before it is committed. NDP link-local addresses are retained. An NDP
proxy can route permitted IPv6 addresses through the host MAC; it cannot bypass
an upstream restriction that authorizes only one IPv6 address or a prefix that
the provider has not routed to this machine.

When UFW is already active, network setup adds forwarding rules limited to
its guest bridges and IPv4/IPv6 subnets. It does not enable an inactive UFW.
Failed rule updates participate in the same network rollback as interface edits.

Cached container templates are checked before unprivileged creation. Character
and block device records from older templates (such as Postfix random devices)
are removed atomically; file ownership, permissions, hardlinks and extended
attributes are retained. A damaged archive is rejected without replacing it.

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

### LXC 独立 IPv4 与独立双栈

`buildct.sh` 保留原来的 NAT 参数，第 14 个参数可指定独立 IPv4/CIDR 或 `auto`。使用和虚拟机相同的宿主、网关、广播地址、已用地址及 ARP 冲突校验，并保留实际子网掩码；公网 IPv4 不创建端口转发。第 13 个参数为 `y` 时同时申请 IPv6，实际模式会写入结果。

```bash
# 最后两个参数：独立 IPv6、独立 IPv4/CIDR（请使用自己的空闲地址）
bash buildct.sh 150 'YOUR_PASSWORD' 1 768 6 0 0 0 0 0 debian12 local y 198.51.100.195/27
```

启用独立 IPv6 前，须先配置实例网桥及其可用委派前缀；不要使用宿主地址或网桥网关作为实例地址。

### 不创建入站端口映射

`buildct.sh`、`buildvm.sh` 的 SSH、HTTP、HTTPS、端口范围起止五个端口参数均设为 `0`，即可只保留内网地址和出网能力，不创建入站端口映射。此时通过宿主机或可达内网连接实例的 SSH 22 端口。端口映射写入失败会使脚本报错，避免把不可连接的实例报告为成功。
