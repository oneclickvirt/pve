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
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 utf8)
if [[ -z "$utf8_locale" ]]; then
  _yellow "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  _green "Locale set to $utf8_locale"
fi


pre_check(){
    home_dir=$(eval echo "~$(whoami)")
    if [ "$home_dir" != "/root" ]; then
        _red "当前路径不是/root，脚本将退出。"
        exit 1
    fi
    if ! command -v dos2unix > /dev/null 2>&1; then
        apt-get install dos2unix -y
    fi
    if [ ! -f "buildct.sh" ]; then
      curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/scripts/buildct.sh -o buildct.sh && chmod +x buildct.sh
      dos2unix buildct.sh
    fi
}

# files=$(find . -maxdepth 1 -name "ct*" | sort)
# if [ -n "$files" ]; then
#   for file in $files
#   do
#     cat "$file" >> ctlog
#   done
# fi

check_info(){
    log_file="ctlog"
    if [ ! -f "ctlog" ]; then
      _yellow "当前目录下不存在ctlog文件"
      ct_num=302
      web2_port=20003
      port_end=30025
    else
      while read line; do
          last_line="$line"
      done < "$log_file"
      last_line_array=($last_line)
      ct_num="${last_line_array[0]}"
      password="${last_line_array[1]}"
      ssh_port="${last_line_array[2]}"
      web1_port="${last_line_array[3]}"
      web2_port="${last_line_array[4]}"
      port_start="${last_line_array[5]}"
      port_end="${last_line_array[6]}"
      system="${last_line_array[7]}"
      _green "当前最后一个NAT服务器对应的信息："
      echo "NAT服务器: $ct_num"
    #   echo "用户名: $user"
    #   echo "密码: $password"
      echo "外网SSH端口: $ssh_port"
      echo "外网80端口: $web1_port"
      echo "外网443端口: $web2_port"
      echo "外网其他端口范围: $port_start-$port_end"
      echo "系统：$system"
    fi
}

build_new_cts(){
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
        reading "每个虚拟机分配多少硬盘？(若每个虚拟机分配5G硬盘，则输入5)：" disk_nums
        if [[ "$disk_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    for ((i=1; i<=$new_nums; i++)); do
        ct_num=$(($ct_num + 1))
        ori=$(date | md5sum)
        password=${ori: 2: 9}
        ssh_port=$(($web2_port + 1))
        web1_port=$(($web2_port + 2)) 
        web2_port=$(($web1_port + 1))
        port_start=$(($port_end + 1))
        port_end=$(($port_start + 25))
        ./buildct.sh $ct_num $password $cpu_nums $memory_nums $disk_nums $ssh_port $web1_port $web2_port $port_start $port_end debian10
        cat "ct$ct_num" >> ctlog
        rm -rf "ct$ct_num"
        sleep 60
    done
}

pre_check
check_info
build_new_cts
check_info
