#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2026.02.28

# 用颜色输出信息
_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }
is_noninteractive() {
    case "${noninteractive:-}" in
    true | TRUE | True | 1 | yes | YES | Yes | y | Y)
        return 0
        ;;
    esac
    case "${NONINTERACTIVE:-}" in
    true | TRUE | True | 1 | yes | YES | Yes | y | Y)
        return 0
        ;;
    esac
    return 1
}
reading() {
    local prompt="$1"
    local var_name="$2"
    local default_value="${3:-}"
    if is_noninteractive; then
        printf -v "$var_name" '%s' "$default_value"
        _yellow "noninteractive=true, using default for ${var_name}: ${default_value:-<empty>}"
    else
        read -rp "$(_green "$prompt")" "$var_name"
    fi
}
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    echo "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    echo "Locale set to $utf8_locale"
fi
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi
command -v apt-get &>/dev/null
apt_get_status=$?
command -v apt &>/dev/null
apt_status=$?
if [ $apt_get_status -ne 0 ] || [ $apt_status -ne 0 ]; then
    _yellow "The host environment does not have the apt package manager command, please check the system"
    _yellow "宿主机的环境无apt包管理器命令，请检查系统"
    exit 1
fi
apt-get install lsb-release -y
if ! command -v lshw >/dev/null 2>&1; then
    apt-get install lshw -y
fi
if ! command -v ifconfig >/dev/null 2>&1; then
    apt-get install net-tools -y
fi
if ! command -v sipcalc >/dev/null 2>&1; then
    apt-get install sipcalc -y
fi
if ! command -v rdisc6 >/dev/null 2>&1; then
    _blue "Installing ndisc6 package for IPv6 router discovery..."
    _green "正在安装 ndisc6 软件包用于 IPv6 路由器发现..."
    apt-get install ndisc6 -y
fi
if ! command -v python3 >/dev/null 2>&1; then
    _blue "Installing Python 3 for safe IPv6 address validation..."
    _green "正在安装 Python 3 以安全校验 IPv6 地址..."
    apt-get install python3 -y
fi

get_system_arch() {
    local sysarch="$(uname -m)"
    if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
        local sysarch="$(arch)"
    fi
    # 根据架构信息设置系统位数并下载文件,其余 * 包括了 x86_64
    case "${sysarch}" in
    "i386" | "i686" | "x86_64")
        system_arch="x86"
        ;;
    "armv7l" | "armv8" | "armv8l" | "aarch64")
        system_arch="arm"
        ;;
    "riscv64")
        system_arch="riscv64"
        ;;
    *)
        system_arch=""
        ;;
    esac
}

check_config() {
    _blue "The machine configuration should meet the minimum requirements of at least 2 cores 2G RAM 20G hard drive"
    _green "本机配置应当满足至少2核2G内存20G硬盘的最低要求"

    # 检查硬盘大小
    total_disk=$(df -h / | awk '/\//{print $2}')
    total_disk_num=$(echo $total_disk | sed -E 's/([0-9.]+)([GT])/\1 \2/')
    total_disk_num=$(awk '{printf "%.0f", $1 * ($2 == "T" ? 1024 : 1)}' <<<"$total_disk_num")
    if [ "$total_disk_num" -lt 20 ]; then
        _red "The machine configuration does not meet the minimum requirements: at least 20G hard drive"
        _red "This machine's hard drive configuration does not allow for the installation of PVE"
        _red "本机配置不满足最低要求：至少20G硬盘"
        _red "本机硬盘配置无法安装PVE"
    fi

    # 检查CPU核心数
    cpu_cores=$(grep -c ^processor /proc/cpuinfo)
    if [ "$cpu_cores" -lt 2 ]; then
        _red "The local machine configuration does not meet the minimum requirements: at least 2 core CPU"
        _red "The number of CPUs on this machine is configured in such a way that PVE cannot be installed"
        _red "本机配置不满足最低要求：至少2核CPU"
        _red "本机CPU数量配置无法安装PVE"
    fi

    # 检查内存大小
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    swap_info=$(free -m | awk '/^Swap:/{print $2}')
    if [ "$swap_info" -ne 0 ]; then
        total_mem=$((total_mem + swap_info))
    fi
    if [ "$total_mem" -lt 2048 ]; then
        _red "The machine configuration does not meet the minimum requirements: at least 2G RAM"
        _red "The local memory configuration cannot install PVE"
        _red "本机配置不满足最低要求：至少2G内存"
        _red "本机内存配置无法安装PVE"
    fi
}

