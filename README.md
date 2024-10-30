mkdir /wg
cd /wg/
touch wgd.sh

//将脚本复制进去
https://raw.githubusercontent.com/OwlOooo/wireguard/refs/heads/main/wgd.sh

chmod +x /wg/wgd.sh
ln -sf /wg/wgd.sh /usr/local/bin/wgd
hash -r
