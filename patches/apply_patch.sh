#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# patches/apply_patch.sh
#
# 自动检测 qemu-server 版本，选择最合适的 patch，应用 Windows Cloudbase-Init 支持补丁。
# 对于未覆盖的版本，自动尝试模糊匹配或推导补丁并保存到新子目录。
#
# 用法:
#   bash apply_patch.sh          # 检测版本并自动应用
#   bash apply_patch.sh --dry-run  # 仅预检测，不实际修改
#   bash apply_patch.sh --revert   # 回滚补丁
#   bash apply_patch.sh --status   # 检查补丁是否已应用

set -euo pipefail

############################################################
# 颜色输出
############################################################
_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }

############################################################
# 基础路径
############################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDINIT_PM="/usr/share/perl5/PVE/QemuServer/Cloudinit.pm"
QEMU_PM="/usr/share/perl5/PVE/API2/Qemu.pm"
GECO_BASE="https://raw.githubusercontent.com/kruisdraad/Geco-Cloudbase-Init/master"

############################################################
# 已知 patch 版本及其适用的 qemu-server 版本区间
# 格式: "patch_dir:min_ver:max_ver"  (字典序比较)
############################################################
KNOWN_PATCHES=(
    "qemu-server-6.4-2:6.0.0:6.99.99"
    "qemu-server-7.1-4:7.0.0:7.2.99"
    "qemu-server-7.3-4:7.3.0:7.3.99"
    "qemu-server-7.4-7:7.4.0:7.4.99"
    "qemu-server-8.0.8:8.0.0:8.0.9"
    "qemu-server-8.0.10:8.0.10:8.0.99"
    "qemu-server-8.1.4:8.1.0:8.1.99"
    "qemu-server-8.2.3:8.2.0:8.2.3"
)

############################################################
# 版本比较工具（用于纯数字版本，如 8.0.10 vs 8.0.8）
############################################################
ver_to_int() {
    # 将 "8.0.10" → "0800000010"，用于字符串比较
    local v="$1"
    v="${v%%-*}"      # 去掉 epoch/release 部分如 "8.0.10~bpo12+1" → "8.0.10"
    local IFS=.
    local -a parts=($v)
    printf "%04d%04d%04d" "${parts[0]:-0}" "${parts[1]:-0}" "${parts[2]:-0}"
}


############################################################
# 获取当前 qemu-server 安装版本
############################################################
# 获取当前 qemu-server 安装版本
############################################################
get_qemu_ver() {
    local v
    v=$(dpkg-query -W -f='${Version}' qemu-server 2>/dev/null || true)
    if [[ -z "$v" ]]; then
        v=$(apt-cache show qemu-server 2>/dev/null | awk '/^Version:/{print $2; exit}' || true)
    fi
    # 去掉 epoch 和 bpo 后缀，仅保留 X.Y.Z
    v=$(echo "$v" | sed 's/:[^:]*://; s/~.*//')
    echo "$v"
}

############################################################
# 确保本地有 patch 文件；如果没有则从 Geco 上游下载
############################################################
ensure_patch_files() {
    local patch_dir="$1"
    local dir_path="$SCRIPT_DIR/$patch_dir"
    mkdir -p "$dir_path"
    local cloudinit_patch="$dir_path/Cloudinit.pm.patch"
    local qemu_patch="$dir_path/Qemu.pm.patch"
    local ver_name="${patch_dir#qemu-server-}"   # e.g. "7.1-4"

    if [[ ! -s "$cloudinit_patch" ]]; then
        _yellow "本地未找到 $patch_dir/Cloudinit.pm.patch，尝试从上游下载..."
        local url="$GECO_BASE/$patch_dir/Cloudinit.pm.patch"
        if curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$cloudinit_patch"; then
            _green "已下载 $patch_dir/Cloudinit.pm.patch"
        else
            rm -f "$cloudinit_patch"
            _red "下载失败: $url"
            return 1
        fi
    fi

    if [[ ! -s "$qemu_patch" ]]; then
        _yellow "本地未找到 $patch_dir/Qemu.pm.patch，尝试从上游下载..."
        local url="$GECO_BASE/$patch_dir/Qemu.pm.patch"
        if curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$qemu_patch"; then
            _green "已下载 $patch_dir/Qemu.pm.patch"
        else
            rm -f "$qemu_patch"
            _red "下载失败: $url"
            return 1
        fi
    fi
    return 0
}

