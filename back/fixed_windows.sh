#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.09.16

cd /root >/dev/null 2>&1
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
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

check_china() {
    _yellow "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            _yellow "根据ipapi.co提供的信息，当前IP可能在中国"
            read -e -r -p "是否选用中国镜像完成相关组件安装? ([y]/n) " input
            case $input in
            [yY][eE][sS] | [yY])
                echo "使用中国镜像"
                CN=true
                ;;
            [nN][oO] | [nN])
                echo "不使用中国镜像"
                ;;
            *)
                echo "使用中国镜像"
                CN=true
                ;;
            esac
        else
            if [[ $? -ne 0 ]]; then
                if [[ $(curl -m 6 -s cip.cc) =~ "中国" ]]; then
                    _yellow "根据cip.cc提供的信息，当前IP可能在中国"
                    read -e -r -p "是否选用中国镜像完成相关组件安装? [Y/n] " input
                    case $input in
                    [yY][eE][sS] | [yY])
                        echo "使用中国镜像"
                        CN=true
                        ;;
                    [nN][oO] | [nN])
                        echo "不使用中国镜像"
                        ;;
                    *)
                        echo "不使用中国镜像"
                        ;;
                    esac
                fi
            fi
        fi
    fi
}

check_cdn() {
    local o_url=$1
    for cdn_url in "${cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, no use CDN"
    fi
}

# ChinaIP检测
check_china

# cdn检测
cdn_urls=("https://cdn.spiritlhl.workers.dev/" "https://cdn3.spiritlhl.net/" "https://cdn1.spiritlhl.net/" "https://ghproxy.com/" "https://cdn2.spiritlhl.net/")
check_cdn_file

# 提取大版本号
version=$(pveversion)
if [[ $version =~ /([0-9]+)\.[0-9]+- ]]; then
    major_version="${BASH_REMATCH[1]}"
    _green "Running kernel version: $major_version"
else
    _yellow "Unable to recognize Proxmox VE version number"
    exit 1
fi

# 克隆修复补丁的仓库
# https://github.com/GECO-IT/Geco-Cloudbase-Init
# https://forum.proxmox.com/threads/howto-scripts-to-make-cloudbase-work-like-cloudinit-for-your-windows-based-instances.103375/
if [[ -z "${CN}" || "${CN}" != true ]]; then
    cd /usr/local/bin/ && git clone git@github.com:GECO-IT/Geco-Cloudbase-Init.git
    cd /root >/dev/null 2>&1
else
    cd /usr/local/bin/ && git clone "${cdn_success_url}https://github.com/GECO-IT/Geco-Cloudbase-Init.git"
    cd /root >/dev/null 2>&1
fi

# 识别是否可替换对应版本镜像
if [ "$major_version" == "7" ]; then
    patch --force --forward --backup -p0 --directory / --input "/usr/local/bin/Geco-Cloudbase-Init/qemu-server-7.1-4/Cloudinit.pm.patch" --dry-run && patch_result1="You can apply patch" || patch_result1="Can't apply patch!"
    patch --force --forward --backup -p0 --directory / --input "/usr/local/bin/Geco-Cloudbase-Init/qemu-server-7.1-4/Qemu.pm.patch" --dry-run && patch_result2="You can apply patch" || patch_result2="Can't apply patch!"
    if [ "$patch_result1" == "You can apply patch" ] && [ "$patch_result2" == "You can apply patch" ]; then
        _green "Can apply both patches."
        patch --force --forward --backup -p0 --directory / --input "/usr/local/bin/Geco-Cloudbase-Init/qemu-server-7.1-4/Cloudinit.pm.patch"
        patch --force --forward --backup -p0 --directory / --input "/usr/local/bin/Geco-Cloudbase-Init/qemu-server-7.1-4/Qemu.pm.patch"
    else
        _yellow "Can't apply one or both patches!"
        exit 1
    fi
elif [ "$major_version" == "6" ]; then
    patch --force --forward --backup -p0 --directory / --input "/usr/local/bin/Geco-Cloudbase-Init/qemu-server-6.4-2/Cloudinit.pm.patch" --dry-run && patch_result1="You can apply patch" || patch_result1="Can't apply patch!"
    patch --force --forward --backup -p0 --directory / --input "/usr/local/bin/Geco-Cloudbase-Init/qemu-server-6.4-2/Qemu.pm.patch" --dry-run && patch_result2="You can apply patch" || patch_result2="Can't apply patch!"
    if [ "$patch_result1" == "You can apply patch" ] && [ "$patch_result2" == "You can apply patch" ]; then
        _green "Can apply both patches."
        patch --force --forward --backup -p0 --directory / --input "/usr/local/bin/Geco-Cloudbase-Init/qemu-server-6.4-2/Cloudinit.pm.patch" 
        patch --force --forward --backup -p0 --directory / --input "/usr/local/bin/Geco-Cloudbase-Init/qemu-server-6.4-2/Qemu.pm.patch"
    else
        _yellow "Can't apply one or both patches!"
        exit 1
    fi
else
    _yellow "Unsupported major version: $major_version"
    exit 1
fi
systemctl restart pvedaemon.service


# https://foxi.buduanwang.vip/windows/1789.html/