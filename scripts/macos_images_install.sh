#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.05.07

set -e

# Color functions
_red()    { echo -e "\033[31m\033[01m$@\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$@\033[0m"; }

# Read with colored prompt
reading() { read -rp "$(_green "$1")" "$2"; }

# Set UTF-8 locale if available
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found (未找到 UTF-8 本地化)"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    _green "Locale set to $utf8_locale (本地化已设置为 $utf8_locale)"
fi

# Configuration
DOWNLOAD_DIR="/var/lib/vz/template/iso"
DOWNLOAD_TASKS="$DOWNLOAD_DIR/download.tasks"
DECOMPRESS_TASKS="$DOWNLOAD_DIR/decompress.tasks"

# Ensure directories and task files exist
mkdir -p "$DOWNLOAD_DIR"
touch "$DOWNLOAD_TASKS" "$DECOMPRESS_TASKS"

# Check for 7z dependency
if ! command -v 7z >/dev/null 2>&1; then
  _red "错误：未找到 '7z' 命令。请安装 p7zip-full (ERROR: '7z' command not found. Please install p7zip-full)"
  exit 1
fi

# macOS .7z URLs
declare -A files=(
  [1]="big‑sur.iso.7z https://cnb.cool/oneclickvirt/template/-/lfs/e15404924199bcf92c6421980a74ad5fdde1dd18a83551726648bd0a1417133a"
  [2]="catalina.iso.7z   https://cnb.cool/oneclickvirt/template/-/lfs/660078c8a258c8bcde62c49897e5415751f5a17d30d40749a06ae81dc9b1c424"
  [3]="high-sierra.iso.7z https://cnb.cool/oneclickvirt/template/-/lfs/81ae1e766f12f94a283ee51a2b3a0c274ce31b578acdce7eddd22c5ff8cd045e"
  [4]="mojave.iso.7z     https://cnb.cool/oneclickvirt/template/-/lfs/4145b12588e14c933ad0d3e527b4e1f701b882d505d9dae463349f5062f7b6b1"
  [5]="sequoia.iso.7z    https://cnb.cool/oneclickvirt/template/-/lfs/f22ad0a9eba713645b566fd6a45f55a0daf9f481e6872cca2407856c6fd33b45"
  [6]="sonoma.iso.7z     https://cnb.cool/oneclickvirt/template/-/lfs/b35ff92067171d72519df05a066d3494b7fdb0eac1603b0a8803c98716707e9c"
)

print_menu() {
  _blue "=== macOS 下载器 菜单 (macOS Downloader Menu) ==="
  for i in "${!files[@]}"; do
    name=${files[$i]%% *}
    _yellow "  $i) 下载 $name (Download $name)"
  done
  _yellow " 100) 显示当前下载任务 (Show current download tasks)"
  _yellow " 101) 删除下载任务及文件 (Delete a download task and file)"
  _yellow " 102) 解压 .7z 文件 (Extract 7z archives)"
  _yellow " 103) 显示当前解压任务 (Show current extraction tasks)"
  _yellow " 104) 删除解压任务及文件 (Delete an extraction task and file)"
  _yellow "   0) 退出 (Exit)"
}

# Fetch remote file size in bytes
get_remote_size() {
  local url=$1
  curl -sI "$url" | awk '/[Cc]ontent-[Ll]ength/ { print $2 }' | tr -d '\r'
}

# Get available space on DOWNLOAD_DIR in bytes
get_avail_space() {
  df --output=avail -B1 "$DOWNLOAD_DIR" | tail -1
}

start_download() {
  local fileName=$1 url=$2
  local size avail req

  size=$(get_remote_size "$url")
  if [[ -z "$size" ]]; then
    _red "错误：无法获取远程文件大小 (Error: Unable to determine remote file size)"
    return
  fi

  avail=$(get_avail_space)
  req=$(( size * 2 + 2*1024*1024*1024 ))

  if (( avail < req )); then
    _red "空间不足: 可用=${avail} 字节, 需要=${req} 字节 (Insufficient space: available=${avail} bytes, required=${req} bytes)"
    return
  fi

  nohup curl -L "$url" -o "$DOWNLOAD_DIR/$fileName" >"$DOWNLOAD_DIR/$fileName.log" 2>&1 &
  pid=$!
  echo "$pid|$fileName|$url" >> "$DOWNLOAD_TASKS"
  _green "下载开始: PID=$pid, 文件=$fileName (Download started: PID=$pid, file=$fileName)"
}