is_public_ipv6() {
    local address="${1:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$address" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

global_unicast = ipaddress.IPv6Network("2000::/3")
non_public = (
    ipaddress.IPv6Network("2001::/32"),       # Teredo
    ipaddress.IPv6Network("2001:2::/48"),     # benchmarking
    ipaddress.IPv6Network("2001:10::/28"),    # ORCHID
    ipaddress.IPv6Network("2001:20::/28"),    # ORCHIDv2
    ipaddress.IPv6Network("2001:db8::/32"),   # documentation
    ipaddress.IPv6Network("2002::/16"),       # 6to4
    ipaddress.IPv6Network("3fff::/20"),       # documentation
)
usable = (
    address in global_unicast
    and address.is_global
    and not address.is_private
    and not address.is_multicast
    and not any(address in prefix for prefix in non_public)
)
raise SystemExit(0 if usable else 1)
PY
}

is_private_ipv6() {
    ! is_public_ipv6 "${1:-}"
}

pve_ipv6_json_probe() {
    local mode="$1" selected_interface="${2:-}" replacement_interface="${3:-}" payload
    case "$mode" in
        addresses|address_bindings|linklocal)
            if [ "${PVE_IPV6_ADDRESS_JSON_OVERRIDE+x}" = x ]; then
                payload="$PVE_IPV6_ADDRESS_JSON_OVERRIDE"
            else
                payload=$(LC_ALL=C NO_COLOR=1 ip -j -6 addr show) || return 1
            fi
            ;;
        gateway|default_interface|default_routes_restore)
            if [ "${PVE_IPV6_ROUTE_JSON_OVERRIDE+x}" = x ]; then
                payload="$PVE_IPV6_ROUTE_JSON_OVERRIDE"
            else
                payload=$(LC_ALL=C NO_COLOR=1 ip -j -6 route show default) || return 1
            fi
            ;;
        interfaces) payload=$(LC_ALL=C NO_COLOR=1 ip -d -j link show) || return 1 ;;
        *) return 1 ;;
    esac
    PVE_IPV6_PROBE_JSON="$payload" python3 - "$mode" "$selected_interface" "$replacement_interface" <<'PY'
import ipaddress
import json
import os
import re
import sys

mode, selected, replacement = sys.argv[1:]
raw = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', os.environ['PVE_IPV6_PROBE_JSON'])
interface_pattern = re.compile(r'[A-Za-z0-9_.:-]{1,15}')

def route_hops(row):
    hops = row.get('nexthops') or row.get('multipath')
    if hops is None:
        return [row]
    if not isinstance(hops, list) or not hops:
        raise ValueError('invalid default route nexthops')
    return hops

