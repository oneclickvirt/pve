
### 存档的脚本 - 勿要使用 - 全是BUG

#### pve6.4升级为最新的pve7.x

自测中，勿要使用，未完成

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/pve6_to_pve7.sh -o pve6_to_pve7.sh && chmod +x pve6_to_pve7.sh && bash pve6_to_pve7.sh
```

替换qcow2

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/back/rebuild.sh -o rebuild.sh && chmod +x rebuild.sh && bash rebuild.sh
```

```

```

```
curl -L https://raw.githubusercontent.com/spiritLHLS/pve/main/buildvm.sh -o buildvm.sh && chmod +x buildvm.sh
```

```
./buildvm.sh 102 test1 1234567 1 512 5 40001 40002 40003 50000 50025 debian10
```

```
rm -rf vm* qcow *.sh
nft delete table nat
echo "" > /etc/nftables.conf
```