############################################################
# 测试某个 patch 文件能否应用（--dry-run），返回 0=可以，1=不行
############################################################
test_patch() {
    local patch_file="$1"
    local fuzz="${2:-0}"
    patch --force --forward --backup \
          -p0 --directory / \
          --fuzz "$fuzz" \
          --dry-run \
          --input "$patch_file" \
          >/dev/null 2>&1
}

############################################################
# 应用 patch 文件（实际写入）
############################################################
apply_patch_file() {
    local patch_file="$1"
    local fuzz="${2:-0}"
    patch --force --forward --backup \
          -p0 --directory / \
          --fuzz "$fuzz" \
          --input "$patch_file"
}

############################################################
# 回滚 patch 文件（--reverse）
############################################################
revert_patch_file() {
    local patch_file="$1"
    local fuzz="${2:-0}"
    patch --force --reverse --backup \
          -p0 --directory / \
          --fuzz "$fuzz" \
          --input "$patch_file" \
          2>/dev/null || true
}

############################################################
# 检查补丁是否已经应用（通过关键特征判断）
############################################################
is_patch_applied() {
    grep -q 'default_dns' "$CLOUDINIT_PM" 2>/dev/null && \
    grep -q 'WINDOWS CLOUD-INIT MODIFICATION' "$QEMU_PM" 2>/dev/null
}

############################################################
# 检查是否已有原生 Cloudbase-Init 支持（PVE 8.2.4+ 原生支持）
# qemu-server 8.2.4 起，PVE 官方已在 Cloudinit.pm 中原生实现
# cloudbase_configdrive2_metadata，无需第三方补丁。
############################################################
is_native_support() {
    grep -q 'cloudbase_configdrive2_metadata' "$CLOUDINIT_PM" 2>/dev/null
}

