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

# 检查系统
check_system() {
    if ! grep -qi 'debian\|ubuntu' /etc/os-release; then
        echo -e "${RED}错误: 此脚本仅支持 Debian/Ubuntu 系统${NC}"
        exit 1
    fi
}

# 安装WireGuard
install_wireguard() {
    echo -e "${YELLOW}开始安装 WireGuard...${NC}"
    
    # 更新系统并安装必要的包
    apt update
    apt upgrade -y
    apt install -y wireguard iptables iptables-persistent ufw curl wget qrencode mtr net-tools

    # 配置系统参数
    cat > /etc/sysctl.d/99-wireguard.conf << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF
    sysctl -p /etc/sysctl.d/99-wireguard.conf

    # 配置防火墙
    iptables -F
    iptables -t nat -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -p udp --dport 51820 -j ACCEPT
    iptables -A FORWARD -i wg0 -j ACCEPT
    iptables -A FORWARD -o wg0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    netfilter-persistent save

    # 创建WireGuard配置
    mkdir -p /etc/wireguard
    cd /etc/wireguard
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    chmod 600 server_private.key

    # 创建基本配置文件
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.0.0.1/24
PrivateKey = $(cat server_private.key)
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
SaveConfig = true
EOF

    chmod 600 /etc/wireguard/wg0.conf

    # 创建客户端目录
    mkdir -p /etc/wireguard/clients

    # 启动服务
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0

    echo -e "${GREEN}WireGuard 安装完成！${NC}"
    echo -e "${YELLOW}服务器公钥：$(cat /etc/wireguard/server_public.key)${NC}"
}

# 创建客户端
create_client() {
    echo -e "${YELLOW}创建新的客户端配置${NC}"
    
    # 检查WireGuard是否已安装
    if [ ! -f "/etc/wireguard/wg0.conf" ]; then
        echo -e "${RED}错误: WireGuard 未安装，请先安装 WireGuard${NC}"
        return 1
    fi

    # 输入客户端名称
    read -p "请输入客户端名称: " CLIENT_NAME
    if [ -z "$CLIENT_NAME" ]; then
        echo -e "${RED}错误: 客户端名称不能为空${NC}"
        return 1
    fi

    # 检查客户端是否已存在
    if [ -f "/etc/wireguard/clients/${CLIENT_NAME}.conf" ]; then
        echo -e "${RED}错误: 客户端 ${CLIENT_NAME} 已存在${NC}"
        return 1
    }

    # 输入IP地址最后一位
    read -p "请输入IP地址最后一位 (2-254): " IP_LAST
    if ! [[ "$IP_LAST" =~ ^[2-9]$|^[1-9][0-9]$|^1[0-9]{2}$|^2[0-4][0-9]$|^25[0-4]$ ]]; then
        echo -e "${RED}错误: IP地址最后一位必须在2-254之间${NC}"
        return 1
    fi

    # 生成客户端密钥
    cd /etc/wireguard/clients
    wg genkey | tee "${CLIENT_NAME}_private.key" | wg pubkey > "${CLIENT_NAME}_public.key"
    chmod 600 "${CLIENT_NAME}_private.key"

    # 创建客户端配置文件
    cat > "/etc/wireguard/clients/${CLIENT_NAME}.conf" << EOF
[Interface]
PrivateKey = $(cat "${CLIENT_NAME}_private.key")
Address = 10.0.0.${IP_LAST}/24
DNS = 223.5.5.5, 223.6.6.6

[Peer]
PublicKey = $(cat /etc/wireguard/server_public.key)
Endpoint = $(curl -s ipv4.icanhazip.com):51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

    # 添加客户端到服务器配置
    cat >> /etc/wireguard/wg0.conf << EOF

[Peer]
# ${CLIENT_NAME}
PublicKey = $(cat "${CLIENT_NAME}_public.key")
AllowedIPs = 10.0.0.${IP_LAST}/32
EOF

    # 重启WireGuard服务
    systemctl restart wg-quick@wg0

    echo -e "${GREEN}客户端 ${CLIENT_NAME} 创建成功！${NC}"
    echo -e "${YELLOW}配置文件位置：/etc/wireguard/clients/${CLIENT_NAME}.conf${NC}"
    echo -e "\n${YELLOW}配置二维码：${NC}"
    qrencode -t ansiutf8 < "/etc/wireguard/clients/${CLIENT_NAME}.conf"
}

# 显示菜单
show_menu() {
    clear
    echo -e "${GREEN}WireGuard 管理脚本${NC}"
    echo -e "${YELLOW}1.${NC} 安装 WireGuard"
    echo -e "${YELLOW}2.${NC} 创建客户端配置"
    echo -e "${YELLOW}3.${NC} 退出"
    echo
}

# 主程序
main() {
    check_root
    check_system

    while true; do
        show_menu
        read -p "请选择操作 [1-3]: " choice
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
