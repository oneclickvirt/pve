#!/bin/bash

apt-get install -y libguestfs-tools rng-tools curl
apt-get install -y libguestfs-tools rng-tools curl --fix-missing
curl -o rebuild_qcow2.sh https://raw.githubusercontent.com/spiritLHLS/pve/main/back/rebuild_qcow2.sh
chmod 777 rebuild_qcow2.sh
# fedora33.qcow2 fedora34.qcow2 opensuse-leap-15.qcow2 archlinux.qcow2
# ubuntu18.qcow2 ubuntu20.qcow2 ubuntu22.qcow2 debian9.qcow2 debian10.qcow2 debian11.qcow2 centos9-stream.qcow2 centos8-stream.qcow2
# alpinelinux_v3_15.qcow2 alpinelinux_v3_17.qcow2 QuTScloud_5.0.1.qcow2 routeros_v6.qcow2 routeros_v7.qcow2 rockylinux8.qcow2 centos7.qcow2 almalinux8.qcow2 almalinux9.qcow2
for image in ubuntu18.qcow2 ubuntu20.qcow2 ubuntu22.qcow2 debian9.qcow2 debian10.qcow2 debian11.qcow2 centos9-stream.qcow2 centos8-stream.qcow2 almalinux8.qcow2 almalinux9.qcow2; do
  curl -o $image "https://cdn-backblaze.down.idc.wiki//Image/realServer-Template/$image"
#   curl -o $image "https://github.com/spiritLHLS/Images/releases/download/v1.0/$image"
  chmod 777 $image
done
for image in ubuntu18.qcow2 ubuntu20.qcow2 ubuntu22.qcow2 debian9.qcow2 debian10.qcow2 debian11.qcow2 centos9-stream.qcow2 centos8-stream.qcow2 almalinux8.qcow2 almalinux9.qcow2; do
  ./rebuild_qcow2.sh $image
done