show_downloads() {
  if [[ ! -s "$DOWNLOAD_TASKS" ]]; then
    _yellow "没有下载任务 (No download tasks)"
    return
  fi

  while IFS='|' read -r pid file url; do
    if ps -p "$pid" > /dev/null 2>&1; then
      downloaded=$(du -b "$DOWNLOAD_DIR/$file" 2>/dev/null | cut -f1 || echo 0)
      total=$(get_remote_size "$url")
      if [[ -n "$total" && "$total" -gt 0 ]]; then
        pct=$(awk "BEGIN{printf \"%.2f\", $downloaded*100/$total}")
        _blue "PID $pid: $file — $downloaded/$total 字节 ($pct%) (bytes)"
      else
        _blue "PID $pid: $file — $downloaded 字节 (总大小未知) (bytes, total size unknown)"
      fi
    else
      _yellow "PID $pid: 未运行 ▶ 从任务列表移除 (not running ▶ removing from task list)"
      grep -v "^$pid|" "$DOWNLOAD_TASKS" > "$DOWNLOAD_TASKS.tmp" && mv "$DOWNLOAD_TASKS.tmp" "$DOWNLOAD_TASKS"
    fi
  done < "$DOWNLOAD_TASKS"
}

delete_download() {
  reading "输入要删除的下载 PID (Enter download PID to delete): " pid
  if ! grep -q "^$pid|" "$DOWNLOAD_TASKS"; then
    _red "PID $pid 未找到 (PID $pid not found)"
    return
  fi
  line=$(grep "^$pid|" "$DOWNLOAD_TASKS")
  file=${line#*|}; file=${file%%|*}
  kill "$pid" 2>/dev/null || true
  rm -f "$DOWNLOAD_DIR/$file" "$DOWNLOAD_DIR/$file.log"
  grep -v "^$pid|" "$DOWNLOAD_TASKS" > "$DOWNLOAD_TASKS.tmp" && mv "$DOWNLOAD_TASKS.tmp" "$DOWNLOAD_TASKS"
  _green "已删除下载任务: $file (Deleted download task for $file)"
}

extract_7z() {
  mapfile -t archives < <(ls "$DOWNLOAD_DIR"/*.7z 2>/dev/null)
  if [[ ${#archives[@]} -eq 0 ]]; then
    _yellow "目录中无 .7z 文件 (No .7z archives found in $DOWNLOAD_DIR)"
    return
  fi
  _blue "可用 .7z 归档: (Available .7z archives:)"
  for i in "${!archives[@]}"; do
    num=$((i+1))
    _yellow "  $num) $(basename "${archives[i]}")"
  done
  reading "选择要解压的索引 (Select index to extract): " idx
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx<1 || idx> ${#archives[@]} )); then
    _red "无效选择 (Invalid selection)"
    return
  fi
  archive="${archives[$((idx-1))]}"
  nohup 7z x "$archive" -o"$DOWNLOAD_DIR" >"$DOWNLOAD_DIR/$(basename "$archive").extract.log" 2>&1 &
  pid=$!
  echo "$pid|$(basename "$archive")" >> "$DECOMPRESS_TASKS"
  _green "开始解压: PID=$pid, 归档=$(basename "$archive") (Extraction started)"
}

show_extracts() {
  if [[ ! -s "$DECOMPRESS_TASKS" ]]; then
    _yellow "没有解压任务 (No extraction tasks)"
    return
  fi

  while IFS='|' read -r pid archive; do
    if ps -p "$pid" > /dev/null 2>&1; then
      _blue "PID $pid: 正在解压 $archive (extracting)"
    else
      _yellow "PID $pid: 未运行 ▶ 从任务列表移除 (not running ▶ removing from task list)"
      grep -v "^$pid|" "$DECOMPRESS_TASKS" > "$DECOMPRESS_TASKS.tmp" && mv "$DECOMPRESS_TASKS.tmp" "$DECOMPRESS_TASKS"
    fi
  done < "$DECOMPRESS_TASKS"
}

delete_extract() {
  reading "输入要删除的解压 PID (Enter extraction PID to delete): " pid
  if ! grep -q "^$pid|" "$DECOMPRESS_TASKS"; then
    _red "PID $pid 未找到 (PID $pid not found)"
    return
  fi
  line=$(grep "^$pid|" "$DECOMPRESS_TASKS")
  archive=${line#*|}
  iso="${archive%.7z}.iso"
  kill "$pid" 2>/dev/null || true
  rm -f "$DOWNLOAD_DIR/$iso" "$DOWNLOAD_DIR/$archive.extract.log"
  grep -v "^$pid|" "$DECOMPRESS_TASKS" > "$DECOMPRESS_TASKS.tmp" && mv "$DECOMPRESS_TASKS.tmp" "$DECOMPRESS_TASKS"
  _green "已删除解压任务: $archive (Deleted extraction task for $archive)"
}

# Main loop
while true; do
  print_menu
  reading "选择操作 (Choice): " choice
  case "$choice" in
    [1-6])
      pair=${files[$choice]}
      fname=${pair%% *}
      furl=${pair#* }
      start_download "$fname" "$furl"
      ;;
    100) show_downloads   ;;
    101) delete_download  ;;
    102) extract_7z       ;;
    103) show_extracts    ;;
    104) delete_extract   ;;
    0)   _green "再见！ (Goodbye!)"; exit 0 ;;
    *)   _red "无效选项 (Invalid option)" ;;
  esac
  echo
done