try:
    rows = json.loads(raw)
    if not isinstance(rows, list):
        raise ValueError('invalid iproute2 JSON')
    if mode in ('gateway', 'default_interface', 'default_routes_restore'):
        candidates = [row for row in rows if row.get('dst') in (None, '', 'default')]
        candidates.sort(key=lambda row: row.get('dev') != selected if selected else False)
        for row in candidates:
            if mode == 'default_interface':
                devices = [row.get('dev', '')]
                devices.extend(hop.get('dev', '') for hop in route_hops(row))
                device = next((value for value in devices if interface_pattern.fullmatch(value or '')), '')
                if device:
                    print(device)
                    break
            elif mode == 'gateway':
                for hop in route_hops(row):
                    device = hop.get('dev') or row.get('dev', '')
                    gateway = hop.get('gateway') or row.get('gateway', '')
                    if selected and device and device != selected:
                        continue
                    if gateway:
                        print(ipaddress.IPv6Address(gateway))
                        raise SystemExit(0)
            else:
                if row.get('type') not in (None, '', 'unicast'):
                    continue
                metric = row.get('metric')
                if metric is not None and (not isinstance(metric, int) or metric < 0):
                    raise ValueError('invalid default route metric')
                hops = route_hops(row)
                tokens = ['-6', 'route', 'replace', 'default']
                if len(hops) > 1 and metric is not None:
                    tokens.extend(['metric', str(metric)])
                for hop in hops:
                    device = hop.get('dev') or row.get('dev') or selected
                    if not interface_pattern.fullmatch(device or ''):
                        raise ValueError('invalid default route interface')
                    if device == selected and replacement:
                        device = replacement
                    if len(hops) > 1:
                        tokens.append('nexthop')
                    gateway = hop.get('gateway') or row.get('gateway', '')
                    gateway_address = ipaddress.IPv6Address(gateway) if gateway else None
                    if gateway:
                        tokens.extend(['via', gateway_address.compressed])
                    tokens.extend(['dev', device])
                    flags = hop.get('flags') or row.get('flags') or []
                    if isinstance(flags, str):
                        flags = [flags]
                    if len(hops) > 1:
                        weight = hop.get('weight', 1)
                        if not isinstance(weight, int) or not 1 <= weight <= 256:
                            raise ValueError('invalid default route nexthop weight')
                        tokens.extend(['weight', str(weight)])
                    if 'onlink' in flags or (gateway_address and gateway_address.is_link_local):
                        tokens.append('onlink')
                if len(hops) == 1 and metric is not None:
                    tokens.extend(['metric', str(metric)])
                print(' '.join(tokens))
    elif mode == 'interfaces':
        for row in rows:
            device = row.get('ifname', '')
            kind = (row.get('linkinfo') or {}).get('info_kind', '')
            if kind in {'bridge', 'veth', 'dummy', 'macvlan', 'ipvlan', 'sit', 'tun', 'tap'}:
                continue
            if device != 'lo' and interface_pattern.fullmatch(device):
                print(device)
    else:
        for row in rows:
            device = row.get('ifname', '')
            if selected and device != selected:
                continue
            for info in row.get('addr_info', []):
                if info.get('family') != 'inet6' or info.get('tentative') or info.get('dadfailed'):
                    continue
                if {'tentative', 'dadfailed'} & set(info.get('flags') or []):
                    continue
                address = ipaddress.IPv6Address(info['local'])
                prefix = info['prefixlen']
                if not isinstance(prefix, int) or not 0 <= prefix <= 128:
                    raise ValueError('invalid IPv6 prefix')
                if mode == 'addresses' and info.get('scope') == 'global' and address.is_global:
                    print(f'{address}/{prefix}')
                if mode == 'address_bindings' and info.get('scope') == 'global' and address.is_global:
                    if not interface_pattern.fullmatch(device):
                        raise ValueError('invalid interface for global IPv6 address')
                    print(f'{device}\t{address}/{prefix}')
                if mode == 'linklocal' and address.is_link_local:
                    print(f'{address}/{prefix}')
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

check_ipv6() {
    local preferred_interface rows
    preferred_interface=$(pve_ipv6_json_probe default_interface) || return 1
    rows=$(pve_ipv6_json_probe addresses "$preferred_interface") || return 1
    if [ -z "$rows" ]; then
        rows=$(pve_ipv6_json_probe addresses) || return 1
    fi
    IPV6="${rows%%/*}"
    IPV6="${IPV6%%$'\n'*}"
    if [ -n "$IPV6" ]; then
        is_public_ipv6 "$IPV6" || return 1
        printf '%s\n' "$IPV6" >/usr/local/bin/pve_check_ipv6
    else
        rm -f /usr/local/bin/pve_check_ipv6
    fi
}

