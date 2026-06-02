
## 无线环境安装

挂载U盘，这里的sdx1是查询到的U盘的实际路径，需要自行修改

```
fdisk -l
mount /dev/sdx1 /mnt
```

U盘内的wireless.zip已解压，打开可见其中的deb文件

此时直接执行一键配置

```
bash /mnt/wireless.sh
```

配置完毕会自动重启系统，重启后会有网络

配置脚本执行过程中会提示输入WIFI的名字和密码，由于纯CI环境无中文输入法，WIFI的名字必须仅英文数字组成，密码也是

无交互配置可使用：

```shell
export noninteractive=true
export WIFI_SSID="your_ssid"
export WIFI_PASSWORD="your_password"
bash /mnt/wireless.sh
```

如果是隐藏 SSID 或扫描不可用，可额外设置 `WIFI_SKIP_SCAN=true`。

## 其他初始设置

使用前务必确保```curl ip.sb```无问题

```shell
bash default.sh
```

执行会非常耗时
