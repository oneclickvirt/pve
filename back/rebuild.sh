#!/bin/bash

apt-get install -y libguestfs-tools rng-tools curl
apt-get install -y libguestfs-tools rng-tools curl --fix-missing
curl -o rebuild_qcow2.sh https://raw.githubusercontent.com/spiritLHLS/pve/main/back/rebuild_qcow2.sh
chmod 777 rebuild_qcow2.sh
for image in ubuntu18.qcow2 ubuntu20.qcow2 ubuntu22.qcow2 debian11.qcow2 debian12.qcow2 centos9-stream.qcow2 centos8-stream.qcow2 centos7.qcow2 almalinux8.qcow2 almalinux9.qcow2 alpinelinux_edge.qcow2 alpinelinux_stable.qcow2 rockylinux8.qcow2 rockylinux9.qcow2; do
  curl -o $image "https://down.idc.wiki/Image/realServer-Template/current/qcow2/$image"
#   curl -o $image "https://github.com/spiritLHLS/Images/releases/download/v1.0/$image"
  chmod 777 $image
done
for image in ubuntu18.qcow2 ubuntu20.qcow2 ubuntu22.qcow2 debian11.qcow2 debian12.qcow2 centos9-stream.qcow2 centos8-stream.qcow2 centos7.qcow2 almalinux8.qcow2 almalinux9.qcow2 alpinelinux_edge.qcow2 alpinelinux_stable.qcow2 rockylinux8.qcow2 rockylinux9.qcow2; do
  ./rebuild_qcow2.sh $image
done
