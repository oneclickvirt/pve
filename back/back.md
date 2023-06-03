- 安装过程中可能会退出安装，需要手动修复apt源，如下图所示修复完毕后再次执行本脚本

![图片](https://user-images.githubusercontent.com/103393591/220104992-9eed2601-c170-46b9-b8b7-de141eeb6da4.png)

![图片](https://user-images.githubusercontent.com/103393591/220105032-72623188-4c44-43c0-b3f1-7ce267163687.png)

- 查询网络配置是否为dhcp配置的V4网络，如果是则转换为静态地址避免重启后dhcp失效，已设置为只读模式，如需修改请使用```chattr -i /etc/network/interfaces.d/50-cloud-init```取消只读锁定，修改完毕请执行```chattr +i /etc/network/interfaces.d/50-cloud-init```只读锁定