############################################################
# 语义化修补（当 patch 文件无法直接应用时的最终兜底方案）
# 使用 perl 做结构化搜索替换，不依赖行号
############################################################
semantic_patch() {
    _yellow "尝试语义化修补（不依赖行号的 Perl 内联方式）..."
    local backup_dir="/root/pve_cloudinit_backup_$(date +%Y%m%d%H%M%S)"
    mkdir -p "$backup_dir"
    cp "$CLOUDINIT_PM" "$backup_dir/Cloudinit.pm.orig"
    cp "$QEMU_PM"     "$backup_dir/Qemu.pm.orig"
    _yellow "原始文件已备份至 $backup_dir"

    # ---- 修补 Qemu.pm ----
    # 在 cipassword 加密块前注入 ostype 读取，并跳过 Windows 的加密
    perl -i -0pe '
        # 在 cipassword 参数处理前注入 ostype 读取（如果还没有）
        unless (/WINDOWS CLOUD-INIT MODIFICATION/) {
            s/(my \$skip_cloud_init = extract_param\(\$param, .skip_cloud_init.\);)/
$1\n\n    # WINDOWS CLOUD-INIT MODIFICATION\n    my \$conf = PVE::QemuConfig->load_config(\$vmid);\n    my \$ostype = \$conf->{ostype};\n/;
        }
        # 用 Windows 版本检查包裹密码加密逻辑
        unless (/windows_version\(\$ostype\)/) {
            s/(\s+if \(defined\(my \$cipassword = \$param->\{cipassword\}\)\) \{[^}]+PVE::Tools::encrypt_pw\(\$cipassword\)\s+if \$cipassword !~ [^;]+;\s+\})/$1 =~ s{(PVE::Tools::encrypt_pw\(\$cipassword\)\s+if \$cipassword !~ [^;]+;)}{if (!(PVE::QemuServer::windows_version(\$ostype))) {\n            \$param->{cipassword} = PVE::Tools::encrypt_pw(\$cipassword)\n                if \$cipassword !~ \/^\\\$(?:[156]|2[ay])(\\\$.+){2}\/;\n        }}e/;
        }
    ' "$QEMU_PM" 2>/dev/null || true

    # 检查 Qemu.pm 是否修改成功（如果上面 perl 因版本差异失败，做简单的 sed 替换）
    if ! grep -q 'windows_version' "$QEMU_PM"; then
        _yellow "Perl 语义修补 Qemu.pm 失败，尝试 sed 方式..."
        # 先把旧加密行替换为带 Windows 判断的版本
        sed -i 's/\(\$param->{cipassword} = PVE::Tools::encrypt_pw(\$cipassword)\)/if (!(PVE::QemuServer::windows_version(\$ostype))) {\n        \1\n    }/g' \
            "$QEMU_PM" 2>/dev/null || true
    fi

    # ---- 修补 Cloudinit.pm ----
    # 在 configdrive2_network 函数中添加 Windows DNS 支持
    if ! grep -q 'windows_version' "$CLOUDINIT_PM"; then
        perl -i -0pe '
            # 在 configdrive2_network 函数开头注入变量声明
            s/(sub configdrive2_network \{[^\n]*\n    my \(\$conf\) = \@_;\n)/$1\n    ## support windows\n    my \$ostype = \$conf->{"ostype"};\n    my \$default_dns = "";\n    my \$default_search = "";\n    my \$dnsinserted = 0;\n    ##\n/;
            # 在 dns_nameservers 行后保存 default_dns
            s/(dns_nameservers[^"]*"\n)/$1        \$default_dns = \$nameservers; # Support windows\n/;
            # 在 dns_search 行后保存 default_search
            s/(dns_search[^"]*"\n)/$1        \$default_search = \$searchdomains; # Support Windows\n/;
        ' "$CLOUDINIT_PM" 2>/dev/null || true
    fi

    if is_patch_applied; then
        _green "语义化修补完成。"
        return 0
    else
        _red "语义化修补失败：无法自动处理当前版本，请参考 README.md 手动修补。"
        _yellow "已备份原始文件至: $backup_dir"
        return 1
    fi
}

############################################################
# 生成推导补丁文件（保存到新子目录，供后续直接使用）
############################################################
save_derived_patch() {
    local qemu_ver="$1"
    local derived_dir="$SCRIPT_DIR/qemu-server-${qemu_ver}"
    if [[ -d "$derived_dir" ]]; then
        return 0  # 已存在
    fi
    mkdir -p "$derived_dir"
    cat >"$derived_dir/VERSION_RANGE.txt" <<EOF
# Auto-derived patch directory
# qemu-server version: ${qemu_ver}
# Generated by apply_patch.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# This patch was auto-derived from the nearest known patch version
# because no exact patch existed for qemu-server ${qemu_ver}.
# It was successfully applied with patch --fuzz.
#
# Range: ${qemu_ver} only (exact match for this derived version)
EOF
    # 从当前已修改的文件生成 diff
    local backup_dir
    backup_dir=$(ls -dt /root/pve_cloudinit_backup_* 2>/dev/null | head -1)
    if [[ -n "$backup_dir" ]] && [[ -f "$backup_dir/Cloudinit.pm.orig" ]]; then
        diff -u "$backup_dir/Cloudinit.pm.orig" "$CLOUDINIT_PM" \
            >"$derived_dir/Cloudinit.pm.patch" 2>/dev/null \
            || true
    fi
    if [[ -n "$backup_dir" ]] && [[ -f "$backup_dir/Qemu.pm.orig" ]]; then
        diff -u "$backup_dir/Qemu.pm.orig" "$QEMU_PM" \
            >"$derived_dir/Qemu.pm.patch" 2>/dev/null \
            || true
    fi
    _green "已将推导补丁保存至 $derived_dir （可提交到仓库供他人使用）"
}

############################################################
# 选择最合适的 patch 目录
# 策略: 精确版本区间 → 最近高版本 → 最新已知版本
############################################################
select_best_patch_dir() {
    local qemu_ver="$1"
    local best_dir=""
    local fallback_dir=""
    local qv_int
    qv_int=$(ver_to_int "$qemu_ver")

    for entry in "${KNOWN_PATCHES[@]}"; do
        local dir min max
        dir="${entry%%:*}"
        min="${entry#*:}"; min="${min%:*}"
        max="${entry##*:}"
        local min_int max_int
        min_int=$(ver_to_int "$min")
        max_int=$(ver_to_int "$max")
        if (( 10#$qv_int >= 10#$min_int && 10#$qv_int <= 10#$max_int )); then
            best_dir="$dir"
            break
        fi
        # 最近高版本备选（min_int 最接近但 < qv_int 的那个）
        if (( 10#$min_int <= 10#$qv_int )); then
            fallback_dir="$dir"
        fi
    done

    if [[ -n "$best_dir" ]]; then
        echo "$best_dir"
        return 0
    fi
    # 没有精确命中，返回最近低版本（或最新已知）
    if [[ -n "$fallback_dir" ]]; then
        echo "$fallback_dir"
        return 1   # 返回 1 表示是 fallback
    fi
    # 比所有已知版本都低，用最旧的
    local oldest="${KNOWN_PATCHES[0]%%:*}"
    echo "$oldest"
    return 1
}

############################################################
# 备份原始文件
############################################################
backup_originals() {
    local backup_dir="/root/pve_cloudinit_backup_$(date +%Y%m%d%H%M%S)"
    mkdir -p "$backup_dir"
    cp "$CLOUDINIT_PM" "$backup_dir/Cloudinit.pm.orig"
    cp "$QEMU_PM"     "$backup_dir/Qemu.pm.orig"
    echo "$backup_dir"
}

############################################################
# 主逻辑：应用补丁
############################################################
cmd_apply() {
    local dry_run="${1:-false}"

    _blue "======================================================"
    _blue " Windows Cloudbase-Init 补丁自动应用器"
    _blue "======================================================"

    # 前置检查
    if [[ ! -f "$CLOUDINIT_PM" ]]; then
        _red "未找到 $CLOUDINIT_PM，请确认 qemu-server 已安装。"
        exit 1
    fi
    if [[ ! -f "$QEMU_PM" ]]; then
        _red "未找到 $QEMU_PM，请确认 qemu-server 已安装。"
        exit 1
    fi

    # 检测版本
    local qemu_ver
    qemu_ver=$(get_qemu_ver)
    if [[ -z "$qemu_ver" ]]; then
        _red "无法检测 qemu-server 版本，请确认 qemu-server 已安装。"
        exit 1
    fi
    _green "当前 qemu-server 版本: $qemu_ver"

    # 检查 PVE 是否已原生支持 Cloudbase-Init（8.2.4+）
    if is_native_support; then
        _green "检测到 PVE 已原生支持 Cloudbase-Init（qemu-server $qemu_ver 含 cloudbase_configdrive2_metadata）。"
        _green "无需额外补丁，PVE 8.2.4+ 已内置 Windows Cloudbase-Init 支持。"
        exit 0
    fi

    # 检查补丁是否已应用（仅识别本脚本注入的标记，避免与原生支持混淆）
    if is_patch_applied; then
        _green "检测到补丁已经应用（命中补丁标记），无需重复操作。"
        exit 0
    fi

    # 选择 patch 目录
    local patch_dir is_fallback=0
    patch_dir=$(select_best_patch_dir "$qemu_ver") || is_fallback=1
    _blue "匹配 patch 目录: $patch_dir$([ $is_fallback -eq 1 ] && echo ' (最近兜底版本)')"

    # 确保 patch 文件存在
    if ! ensure_patch_files "$patch_dir"; then
        _red "无法获取 patch 文件，请检查网络或手动放置补丁文件。"
        exit 1
    fi

    local cloudinit_patch="$SCRIPT_DIR/$patch_dir/Cloudinit.pm.patch"
    local qemu_patch="$SCRIPT_DIR/$patch_dir/Qemu.pm.patch"

    # 尝试以不同 fuzz 值预检测
    local apply_fuzz=0
    local can_apply=false
    for fuzz in 0 3 6 10; do
        if test_patch "$cloudinit_patch" "$fuzz" && test_patch "$qemu_patch" "$fuzz"; then
            apply_fuzz=$fuzz
            can_apply=true
            [[ $fuzz -gt 0 ]] && _yellow "patch 需要 --fuzz $fuzz 才能应用（行号有偏移）"
            break
        fi
    done

    if "$can_apply"; then
        _green "预检测通过（fuzz=$apply_fuzz）"
        [[ "$dry_run" == "true" ]] && { _blue "dry-run 模式，不实际修改。"; exit 0; }

        _yellow "正在备份原始文件..."
        local backup_dir
        backup_dir=$(backup_originals)
        _green "备份至: $backup_dir"

        _yellow "正在应用 Cloudinit.pm.patch ..."
        apply_patch_file "$cloudinit_patch" "$apply_fuzz"
        _yellow "正在应用 Qemu.pm.patch ..."
        apply_patch_file "$qemu_patch" "$apply_fuzz"

        # 如果是 fallback 版本或有 fuzz，推导并保存新补丁
        if [[ $is_fallback -eq 1 ]] || [[ $apply_fuzz -gt 0 ]]; then
            save_derived_patch "$qemu_ver"
        fi
    else
        # 所有标准 fuzz 都失败 → 如果还有其他 patch 版本没试，逐一尝试
        _yellow "当前 patch 目录无法应用，逐一尝试其他已知版本..."
        local found=false
        local qemu_major="${qemu_ver%%.*}"
        for phase in same_major other_major; do
            for entry in "${KNOWN_PATCHES[@]}"; do
                local alt_dir="${entry%%:*}"
                [[ "$alt_dir" == "$patch_dir" ]] && continue
                local alt_ver="${alt_dir#qemu-server-}"
                local alt_major="${alt_ver%%.*}"
                if [[ "$phase" == "same_major" && "$alt_major" != "$qemu_major" ]]; then
                    continue
                fi
                if [[ "$phase" == "other_major" && "$alt_major" == "$qemu_major" ]]; then
                    continue
                fi

                ensure_patch_files "$alt_dir" 2>/dev/null || continue
                local alt_ci="$SCRIPT_DIR/$alt_dir/Cloudinit.pm.patch"
                local alt_qm="$SCRIPT_DIR/$alt_dir/Qemu.pm.patch"
                for fuzz in 0 3 6 10; do
                    if test_patch "$alt_ci" "$fuzz" && test_patch "$alt_qm" "$fuzz"; then
                        _yellow "找到可用备选: $alt_dir (fuzz=$fuzz)"
                        [[ "$dry_run" == "true" ]] && { _blue "dry-run 模式，不实际修改。"; exit 0; }
                        local backup_dir
                        backup_dir=$(backup_originals)
                        _green "备份至: $backup_dir"
                        apply_patch_file "$alt_ci" "$fuzz"
                        apply_patch_file "$alt_qm" "$fuzz"
                        save_derived_patch "$qemu_ver"
                        found=true
                        break 3
                    fi
                done
            done
        done

        if ! "$found"; then
            _yellow "所有已知 patch 版本均无法直接应用，启用语义化补丁推导..."
            [[ "$dry_run" == "true" ]] && { _yellow "dry-run 模式下无法预览语义化补丁效果。"; exit 1; }
            local backup_dir
            backup_dir=$(backup_originals)
            _green "备份至: $backup_dir"
            if semantic_patch; then
                save_derived_patch "$qemu_ver"
            else
                _red "自动修补失败！正在从备份恢复..."
                cp "$backup_dir/Cloudinit.pm.orig" "$CLOUDINIT_PM"
                cp "$backup_dir/Qemu.pm.orig"     "$QEMU_PM"
                _yellow "请参考 patches/README.md 手动应用补丁。"
                exit 1
            fi
        fi
    fi

    # 验证
    if is_patch_applied; then
        _green "补丁应用成功！正在重启 pvedaemon..."
        systemctl restart pvedaemon.service && _green "pvedaemon 重启完成。" \
            || _yellow "重启 pvedaemon 失败，请手动执行: systemctl restart pvedaemon.service"
    else
        _red "补丁应用后未检测到预期的修改标记，请手动检查 $CLOUDINIT_PM 和 $QEMU_PM"
        exit 1
    fi
}

############################################################
# 回滚补丁
############################################################
cmd_revert() {
    _blue "======================================================"
    _blue " 回滚 Windows Cloudbase-Init 补丁"
    _blue "======================================================"

    if ! is_patch_applied; then
        _green "未检测到补丁标记，无需回滚。"
        exit 0
    fi

    local qemu_ver
    qemu_ver=$(get_qemu_ver)
    local patch_dir is_fallback=0
    patch_dir=$(select_best_patch_dir "$qemu_ver") || is_fallback=1

    # 优先使用推导补丁目录（更精确）
    local derived_dir="$SCRIPT_DIR/qemu-server-${qemu_ver}"
    if [[ -d "$derived_dir" ]] && [[ -s "$derived_dir/Cloudinit.pm.patch" ]]; then
        patch_dir="qemu-server-${qemu_ver}"
        _blue "使用推导补丁目录: $patch_dir"
    fi

    ensure_patch_files "$patch_dir" 2>/dev/null || {
        _yellow "无法获取 patch 文件，尝试从备份恢复..."
        local backup_dir
        backup_dir=$(ls -dt /root/pve_cloudinit_backup_* 2>/dev/null | head -1)
        if [[ -n "$backup_dir" ]] && [[ -f "$backup_dir/Cloudinit.pm.orig" ]]; then
            cp "$backup_dir/Cloudinit.pm.orig" "$CLOUDINIT_PM"
            cp "$backup_dir/Qemu.pm.orig"     "$QEMU_PM"
            _green "已从备份 $backup_dir 恢复原始文件。"
            systemctl restart pvedaemon.service 2>/dev/null || true
            exit 0
        fi
        _red "无备份文件，回滚失败。"
        exit 1
    }

    local cloudinit_patch="$SCRIPT_DIR/$patch_dir/Cloudinit.pm.patch"
    local qemu_patch="$SCRIPT_DIR/$patch_dir/Qemu.pm.patch"

    for fuzz in 0 3 6 10; do
        if revert_patch_file "$cloudinit_patch" "$fuzz" && \
           revert_patch_file "$qemu_patch" "$fuzz"; then
            _green "回滚成功，正在重启 pvedaemon..."
            systemctl restart pvedaemon.service && _green "重启完成。" || true
            exit 0
        fi
    done

    # patch --reverse 失败时从备份恢复
    _yellow "patch --reverse 失败，从备份恢复..."
    local backup_dir
    backup_dir=$(ls -dt /root/pve_cloudinit_backup_* 2>/dev/null | head -1)
    if [[ -n "$backup_dir" ]] && [[ -f "$backup_dir/Cloudinit.pm.orig" ]]; then
        cp "$backup_dir/Cloudinit.pm.orig" "$CLOUDINIT_PM"
        cp "$backup_dir/Qemu.pm.orig"     "$QEMU_PM"
        _green "已从备份 $backup_dir 恢复原始文件。"
        systemctl restart pvedaemon.service 2>/dev/null || true
        exit 0
    fi
    _red "回滚失败：无可用的备份文件。"
    exit 1
}

############################################################
# 状态检查
############################################################
cmd_status() {
    local qemu_ver
    qemu_ver=$(get_qemu_ver 2>/dev/null || echo "未知")
    echo "qemu-server 版本: $qemu_ver"
    if is_native_support; then
        _green "原生支持: 已启用（检测到 cloudbase_configdrive2_metadata）"
    else
        _yellow "原生支持: 未检测到（需要补丁或后续升级）"
    fi
    if is_patch_applied; then
        _green "状态: Windows Cloudbase-Init 补丁 已应用"
    else
        _yellow "状态: Windows Cloudbase-Init 补丁 未应用"
    fi
    # 列出备份
    local backups
    backups=$(ls -dt /root/pve_cloudinit_backup_* 2>/dev/null | head -5 || true)
    if [[ -n "$backups" ]]; then
        echo "可用备份:"
        echo "$backups"
    fi
}

############################################################
# 入口
############################################################
MODE="${1:-}"
case "$MODE" in
    --dry-run) cmd_apply true  ;;
    --revert)  cmd_revert      ;;
    --status)  cmd_status      ;;
    "")        cmd_apply false ;;
    *)
        echo "用法: $0 [--dry-run | --revert | --status]"
        echo ""
        echo "  (无参数)   自动检测版本并应用补丁"
        echo "  --dry-run  仅预检测，不实际修改"
        echo "  --revert   回滚已应用的补丁"
        echo "  --status   显示当前补丁状态"
        exit 1
        ;;
esac
