#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.04.12

# cd /root

red() { echo -e "\033[31m\033[01m$@\033[0m"; }
green() { echo -e "\033[32m\033[01m$@\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(green "$1")" "$2"; }

pre_check(){
    home_dir=$(eval echo "~$(whoami)")
    if [ "$home_dir" != "/root" ]; then
        red "当前路径不是/root，脚本将退出。"
        exit 1
    fi
    if ! command -v dos2unix > /dev/null 2>&1; then
        apt-get install dos2unix -y
    fi
    if [ ! -f "buildvm.sh" ]; then
      curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/buildvm.sh -o buildvm.sh && chmod +x buildvm.sh
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
      yellow "当前目录下不存在vmlog文件"
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
      green "当前最后一个NAT服务器对应的信息："
      echo "NAT服务器: $vm_num"
    #   echo "用户名: $user"
    #   echo "密码: $password"
      echo "外网SSH端口: $ssh_port"
      echo "外网80端口: $web1_port"
      echo "外网443端口: $web2_port"
      echo "外网其他端口范围: $port_start-$port_end"
      echo "系统：$system"
    fi
}

build_new_vms(){
    while true; do
        reading "还需要生成几个NAT服务器？(输入新增几个NAT服务器)：" new_nums
        if [[ "$new_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            yellow "输入无效，请输入一个正整数。"
        fi
    done
    for ((i=1; i<=$new_nums; i++)); do
        vm_num=$(($vm_num + 1))
        ori=$(date | md5sum)
        user=${ori: 2: 4}
        ori=$(date | md5sum)
        password=${ori: 2: 9}
        ssh_port=$(($web2_port + 1))
        web1_port=$(($web2_port + 2)) 
        web2_port=$(($web1_port + 3))
        port_start=$(($port_end + 1))
        port_end=$(($port_start + 25))
        ./buildvm.sh $vm_num $user $password 1 512 5 $ssh_port $web1_port $web2_port $port_start $port_end debian10
        cat "vm$vm_num" >> vmlog
        rm -rf "vm$vm_num"
    done
}

pre_check
check_info
build_new_vms
check_info