check_interface() {
    if [ -z "$interface_2" ]; then
        interface=${interface_1}
        return
    fi
    if [ -z "$interface_1" ] && [ -z "$interface_2" ]; then
        interface="eth0"
        return
    fi
    local config_files=(
        "/etc/network/interfaces"
        "/etc/network/interfaces.d/50-cloud-init"
    )
    for config_file in "${config_files[@]}"; do
        if [ -f "$config_file" ]; then
            if grep -q "$interface_1" "$config_file"; then
                interface=${interface_1}
                return
            elif grep -q "$interface_2" "$config_file"; then
                interface=${interface_2}
                return
            fi
        fi
    done
    local interfaces_list
    interfaces_list=$(pve_ipv6_json_probe interfaces) || return 1
    if echo "$interfaces_list" | grep -q "^${interface_1}$"; then
        interface=${interface_1}
        return
    fi
    if echo "$interfaces_list" | grep -q "^${interface_2}$"; then
        interface=${interface_2}
        return
    fi
    interface="eth0"
    if ! echo "$interfaces_list" | grep -q "^eth0$" && [ -n "$interfaces_list" ]; then
        interface=$(echo "$interfaces_list" | head -n 1)
    fi
}

# 检测系统是否支持
get_system_arch
version=$(lsb_release -cs)
if [ "$system_arch" = "arm" ]; then
    _blue "system_arch: arm"
    _green "架构：arm"
    case $version in
    stretch | buster)
        _blue "The recognized system is $version"
        _green "识别到的系统为 $version"
        _blue "Will use Pixmox for low version PVE installations"
        _green "将使用 Pixmox 进行低版本的PVE安装"
        ;;
    bullseye | bookworm | trixie)
        _blue "The recognized system is $version"
        _green "识别到的系统为 $version"
        _blue "Will use Pxvirt for PVE installation"
        _green "将使用 Pxvirt 进行低版本的PVE安装"
        ;;
    *)
        _yellow "Error: Recognized as an unsupported version of Debian, but you can force an installation attempt or use the custom partitioning method to install the PVE"
        _yellow "Error: 识别为不支持的Debian版本，但你可以强行安装尝试或使用自定义分区的方法安装PVE"
        ;;
    esac
elif [ "$system_arch" = "riscv64" ]; then
    _blue "system_arch: riscv64"
    _green "架构：riscv64"
    case $version in
    trixie)
        _blue "The recognized system is $version"
        _green "识别到的系统为 $version"
        _blue "Will use PXVIRT trixie for riscv64 host installation"
        _green "将使用 PXVIRT trixie 进行 riscv64 宿主安装"
        ;;
    *)
        _yellow "riscv64 PXVIRT currently targets Debian 13 trixie; other releases are not recommended"
        _yellow "riscv64 PXVIRT 当前主要面向 Debian 13 trixie，其它版本暂不推荐"
        ;;
    esac
elif [ "$system_arch" = "x86" ] || [ "$system_arch" = "x86_64" ]; then
    _blue "system_arch: x86"
    _green "架构：x86"
    case $version in
    stretch | buster | bullseye | bookworm | trixie)
        _blue "The recognized system is $version"
        _green "识别到的系统为 $version"
        ;;
    *)
        _yellow "Error: Recognized as an unsupported version of Debian, but you can force an installation attempt or use the custom partitioning method to install the PVE"
        _yellow "Error: 识别为不支持的Debian版本，但你可以强行安装尝试或使用自定义分区的方法安装PVE"
        ;;
    esac
else
    _yellow "Error: Recognized as an unsupported architecture, but you can force an installation attempt or use the custom partitioning method to install PVE"
    _yellow "Error: 识别为不支持的架构，但你可以强行安装尝试或使用自定义分区的方法安装PVE"
fi

# 检测IPV6网络配置。只采信宿主机当前绑定的地址和准确前缀；
# 不从本地化的 rdisc6/ifconfig 输出推断额外可分配地址。
detected_interfaces=$(pve_ipv6_json_probe interfaces) || exit 1
preferred_interface=$(pve_ipv6_json_probe default_interface) || exit 1
if [ -n "$preferred_interface" ] && ! grep -Fxq "$preferred_interface" <<<"$detected_interfaces"; then
    preferred_interface=""
fi
interface_1="${preferred_interface:-$(printf '%s\n' "$detected_interfaces" | head -n 1)}"
interface_2=""
while IFS= read -r candidate; do
    if [ -n "$candidate" ] && [ "$candidate" != "$interface_1" ]; then
        interface_2="$candidate"
        break
    fi
