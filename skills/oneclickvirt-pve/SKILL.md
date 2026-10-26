---
name: oneclickvirt-pve
description: "Operate and troubleshoot pve instances deployed with the OneClickVirt scripts."
metadata:
  repository: oneclickvirt/pve
  integration-version: "1.0.0"
---

# pve

## Scope

Operate and troubleshoot pve instances deployed with the OneClickVirt scripts.

- Read the platform precheck and installation pages before changing a host.
- Use the existing host runtime and its credentials. Instance IDs and names remain the native runtime identifiers.
- MCP starts read-only. Set ONECLICKVIRT_MCP_ALLOW_WRITE=1 on the intended host to expose start, graceful stop and restart; deletion, reinstall and arbitrary shell commands are not exposed.
- PVE uses pvesh and the cluster-reported node/type; qemu and lxc guests are kept distinct. ARM64 PVE packages are community PXVIRT.

## Install and update

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/install_agent.py -o install_agent.py
python3 install_agent.py --client codex
```

The installer is also mirrored at `https://cnb.cool/oneclickvirt/pve/-/git/raw/main/scripts/install_agent.py`; add `--source cnb` to install from an immutable CNB snapshot (requires Git).

Use `--client claude` or `--client openclaw` for another client. Download and run again to update; `--ref` pins a source tag/commit. The installer verifies all SHA-256 checksums before replacing its files, preserves extra local files/client settings, and records the source commit in `install.json`.

## MCP

Requires Python 3.9+. The adapter uses existing local commands and their existing permissions; it does not install a virtualization runtime. Merge the installed `mcp.example.json` into the client configuration. For a remote host, run its adapter over noninteractive SSH.

Call `integration_info` first for capabilities and prerequisites.

## Source and documentation

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

Check the relevant source and current documentation before giving commands. Preserve requested version pins, data paths and native host identifiers. Distinguish actual program execution, isolated tests and unverified environments.
