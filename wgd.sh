#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查root权限
check_root() {
   if [ "$(id -u)" != "0" ]; then
       echo -e "${RED}错误: 此脚本需要root权限运行${NC}"
       exit 1
   fi
}

# 安装WireGuard
install_wireguard() {
   echo -e "${YELLOW}开始安装 WireGuard...${NC}"
   
   # 更新系统
   apt update
   
   # 分步安装，避免冲突
   apt install -y wireguard
   apt install -y iptables
   apt install -y curl wget
   apt install -y qrencode
   apt install -y mtr
   apt install -y net-tools
   apt install -y iptables-persistent

   echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
   sysctl -p /etc/sysctl.d/99-wireguard.conf

   mkdir -p /etc/wireguard
   cd /etc/wireguard
   
   # 生成服务器密钥
   wg genkey | tee server_private.key | wg pubkey > server_public.key
   chmod 600 server_private.key

   # 获取服务器私钥
   SERVER_PRIVATE_KEY=$(cat server_private.key)

   # 创建服务器配置文件
   cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.0.0.1/24
PrivateKey = ${SERVER_PRIVATE_KEY}
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
SaveConfig = true
EOF

   chmod 600 /etc/wireguard/wg0.conf
   mkdir -p /etc/wireguard/clients
   
   # 配置防火墙规则
   iptables -F
   iptables -P INPUT ACCEPT
   iptables -P FORWARD ACCEPT
   iptables -P OUTPUT ACCEPT
   iptables -A INPUT -p udp --dport 51820 -j ACCEPT
   iptables -A FORWARD -i wg0 -j ACCEPT
   iptables -A FORWARD -o wg0 -j ACCEPT
   iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
   netfilter-persistent save

   # 启动WireGuard
   systemctl enable wg-quick@wg0
   systemctl start wg-quick@wg0

   echo -e "${GREEN}WireGuard 安装完成！${NC}"
   echo -e "${YELLOW}服务器公钥：$(cat server_public.key)${NC}"
}

