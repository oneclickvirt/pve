qm create 100 --agent 1 --scsihw virtio-scsi-single --serial0 socket --cores 1 --sockets 1 --net0 virtio,bridge=vmbr1
qm importdisk 100 /root/qcow/ubuntu22.qcow2 local
qm set 100 --scsihw virtio-scsi-pci --scsi0 local:100/vm-100-disk-0.raw
qm set 100 --memory 1024
qm set 100 --ide2 local:cloudinit
qm set 100 --nameserver 8.8.8.8
qm set 100 --searchdomain 8.8.4.4
qm set 100 --ipconfig0 ip=172.16.1.2/24,gw=172.16.1.1
qm set 100 --cipassword 123456 --ciuser test
