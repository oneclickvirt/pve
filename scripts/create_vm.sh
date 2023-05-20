#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.04.24

# cd /root

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
  echo "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
  echo "Locale set to $utf8_locale"
fi

check_cdn() {
  local o_url=$1
  for cdn_url in "${cdn_urls[@]}"; do
    if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" > /dev/null 2>&1; then
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

cdn_urls=("https://cdn.spiritlhl.workers.dev/" "https://cdn3.spiritlhl.net/" "https://cdn1.spiritlhl.net/" "https://ghproxy.com/" "https://cdn2.spiritlhl.net/")
check_cdn_file

pre_check(){
    home_dir=$(eval echo "~$(whoami)")
    if [ "$home_dir" != "/root" ]; then
        _red "当前路径不是/root，脚本将退出。"
        exit 1
    fi
    if ! command -v dos2unix > /dev/null 2>&1; then
        apt-get install dos2unix -y
    fi
    if [ ! -f "buildvm.sh" ]; then
      curl -L ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/buildvm.sh -o buildvm.sh && chmod +x buildvm.sh
      dos2unix buildvm.sh
    fi
}

# files=$(find . -maxdepth 1 -name "vm*" | sort)
# if [ -n "$files" ]; then
#   for file in $files
#   do
#     cat "$file" >> vmlog
#   done
# fi

check_info(){
    log_file="vmlog"
    if [ ! -f "vmlog" ]; then
      _yellow "当前目录下不存在vmlog文件"
      vm_num=202
      web2_port=40003
      port_end=50025
    else
      while read line; do
          last_line="$line"
      done < "$log_file"
      last_line_array=($last_line)
      vm_num="${last_line_array[0]}"
      user="${last_line_array[1]}"
      password="${last_line_array[2]}"
      ssh_port="${last_line_array[6]}"
      web1_port="${last_line_array[7]}"
      web2_port="${last_line_array[8]}"
      port_start="${last_line_array[9]}"
      port_end="${last_line_array[10]}"
      system="${last_line_array[11]}"
      storage="${last_line_array[12]}"
      _green "当前最后一个NAT服务器对应的信息："
      echo "NAT服务器: $vm_num"
    #   echo "用户名: $user"
    #   echo "密码: $password"
      echo "外网SSH端口: $ssh_port"
      echo "外网80端口: $web1_port"
      echo "外网443端口: $web2_port"
      echo "外网其他端口范围: $port_start-$port_end"
      echo "系统：$system"
      echo "存储盘：$storage"
    fi
}

build_new_vms(){
    while true; do
        reading "还需要生成几个NAT服务器？(输入新增几个NAT服务器)：" new_nums
        if [[ "$new_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    while true; do
        reading "每个虚拟机分配几个CPU？(若每个虚拟机分配1核，则输入1)：" cpu_nums
        if [[ "$cpu_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    while true; do
        reading "每个虚拟机分配多少内存？(若每个虚拟机分配512MB内存，则输入512)：" memory_nums
        if [[ "$memory_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    while true; do
        reading "虚拟机们开设在哪个存储盘上？(若虚拟机要开设在系统盘上，则留空或输入local)：" storage
        if [ -z "$storage" ]; then
          storage="local"
        fi
        output=$(pvesm list | grep "$storage")
        if [ -n "$output" ]; then
          echo "存储盘 '$storage' 存在于Proxmox VE中。"
          break
        else
          echo "存储盘 '$storage' 不存在于Proxmox VE中，请重新输入"
        fi
    done
    while true; do
        reading "每个虚拟机分配多少硬盘？(若每个虚拟机分配5G硬盘，则输入5)：" disk_nums
        if [[ "$disk_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    for ((i=1; i<=$new_nums; i++)); do
        vm_num=$(($vm_num + 1))
        user=$(cat /dev/urandom | tr -dc 'a-zA-Z' | fold -w 4 | head -n 1)
        ori=$(date | md5sum)
        password=${ori: 2: 9}
        ssh_port=$(($web2_port + 1))
        web1_port=$(($web2_port + 2)) 
        web2_port=$(($web1_port + 1))
        port_start=$(($port_end + 1))
        port_end=$(($port_start + 25))
        ./buildvm.sh $vm_num $user $password $cpu_nums $memory_nums $disk_nums $ssh_port $web1_port $web2_port $port_start $port_end debian10 $storage
        cat "vm$vm_num" >> vmlog
        rm -rf "vm$vm_num"
        sleep 60
    done
}

pre_check
check_info
build_new_vms
check_info
