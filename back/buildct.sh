#!/bin/bash
# from
# https://github.com/spiritLHLS/pve
# 2023.04.17

cd /root >/dev/null 2>&1
# 创建容器
CTID="${1:-102}"
password="${2:-123456}"
core="${3:-1}"
memory="${4:-512}"
disk="${5:-5}"
sshn="${6:-40001}"
web1_port="${7:-40002}"
web2_port="${8:-40003}"
port_first="${9:-49975}"
port_last="${10:-50000}"
system="${12:-debian10}"
rm -rf "ct$name"
TMP_FILE="$(mktemp)"
echo "#cloud-config" > "$TMP_FILE"
echo "chpasswd:" >> "$TMP_FILE"
echo "  list: |" >> "$TMP_FILE"
echo "    root:$password" >> "$TMP_FILE"
pct create $CTID local:vztmpl/debian-11-standard_11.6-1_amd64.tar.zst --cores 1 --cpuunits 1024 --memory 2048 --swap 128 --net0 name=eth0,ip=172.16.1.2/24,bridge=vmbr1,gw=172.16.1.1 --rootfs local:10 --onboot 1
rm "$TMP_FILE"
