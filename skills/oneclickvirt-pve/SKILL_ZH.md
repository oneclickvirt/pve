---
name: oneclickvirt-pve
description: "管理和排查由 OneClickVirt 脚本部署的 Proxmox VE 虚拟机与 LXC 容器。"
metadata:
  repository: oneclickvirt/pve
  integration-version: "1.0.0"
---

# pve

## 使用范围

管理和排查由 OneClickVirt 脚本部署的 Proxmox VE 虚拟机与 LXC 容器。

- 变更宿主机前，先阅读平台准备和安装页。
- 使用本机已有运行环境及凭据；实例名称和 ID 保持原运行环境的标识。
- MCP 默认只读。在目标主机设置 ONECLICKVIRT_MCP_ALLOW_WRITE=1 后才提供启动、正常关机和重启；不提供删除、重装或任意 Shell 执行。
- 使用集群返回的节点和实例类型调用 pvesh，区分 qemu 与 lxc。ARM64 PVE 使用社区 PXVIRT 软件包。

## 安装和更新

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/install_agent.py -o install_agent.py
python3 install_agent.py --client codex
```

可将下载地址改为 `https://cnb.cool/oneclickvirt/pve/-/git/raw/main/scripts/install_agent.py`，并使用 `--source cnb` 从 CNB 的固定提交安装；此模式另需 Git。

用 `--client claude` 或 `--client openclaw` 选择其他客户端。重新下载并执行可更新；`--ref` 固定源码标签或提交。安装前校验全部 SHA-256，保留额外本地文件及已有客户端设置，`install.json` 记录来源提交。

## MCP

运行需要 Python 3.9 以上版本；MCP 使用本机已有程序及其权限，不自动安装虚拟化环境。将安装目录内 `mcp.example.json` 合并到客户端配置。远端宿主机应通过无交互 SSH 运行该主机上的适配器。

先调用 `integration_info` 查看能力和运行要求。

## 对应源码与说明

- [`dockerfiles/build-modern.sh`](https://github.com/oneclickvirt/pve/blob/main/dockerfiles/build-modern.sh)
- [`dockerfiles/build.sh`](https://github.com/oneclickvirt/pve/blob/main/dockerfiles/build.sh)
- [`dockerfiles/container-certificates.sh`](https://github.com/oneclickvirt/pve/blob/main/dockerfiles/container-certificates.sh)
- [`dockerfiles/container-entrypoint.sh`](https://github.com/oneclickvirt/pve/blob/main/dockerfiles/container-entrypoint.sh)
- [`dockerfiles/install-container.sh`](https://github.com/oneclickvirt/pve/blob/main/dockerfiles/install-container.sh)
- [`extra_scripts/check-dns.sh`](https://github.com/oneclickvirt/pve/blob/main/extra_scripts/check-dns.sh)
- [`extra_scripts/clear_interface_route_cache.sh`](https://github.com/oneclickvirt/pve/blob/main/extra_scripts/clear_interface_route_cache.sh)
- [`extra_scripts/configure_macos.sh`](https://github.com/oneclickvirt/pve/blob/main/extra_scripts/configure_macos.sh)
- [`extra_scripts/configure_network.sh`](https://github.com/oneclickvirt/pve/blob/main/extra_scripts/configure_network.sh)
- [`extra_scripts/install_ifupdown2.sh`](https://github.com/oneclickvirt/pve/blob/main/extra_scripts/install_ifupdown2.sh)
- [`extra_scripts/wireless/default.sh`](https://github.com/oneclickvirt/pve/blob/main/extra_scripts/wireless/default.sh)
- [`extra_scripts/wireless/wireless.sh`](https://github.com/oneclickvirt/pve/blob/main/extra_scripts/wireless/wireless.sh)
- [`patches/apply_patch.sh`](https://github.com/oneclickvirt/pve/blob/main/patches/apply_patch.sh)
- [`scripts/build_backend.sh`](https://github.com/oneclickvirt/pve/blob/main/scripts/build_backend.sh)
- [`scripts/build_nat_network.sh`](https://github.com/oneclickvirt/pve/blob/main/scripts/build_nat_network.sh)
- [`scripts/buildct.sh`](https://github.com/oneclickvirt/pve/blob/main/scripts/buildct.sh)
- [`scripts/buildct_onlyv6.sh`](https://github.com/oneclickvirt/pve/blob/main/scripts/buildct_onlyv6.sh)
- [`scripts/buildvm.sh`](https://github.com/oneclickvirt/pve/blob/main/scripts/buildvm.sh)

- [集成安装说明 / Integration guide](https://www.spiritlhl.net/guide/agent_integrations.html)
- [平台准备与安装 / Platform prerequisites](https://www.spiritlhl.net/guide/pve/pve_precheck.html)

给出操作命令前核对这些源码文件及当前文档，保留现有版本固定、数据路径和宿主机标识。报告测试时区分真实程序执行、隔离测试及未验证的环境。
