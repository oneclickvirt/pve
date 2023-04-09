#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.04.09

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
    if [ ! -f buildvm.sh ]; then
        curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/buildvm.sh
        chmod 777 buildvm.sh
        dos2unix buildvm.sh
    fi
}

# 检查当前目录下是否有vmlog文件
if [ ! -f "vmlog" ]; then
  yellow "当前目录下不存在vmlog文件"
  nat_num=200
  ssh_port=40000
  web1_port=40001
  web2_port=40002
#   port_start=50000
  port_end=50000
  echo "" > vmlog
else
  lines=$(cat vmlog | sed '/^$/d')
  last_line=$(echo "$lines" | tail -n 1)
  nat_num=$(echo "$last_line" | awk '{print $1}')
  user=$(echo "$last_line" | awk '{print $2}')
  password=$(echo "$last_line" | awk '{print $3}')
  ssh_port=$(echo "$last_line" | awk '{print $4}')
  web1_port=$(echo "$last_line" | awk '{print $5}')
  web2_port=$(echo "$last_line" | awk '{print $6}')
  port_start=$(echo "$last_line" | awk '{print $7}')
  port_end=$(echo "$last_line" | awk '{print $8}')
  green "最后一个NAT服务器对应的信息："
  echo "NAT服务器: $nat"
#   echo "用户名: $user"
#   echo "密码: $password"
  echo "外网SSH端口: $ssh_port"
  echo "外网80端口: $web1_port"
  echo "外网443端口: $web2_port"
  echo "外网其他端口范围: $port_start-$port_end"
fi

build_new_containers(){
    while true; do
        reading "还需要生成几个NAT服务器？(输入新增几个NAT服务器)：" new_nums
        if [[ "$new_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            yellow "输入无效，请输入一个正整数。"
        fi
    done
    for ((i=1; i<=$new_nums; i++)); do
        vm_num=$(($nat_num + 1))
        ori=$(date | md5sum)
        user=${ori: 2: 4}
        ori=$(date | md5sum)
        password=${ori: 2: 9}
        ssh_port=$(($ssh_port + 1))
        port_start=$(($port_end + 1))
        port_end=$(($port_start + 25))
        ./buildvm.sh $vm_num $user $password 1 512 5 $ssh_port $web1_port $web2_port $port_start $port_end 300 300
        cat "vm$vm_num" >> vmlog
        rm -rf "vm$vm_num"
    done
}