# 重建服务器配置
rebuild_server_config() {
   echo -e "${YELLOW}重建服务器配置...${NC}"
   
   # 保存原始的Interface部分
   local SERVER_CONFIG=$(grep -A 4 "\[Interface\]" /etc/wireguard/wg0.conf)
   
   # 创建新的配置文件
   echo "$SERVER_CONFIG" > /etc/wireguard/wg0.conf
   
   # 添加所有客户端
   for conf in /etc/wireguard/clients/*.conf; do
       if [ -f "$conf" ]; then
           client_name=$(basename "$conf" .conf)
           client_public_key=$(cat "/etc/wireguard/clients/${client_name}_public.key")
           client_ip=$(grep "Address" "$conf" | cut -d'=' -f2 | tr -d ' ' | cut -d'/' -f1)
           
           echo -e "${GREEN}添加客户端: ${client_name}${NC}"
           cat >> /etc/wireguard/wg0.conf << PEER

[Peer]
# ${client_name}
PublicKey = ${client_public_key}
AllowedIPs = ${client_ip}/32
PEER
       fi
   done
   
   chmod 600 /etc/wireguard/wg0.conf
   
   # 重启服务
   echo -e "${YELLOW}重启 WireGuard 服务...${NC}"
   wg-quick down wg0 2>/dev/null
   wg-quick up wg0
   
   echo -e "${GREEN}服务器配置重建完成${NC}"
   echo -e "\n${YELLOW}当前配置：${NC}"
   cat /etc/wireguard/wg0.conf
   echo -e "\n${YELLOW}WireGuard 状态：${NC}"
   wg show
}

# 创建客户端
create_client() {
   if [ ! -f "/etc/wireguard/wg0.conf" ]; then
       echo -e "${RED}错误: WireGuard 未安装，请先安装${NC}"
       return 1
   fi

   read -p "请输入客户端名称: " CLIENT_NAME
   if [ -z "$CLIENT_NAME" ]; then
       echo -e "${RED}错误: 客户端名称不能为空${NC}"
       return 1
   fi

   if [ -f "/etc/wireguard/clients/${CLIENT_NAME}.conf" ]; then
       echo -e "${RED}错误: 客户端 ${CLIENT_NAME} 已存在${NC}"
       return 1
   fi

   read -p "请输入IP地址最后一位 (2-254): " IP_LAST
   if ! [[ "$IP_LAST" =~ ^[2-9]$|^[1-9][0-9]$|^1[0-9]{2}$|^2[0-4][0-9]$|^25[0-4]$ ]]; then
       echo -e "${RED}错误: IP地址最后一位必须在2-254之间${NC}"
       return 1
   fi

   # 生成客户端密钥
   cd /etc/wireguard/clients
   wg genkey | tee "${CLIENT_NAME}_private.key" | wg pubkey > "${CLIENT_NAME}_public.key"
   chmod 600 "${CLIENT_NAME}_private.key"

   # 获取所有需要的密钥和服务器信息
   CLIENT_PRIVATE_KEY=$(cat "${CLIENT_NAME}_private.key")
   CLIENT_PUBLIC_KEY=$(cat "${CLIENT_NAME}_public.key")
   SERVER_PUBLIC_KEY=$(cat /etc/wireguard/server_public.key)
   SERVER_ENDPOINT=$(curl -s ipv4.icanhazip.com)

   # 创建客户端配置文件
   cat > "/etc/wireguard/clients/${CLIENT_NAME}.conf" << EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.0.0.${IP_LAST}/24
DNS = 223.5.5.5, 223.6.6.6

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_ENDPOINT}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

   # 重建服务器配置
   rebuild_server_config

   echo -e "${GREEN}客户端 ${CLIENT_NAME} 创建成功！${NC}"
   echo -e "${YELLOW}配置文件位置：/etc/wireguard/clients/${CLIENT_NAME}.conf${NC}"
   
   # 显示客户端信息
   show_client_info "${CLIENT_NAME}"
}

# 显示客户端信息
show_client_info() {
   local CLIENT_NAME=$1
   local CONFIG_FILE="/etc/wireguard/clients/${CLIENT_NAME}.conf"
   
   if [ ! -f "$CONFIG_FILE" ]; then
       echo -e "${RED}错误: 客户端 ${CLIENT_NAME} 配置文件不存在${NC}"
       return 1
   fi

   echo -e "${YELLOW}===== 客户端 ${CLIENT_NAME} 配置信息 =====${NC}"
   echo -e "${GREEN}配置文件内容：${NC}"
   cat "$CONFIG_FILE"
   
   echo -e "\n${YELLOW}配置二维码：${NC}"
   qrencode -t ansiutf8 < "$CONFIG_FILE"
}

# 列出所有客户端
list_clients() {
   echo -e "${YELLOW}已配置的客户端：${NC}"
   if [ -d "/etc/wireguard/clients" ]; then
       local i=1
       for conf in /etc/wireguard/clients/*.conf; do
           if [ -f "$conf" ]; then
               client_name=$(basename "$conf" .conf)
               ip=$(grep "Address" "$conf" | cut -d= -f2 | tr -d ' ')
               echo -e "${GREEN}$i. 客户端: ${client_name}${NC}"
               echo -e "   IP: ${ip}"
               echo "------------------------"
               ((i++))
           fi
       done
   else
       echo -e "${RED}未找到任何客户端配置${NC}"
   fi
}

# 删除客户端
remove_client() {
   if [ ! -d "/etc/wireguard/clients" ] || ! ls /etc/wireguard/clients/*.conf >/dev/null 2>&1; then
       echo -e "${RED}没有找到任何客户端配置${NC}"
       return 1
   fi

   echo -e "${YELLOW}可用的客户端：${NC}"
   local clients=()
   local i=1
   for conf in /etc/wireguard/clients/*.conf; do
       if [ -f "$conf" ]; then
           client_name=$(basename "$conf" .conf)
           clients+=("$client_name")
           echo -e "${GREEN}$i. ${client_name}${NC}"
           ((i++))
       fi
   done

   read -p "请输入要删除的客户端序号 [1-$((i-1))]: " choice
   if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $((i-1)) ]; then
       echo -e "${RED}无效的选择${NC}"
       return 1
   fi

   local selected_client="${clients[$((choice-1))]}"
   
   echo -e "${YELLOW}正在删除客户端: ${selected_client}${NC}"

   # 删除客户端文件
   rm -f "/etc/wireguard/clients/${selected_client}.conf"
   rm -f "/etc/wireguard/clients/${selected_client}_private.key"
   rm -f "/etc/wireguard/clients/${selected_client}_public.key"

   # 重建服务器配置
   rebuild_server_config

   echo -e "${GREEN}客户端 ${selected_client} 已成功删除${NC}"
}

# 显示菜单
show_menu() {
   clear
   echo -e "${GREEN}WireGuard 管理脚本${NC}"
   echo -e "${YELLOW}1.${NC} 安装 WireGuard"
   echo -e "${YELLOW}2.${NC} 创建客户端配置"
   echo -e "${YELLOW}3.${NC} 查看所有客户端"
   echo -e "${YELLOW}4.${NC} 显示特定客户端配置"
   echo -e "${YELLOW}5.${NC} 删除客户端"
   echo -e "${YELLOW}6.${NC} 重建服务器配置"
   echo -e "${YELLOW}7.${NC} 退出"
   echo
}

# 主程序
main() {
   check_root

   while true; do
       show_menu
       read -p "请选择操作 [1-7]: " choice
       case $choice in
           1)
               install_wireguard
               read -p "按回车键继续..."
               ;;
           2)
               create_client
               read -p "按回车键继续..."
               ;;
           3)
               list_clients
               read -p "按回车键继续..."
               ;;
           4)
               echo -e "${YELLOW}可用的客户端：${NC}"
               ls -1 /etc/wireguard/clients/ | grep "\.conf$" | sed 's/\.conf$//'
               echo
               read -p "请输入要显示的客户端名称: " client_name
               if [ -n "$client_name" ]; then
                   show_client_info "$client_name"
               fi
               read -p "按回车键继续..."
               ;;
           5)
               remove_client
               read -p "按回车键继续..."
               ;;
           6)
               rebuild_server_config
               read -p "按回车键继续..."
               ;;
           7)
               echo -e "${GREEN}感谢使用！再见！${NC}"
               exit 0
               ;;
           *)
               echo -e "${RED}无效的选择，请重试${NC}"
               read -p "按回车键继续..."
               ;;
       esac
   done
}

# 运行主程序
main