done <<<"$detected_interfaces"
check_interface
live_cidrs=$(pve_ipv6_json_probe addresses "$interface") || exit 1
if [ -z "$live_cidrs" ]; then
    live_cidrs=$(pve_ipv6_json_probe addresses) || exit 1
fi
live_cidr="${live_cidrs%%$'\n'*}"
ipv6_address=""
ipv6_prefixlen=""
if [ -n "$live_cidr" ]; then
    ipv6_address="${live_cidr%/*}"
    ipv6_prefixlen="${live_cidr##*/}"
fi
ipv6_gateway=$(pve_ipv6_json_probe gateway "$interface") || exit 1
fe80_address=$(pve_ipv6_json_probe linklocal "$interface" | head -n 1) || exit 1
if [ -n "$ipv6_address" ]; then
    printf '%s\n' "$ipv6_address" >/usr/local/bin/pve_check_ipv6
    printf '%s\n' "$ipv6_prefixlen" >/usr/local/bin/pve_ipv6_prefixlen
else
    rm -f /usr/local/bin/pve_check_ipv6 /usr/local/bin/pve_ipv6_prefixlen
fi
if [ -n "$ipv6_gateway" ]; then
    printf '%s\n' "$ipv6_gateway" >/usr/local/bin/pve_ipv6_gateway
else
    rm -f /usr/local/bin/pve_ipv6_gateway
fi
if [ -n "$fe80_address" ]; then
    printf '%s\n' "$fe80_address" >/usr/local/bin/pve_fe80_address
else
    rm -f /usr/local/bin/pve_fe80_address
fi
rm -f /usr/local/bin/pve_ipv6_real_prefixlen
if [[ "$ipv6_gateway" == fe80* ]]; then
    ipv6_gateway_fe80="Y"
else
    ipv6_gateway_fe80="N"
fi
if [ -n "$ipv6_address" ] && [ -n "$ipv6_prefixlen" ] && [ -n "$ipv6_gateway" ]; then
    _blue "The following IPV6 information is detected for this machine:"
    _green "检测到本机的IPV6信息如下："
    _green "ipv6_address: ${ipv6_address}"
    _green "ipv6_prefixlen: ${ipv6_prefixlen}"
    _green "ipv6_gateway: ${ipv6_gateway}"
    if [[ "$ipv6_gateway_fe80" == "Y" || "$ipv6_address" == *ff:fe* ]]; then
        : >/usr/local/bin/pve_slaac_status
    fi
fi

# 检测硬件配置
check_config

