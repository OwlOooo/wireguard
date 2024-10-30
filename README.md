mkdir /wg
cd /wg/
touch wgd.sh

# 将脚本复制进去
https://raw.githubusercontent.com/OwlOooo/wireguard/refs/heads/main/wgd.sh

chmod +x /wg/wgd.sh
ln -sf /wg/wgd.sh /usr/local/bin/wgd
hash -r

# wireguard一键安装和管理脚本

## 安装步骤

### Debain 系统

```bash
mkdir /wg
cd /wg/
touch wgd.sh
```

## 将脚本复制进去
```bash
https://raw.githubusercontent.com/OwlOooo/wireguard/refs/heads/main/wgd.sh
```

## 设置为系统命令，输入wgd
```bash
chmod +x /wg/wgd.sh
ln -sf /wg/wgd.sh /usr/local/bin/wgd
hash -r
```
