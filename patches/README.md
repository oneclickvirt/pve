# Windows Cloudbase-Init 补丁 for Proxmox VE

本目录为 [Geco-Cloudbase-Init](https://github.com/kruisdraad/Geco-Cloudbase-Init) 项目的本地镜像与自动化工具。
通过修补 PVE 的两个 Perl 源文件，使 PVE 原生的 Cloud-Init 机制支持 Windows VM 所使用的 Cloudbase-Init。

**补丁仅影响 ostype 为 `win*` 的 Windows 虚拟机，Linux VM 和 CT 完全不受影响。**

---

## 目录结构

```
patches/
├── README.md              本文档
├── apply_patch.sh         自动修补脚本（推荐入口）
├── qemu-server-6.4-2/    适用于 PVE 6.x（Debian 9/10）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
├── qemu-server-7.1-4/    适用于 PVE 7.x（Debian 11 Bullseye）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
├── qemu-server-8.0.8/    适用于 PVE 8.0.0 – 8.0.9（Debian 12）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
└── qemu-server-8.0.10/   适用于 PVE 8.0.10+（Debian 12/13）
    ├── Cloudinit.pm.patch
    └── Qemu.pm.patch
```

对于未覆盖版本（如 PVE 8.1+、9.x），`apply_patch.sh` 会自动推导补丁并在本目录创建对应子文件夹（如 `qemu-server-8.2.0/`），欢迎提交 PR。
```
patches/
├── README.md              本文档
├── apply_patch.sh         自动修补脚本（推荐入口）
├── qemu-server-6.4-2/    适用于 PVE 6.x（Debian 10 buster）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
├── qemu-server-7.1-4/    适用于 PVE 7.0–7.2.x（Debian 11 bullseye）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
├── qemu-server-7.3-4/    适用于 PVE 7.3.x（Debian 11 bullseye）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
├── qemu-server-7.4-7/    适用于 PVE 7.4.x（Debian 11 bullseye）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
├── qemu-server-8.0.8/    适用于 PVE 8.0.0 – 8.0.9（Debian 12 bookworm）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
├── qemu-server-8.0.10/   适用于 PVE 8.0.10 – 8.0.x（Debian 12 bookworm）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
├── qemu-server-8.1.4/    适用于 PVE 8.1.x（Debian 12 bookworm）
│   ├── Cloudinit.pm.patch
│   └── Qemu.pm.patch
└── qemu-server-8.2.3/    适用于 PVE 8.2.0 – 8.2.3（Debian 12 bookworm）
      ├── Cloudinit.pm.patch
      └── Qemu.pm.patch
├── LocalScripts/         Cloudbase-Init 本地脚本（Windows 客体内使用）
│   ├── 00ActivateDHCP.py
│   ├── 01ActivateAdministrator.py
│   └── 99EjectDrive.py
└── powershell/           Windows 配置与封装脚本
      ├── ModifyConf.ps1
      ├── FixUserService.ps1
      └── sysprep.bat
```

> **PVE 8.2.4+（含 8.3.x、8.4.x、9.x+）已原生支持 Cloudbase-Init**，无需补丁。
> `apply_patch.sh` 会自动检测并跳过。
>
> 对于介于已知版本之间的小版本，`apply_patch.sh` 会自动选择最近的补丁版本进行模糊匹配推导，
> 并在本目录生成对应子文件夹（如 `qemu-server-8.2.2/`），欢迎提交 PR。

---

## 版本覆盖范围

| 子目录 | qemu-server 版本区间 | PVE 大版本 | Debian 代号 |
|---|---|---|---|
| `qemu-server-6.4-2` | 6.x | PVE 6 | stretch / buster |
| `qemu-server-7.1-4` | 7.0 – 7.x | PVE 7 | bullseye |
| `qemu-server-8.0.8` | 8.0.0 – 8.0.9 | PVE 8.0 early | bookworm |
| `qemu-server-8.0.10` | 8.0.10 – 8.x | PVE 8.0.10+ | bookworm / trixie |

| 子目录 | qemu-server 版本区间 | PVE 大版本 | Debian 代号 |
|---|---|---|---|
| `qemu-server-6.4-2` | 6.0.0 – 6.x | PVE 6.x | buster |
| `qemu-server-7.1-4` | 7.0.0 – 7.2.x | PVE 7.0 – 7.2 | bullseye |
| `qemu-server-7.3-4` | 7.3.0 – 7.3.x | PVE 7.3 | bullseye |
| `qemu-server-7.4-7` | 7.4.0 – 7.4.x | PVE 7.4 | bullseye |
| `qemu-server-8.0.8` | 8.0.0 – 8.0.9 | PVE 8.0 early | bookworm |
| `qemu-server-8.0.10` | 8.0.10 – 8.0.x | PVE 8.0.10+ | bookworm |
| `qemu-server-8.1.4` | 8.1.0 – 8.1.x | PVE 8.1 | bookworm |
| `qemu-server-8.2.3` | 8.2.0 – 8.2.3 | PVE 8.2.0–8.2.3 | bookworm |
| **原生支持** | **8.2.4+（含 8.3、8.4、9.x+）** | **PVE 8.2.4+** | bookworm / trixie |

---

## 补丁内容说明

补丁修改 PVE 的两个 Perl 文件：

### 1. `/usr/share/perl5/PVE/QemuServer/Cloudinit.pm`

- `configdrive2_network()`：为 Windows VM 生成 Cloudbase-Init 所需的 DNS 配置段
- `configdrive2_gen_metadata()` / `configdrive2_metadata()`：向 metadata 中注入
  hostname、明文密码（Windows 不支持加密密码哈希）、admin_username、SSH 公钥（JSON 格式）、
  MAC 地址列表等字段
- 新增 `get_mac_addresses()` 辅助函数

所有新增代码均在 `if (PVE::QemuServer::windows_version($ostype)) { ... }` 条件块中，
**不会影响 Linux VM 或 CT 的 Cloud-Init 行为**。

### 2. `/usr/share/perl5/PVE/API2/Qemu.pm`

- 对 `update_vm` API 中的 `cipassword` 处理：当 ostype 为 Windows 时，
  **跳过** `PVE::Tools::encrypt_pw()` 加密，以明文写入配置，
  因为 Cloudbase-Init 不支持读取 Linux 密码哈希格式。

---

## 快速使用

### 自动应用（推荐）

```bash
# 自动检测版本并应用
bash patches/apply_patch.sh

# 仅预检测（不修改文件）
bash patches/apply_patch.sh --dry-run

# 查看当前补丁状态
bash patches/apply_patch.sh --status
```

脚本会：
1. 检测当前安装的 `qemu-server` 版本
2. 选择最合适的补丁目录
3. 如本地补丁不存在，从 Geco 上游下载
4. 预检测（`patch --dry-run`），通过后再实际应用
5. 对未覆盖版本，依次尝试模糊匹配（`--fuzz`）→ 语义化 Perl 修补 → 保存推导补丁
6. 成功后自动 `systemctl restart pvedaemon.service`

### 回滚

```bash
bash patches/apply_patch.sh --revert
```

若 `patch --reverse` 失败，脚本将自动从 `/root/pve_cloudinit_backup_*/` 恢复原始文件。

---

## 手动操作参考

### 手动应用（以 8.0.10 为例）

```bash
PATCH_DIR="patches/qemu-server-8.0.10"

# 预检测
patch --force --forward --backup -p0 --directory / \
      --dry-run --input "$PATCH_DIR/Cloudinit.pm.patch"
patch --force --forward --backup -p0 --directory / \
      --dry-run --input "$PATCH_DIR/Qemu.pm.patch"

# 确认无误后实际应用
patch --force --forward --backup -p0 --directory / \
      --input "$PATCH_DIR/Cloudinit.pm.patch"
patch --force --forward --backup -p0 --directory / \
      --input "$PATCH_DIR/Qemu.pm.patch"

systemctl restart pvedaemon.service
```

### 手动回滚

```bash
PATCH_DIR="patches/qemu-server-8.0.10"
patch --force --reverse --backup -p0 --directory / \
      --input "$PATCH_DIR/Cloudinit.pm.patch"
patch --force --reverse --backup -p0 --directory / \
      --input "$PATCH_DIR/Qemu.pm.patch"
systemctl restart pvedaemon.service
```

---

## 在 Windows VM 中配合使用

补丁应用后，创建 Windows VM 时需满足以下条件才能使用 Windows Cloudbase-Init：

1. **ostype** 设置为 `win10` / `win11` 等 `win*` 类型
2. 添加 **Cloud-Init 驱动器**（Hardware → Add → CloudInit Drive）
3. 添加 **串口 0**（Serial Port → socket）
4. 在 VM 内安装 [Cloudbase-Init Continuous Build](https://cloudbase.it/cloudbase-init/)
5. 在 PVE Cloud-Init 标签页中设置 User / Password / SSH Keys / IP 配置

详细说明参见：[Geco-Cloudbase-Init README](https://github.com/kruisdraad/Geco-Cloudbase-Init)
和 [使用教程（中文）](https://foxi.buduanwang.vip/windows/1789.html/)

---

## LocalScripts 与 PowerShell 使用说明（中文）

本仓库已内置以下 Windows 侧辅助脚本：

- `patches/LocalScripts/00ActivateDHCP.py`：按 metadata 中 DHCP 网卡列表启用 DHCP
- `patches/LocalScripts/01ActivateAdministrator.py`：当 Cloudbase-Init 用户为本地管理员名时，自动启用内置管理员账户
- `patches/LocalScripts/99EjectDrive.py`：完成后弹出 config-2 光驱
- `patches/powershell/ModifyConf.ps1`：将 Cloudbase-Init 配置中的默认英文管理员/组名替换为系统本地语言对应名称
- `patches/powershell/FixUserService.ps1`：安装 OpenSSH Server、调整 cloudbase-init 服务用户为 LocalSystem、清理可能影响 sysprep 的语言包
- `patches/powershell/sysprep.bat`：执行 sysprep 封装并关机

推荐顺序：

1. 在 Windows 模板机中安装 Cloudbase-Init Continuous Build
2. 将 `patches/LocalScripts/*.py` 复制到 `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\`
3. 在管理员 PowerShell 中执行 `patches/powershell/ModifyConf.ps1`
4. 再执行 `patches/powershell/FixUserService.ps1`
5. 确认系统状态后执行 `patches/powershell/sysprep.bat`

说明：

- 这些脚本运行在 Windows 客体内，不在 PVE 宿主机执行
- 仅用于 Windows + Cloudbase-Init 模板制作流程，不影响 Linux 虚拟机
- PowerShell 脚本需以管理员权限运行

---

## 注意事项

- 补丁以明文写入 `cipassword`，**仅应在内网/可信环境下使用**
- 补丁对系统其他部分无副作用，但建议在 PVE 大版本升级（如 8.x → 9.x）后重新执行 `apply_patch.sh`，
  脚本会自动检测是否需要重新应用
- 每次应用前，脚本会自动备份原始文件到 `/root/pve_cloudinit_backup_<timestamp>/`
- 若本地 patch 文件不存在，脚本会尝试从 GitHub 下载；如需离线使用，请提前将 patch 文件放入对应子目录

---

## 贡献推导补丁

如果 `apply_patch.sh` 为你的 PVE 版本自动生成了推导补丁（保存在 `patches/qemu-server-X.Y.Z/`），
欢迎将该目录提交为 Pull Request，帮助其他相同版本的用户直接使用精确匹配的补丁。

---

## 上游来源

- Geco-Cloudbase-Init: <https://github.com/kruisdraad/Geco-Cloudbase-Init>
- 原始补丁作者: [@kruisdraad](https://github.com/kruisdraad)