# 检查 CPU 是否支持硬件虚拟化指令集
if [ "$(egrep -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
    _yellow "CPU does not support hardware virtualization (vmx/svm); nested KVM virtualization is not possible. You can still run LXC containers or QEMU with software emulation (TCG)."
    _yellow "CPU 不支持硬件虚拟化（缺少 vmx/svm 指令），无法进行嵌套 KVM 虚拟化。但仍可使用 LXC 容器或 QEMU 软件仿真（TCG）运行虚拟机。"
else
    _green "CPU supports hardware virtualization (vmx/svm); nested KVM virtualization is possible."
    _green "CPU 支持硬件虚拟化（支持 vmx/svm 指令），可用于嵌套 KVM 虚拟化。"
fi

# 检查宿主机是否启用了嵌套虚拟化
CPU_TYPE=""
if [ -e "/sys/module/kvm_intel/parameters/nested" ]; then
    NESTED=$(cat /sys/module/kvm_intel/parameters/nested | tr '[:upper:]' '[:lower:]')
    if [ "$NESTED" = "y" ] || [ "$NESTED" = "1" ]; then
        CPU_TYPE="intel"
        _green "Intel KVM module loaded with nested virtualization enabled."
        _green "已加载 Intel KVM 模块，嵌套虚拟化已启用。"
    else
        _yellow "Nested virtualization is supported by the Intel KVM module but currently disabled (nested=0)."
        _yellow "已加载 Intel KVM 模块，但嵌套虚拟化当前未启用（nested=0）。"
        _yellow "Will attempt to enable it. QEMU TCG (software emulation) remains available as fallback."
        _yellow "将尝试启用。QEMU TCG（软件仿真）仍可作为后备方案使用。"
        CPU_TYPE="intel"
    fi
elif [ -e "/sys/module/kvm_amd/parameters/nested" ]; then
    NESTED=$(cat /sys/module/kvm_amd/parameters/nested | tr '[:upper:]' '[:lower:]')
    if [ "$NESTED" = "1" ] || [ "$NESTED" = "y" ]; then
        CPU_TYPE="amd"
        _green "AMD KVM module loaded with nested virtualization enabled."
        _green "已加载 AMD KVM 模块，嵌套虚拟化已启用。"
    else
        _yellow "Nested virtualization is supported by the AMD KVM module but currently disabled (nested=0)."
        _yellow "已加载 AMD KVM 模块，但嵌套虚拟化当前未启用（nested=0）。"
        _yellow "Will attempt to enable it. QEMU TCG (software emulation) remains available as fallback."
        _yellow "将尝试启用。QEMU TCG（软件仿真）仍可作为后备方案使用。"
        CPU_TYPE="amd"
    fi
else
    _yellow "KVM kernel module with nested virtualization support is not loaded or not available in this environment."
    _yellow "未检测到启用嵌套虚拟化支持的 KVM 内核模块，可能是当前系统运行在虚拟机中且未开启嵌套虚拟化，或内核未加载 kvm_intel/kvm_amd 模块。"
    _yellow "PVE can still be installed. VMs will use QEMU TCG (software emulation) if KVM is not available."
    _yellow "PVE 仍可安装。若 KVM 不可用，虚拟机将使用 QEMU TCG（软件仿真）运行。"
fi

# 检查 kvm 模块是否已加载
if ! lsmod | grep -q kvm; then
    _yellow "KVM module is not currently loaded. KVM-based acceleration (hardware virtualization) will not be available."
    _yellow "当前未加载 KVM 模块，无法使用基于 KVM 的加速（硬件虚拟化）。"
    _yellow "You can still run virtual machines using QEMU TCG (software emulation), but performance may be poor."
    _yellow "仍可通过 QEMU TCG（软件仿真）运行虚拟机，但性能可能较差。"
    _yellow "Attempting to load the KVM module..."
    _yellow "正在尝试加载 KVM 模块……"
    if modprobe kvm; then
        grep -qxF "kvm" /etc/modules || echo "kvm" >> /etc/modules
        _green "Successfully loaded the KVM module and added it to /etc/modules."
        _green "KVM 模块已成功加载，并添加至 /etc/modules。"
    else
        _yellow "Failed to load the KVM module, continuing without hardware virtualization support."
        _yellow "KVM 模块加载失败，将继续使用软件虚拟化。"
    fi
else
    _green "KVM module is already loaded. Hardware virtualization is available for better performance."
    _green "KVM 模块已加载，可使用硬件虚拟化以获得更好性能。"
fi

# 检查并尝试加载 CPU 对应的嵌套模块（Intel 或 AMD）
if [ "$CPU_TYPE" = "intel" ] && ! lsmod | grep -q kvm_intel; then
    _yellow "Attempting to load Intel KVM module (kvm_intel)..."
    _yellow "正在尝试加载 Intel 的 KVM 模块（kvm_intel）……"
    if modprobe kvm_intel nested=1; then
        grep -qxF "kvm_intel" /etc/modules || echo "kvm_intel" >> /etc/modules
        _green "Loaded kvm_intel module with nested virtualization enabled."
        _green "已加载 kvm_intel 模块并启用嵌套虚拟化。"
    fi
elif [ "$CPU_TYPE" = "amd" ] && ! lsmod | grep -q kvm_amd; then
    _yellow "Attempting to load AMD KVM module (kvm_amd)..."
    _yellow "正在尝试加载 AMD 的 KVM 模块（kvm_amd）……"
    if modprobe kvm_amd nested=1; then
        grep -qxF "kvm_amd" /etc/modules || echo "kvm_amd" >> /etc/modules
        _green "Loaded kvm_amd module with nested virtualization enabled."
        _green "已加载 kvm_amd 模块并启用嵌套虚拟化。"
    fi
fi
