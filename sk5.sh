#!/bin/bash

#=================================================
#	SOCKS5 代理自动安装与管理综合脚本 (纯净输出版)
#=================================================

# ----------------- 1. 安装 SOCKS5 代理 -----------------
install_socks5() {
    clear
    echo "====================================="
	echo "       开始安装 SOCKS5 代理服务      "
    echo "====================================="
    
    echo "请输入socks用户名 (直接回车默认: dwi668):"
    read socks_user
    socks_user=${socks_user:-dwi668}
    
    echo "请输入socks密码 (直接回车默认: dwi886):"
    read socks_pass
    socks_pass=${socks_pass:-dwi886}

    # 清空防火墙规则
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -t nat -F
    iptables -t mangle -F
    iptables -F
    iptables -X
    iptables-save >/dev/null 2>&1

    # 获取本机所有IP地址
    ips=($(hostname -I))

    # 安装 unzip 工具
    if command -v yum >/dev/null 2>&1; then
        yum install -y unzip || { echo "unzip 安装失败"; exit 1; }
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y unzip || { echo "unzip 安装失败"; exit 1; }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y unzip || { echo "unzip 安装失败"; exit 1; }
    else
        echo "未找到支持的包管理器 (yum/apt-get/dnf)"
        exit 1
    fi

    # Xray 安装
    if [ ! -f "/root/Xray-linux-64.zip" ]; then
        wget -O /root/Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/download/v1.6.1/Xray-linux-64.zip || { echo "下载失败"; exit 1; }
    else
        echo "/root 目录下已有 Xray-linux-64.zip，跳过下载步骤"
    fi

    # 创建 Xray 目录（如果不存在）
    if [ ! -d "/root/e1" ]; then
        mkdir -p /root/e1 || { echo "创建目录 /root/e1 失败"; exit 1; }
    fi

    # 解压文件到 /root/e1 目录
    sudo unzip -o /root/Xray-linux-64.zip -d /root/e1/ >/dev/null 2>&1 || { echo "解压失败"; exit 1; }

    # 检查是否解压成功
    if [ -f "/root/e1/xray" ]; then
        echo "解压成功，文件存在"
    else
        echo "解压失败或文件不存在"
        exit 1
    fi

    # 设置 xray 文件的可执行权限
    chmod +x /root/e1/xray

    # 创建 Xray 服务配置文件
    mkdir -p /etc/xray
    echo -n "" > /etc/xray/serve.toml

    # 创建 /root/ip 目录（如果不存在）
    mkdir -p /root/ip

    # 获取第一个IP地址
    first_ip=$(hostname -I | awk '{print $1}')

    # 创建信息文本文件，格式：用户名_密码_IP地址.txt
    filename="/root/ip/${socks_user}_${socks_pass}_${first_ip}.txt"
    > "$filename"

    # 声明一个数组用于存放所有随机生成的端口，供防火墙使用
    generated_ports=()

    # 循环为每个IP分配端口并配置Xray
    for ((i = 0; i < ${#ips[@]}; i++)); do
        # 生成 10000-60000 之间的随机端口
        current_port=$(shuf -i 10000-60000 -n 1)
        generated_ports+=($current_port)

        # 追加配置到 serve.toml 文件
        cat <<EOF >> /etc/xray/serve.toml
[[inbounds]]
listen = "${ips[i]}"
port = $current_port
protocol = "socks"
tag = "$((i+1))"

[inbounds.settings]
auth = "password"
udp = true
ip = "${ips[i]}"

[[inbounds.settings.accounts]]
user = "$socks_user"
pass = "$socks_pass"

[[routing.rules]]
type = "field"
inboundTag = "$((i+1))"
outboundTag = "$((i+1))"

[[outbounds]]
sendThrough = "${ips[i]}"
protocol = "freedom"
tag = "$((i+1))"
EOF

        # 追加信息到文本文件（格式：IP:端口:用户名:密码）
        echo "${ips[i]}:$current_port:$socks_user:$socks_pass" >> "$filename"
    done

    # 配置防火墙规则
    configure_firewall() {
        if command -v firewall-cmd >/dev/null 2>&1; then
            if systemctl is-active --quiet firewalld 2>/dev/null; then
                echo "firewalld 服务正在运行"
            else
                echo "尝试启动 firewalld 服务..."
                if systemctl start firewalld 2>/dev/null && systemctl enable firewalld 2>/dev/null; then
                    echo "firewalld 服务已启动"
                    sleep 2
                else
                    echo "警告: 无法启动 firewalld，将使用 iptables"
                    use_iptables=true
                fi
            fi
            
            if [ "$use_iptables" != "true" ]; then
                for p in "${generated_ports[@]}"; do
                    firewall-cmd --zone=public --add-port=$p/tcp --add-port=$p/udp --permanent 2>/dev/null
                done
                firewall-cmd --reload 2>/dev/null
                echo "防火墙规则已通过 firewalld 配置"
                return 0
            fi
        fi
        
        echo "使用 iptables 配置防火墙规则..."
        for p in "${generated_ports[@]}"; do
            iptables -I INPUT -p tcp --dport $p -j ACCEPT
            iptables -I INPUT -p udp --dport $p -j ACCEPT
        done
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi
        echo "防火墙规则已通过 iptables 配置"
    }

    configure_firewall

    # 配置Xray服务
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=The Xray Proxy Serve
After=network-online.target

[Service]
ExecStart=/root/e1/xray -c /etc/xray/serve.toml
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=always
RestartSec=15s

[Install]
WantedBy=multi-user.target
EOF

    # 启动Xray服务
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray

    # 删除安装包
    rm -f /root/Xray-linux-64.zip 2>/dev/null

    # 显示完成信息并打印纯净格式账号信息
    echo ""
    echo "====================================="
    echo "        🎉 代理安装与配置完成 🎉       "
    echo "====================================="
    
    while IFS=':' read -r ip port user pass; do
        if [ -n "$ip" ]; then
            echo "$ip:$port:$user:$pass"
        fi
    done < "$filename"

    echo "====================================="
    
    read -p "按回车键返回主菜单..."
    menu
}

# ----------------- 2. 卸载 SOCKS5 代理 -----------------
uninstall_socks5() {
    clear
    echo "====================================="
    echo "       正在卸载 SOCKS5 代理服务      "
    echo "====================================="
    
    # 停止并禁用 Xray 服务
    if systemctl is-active --quiet xray; then
        echo "正在停止 Xray 服务..."
        systemctl stop xray
    fi

    if systemctl is-enabled --quiet xray 2>/dev/null; then
        echo "正在禁用 Xray 开机自启..."
        systemctl disable xray >/dev/null 2>&1
    fi

    # 自动清理防火墙规则
    echo "正在清理防火墙开放端口..."
    CONF_FILE="/etc/xray/serve.toml"

    if [ -f "$CONF_FILE" ]; then
        open_ports=$(grep "port =" "$CONF_FILE" | awk '{print $3}')
        
        for port in $open_ports; do
            if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
                firewall-cmd --zone=public --remove-port=$port/tcp --permanent 2>/dev/null
                firewall-cmd --zone=public --remove-port=$port/udp --permanent 2>/dev/null
            fi
            
            if command -v iptables >/dev/null 2>&1; then
                iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null
                iptables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null
            fi
        done
        
        if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
            firewall-cmd --reload 2>/dev/null
        fi
        echo "✓ 防火墙规则已清理"
    else
        echo "未找到配置文件，跳过防火墙清理"
    fi

    # 删除相关文件
    echo "正在删除残留文件..."
    rm -rf /root/e1
    rm -rf /etc/xray
    rm -rf /root/ip
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload

    echo ""
    echo "====================================="
    echo "        🎉 SOCKS5 代理卸载完成 🎉      "
    echo "====================================="
    echo "说明：BBR加速属于内核级优化，已保留在系统内。"
    echo "所有代理进程、配置和端口规则已彻底清除。"
    echo "====================================="
    
    read -p "按回车键返回主菜单..."
    menu
}

# ----------------- 3. 查看节点信息 -----------------
view_info() {
    clear
    echo "====================================="
    echo "        🔍 SOCKS5 节点信息查询       "
    echo "====================================="
    
    local has_file=false
    if [ -d "/root/ip" ]; then
        files=(/root/ip/*.txt)
        if [ -e "${files[0]}" ]; then
            has_file=true
            for file in "${files[@]}"; do
                while IFS=':' read -r ip port user pass; do
                    if [ -n "$ip" ]; then
                        echo "$ip:$port:$user:$pass"
                    fi
                done < "$file"
            done
        fi
    fi

    if [ "$has_file" = false ]; then
        echo "未找到保存的节点信息文件，可能是尚未安装或已被卸载。"
    fi

    echo "====================================="
    if systemctl is-active --quiet xray >/dev/null 2>&1; then
        echo -e "▶️ 服务状态: \033[32m正在运行 (Active)\033[0m"
    else
        echo -e "▶️ 服务状态: \033[31m未运行或未安装 (Inactive)\033[0m"
    fi
    echo "====================================="

    read -p "按回车键返回主菜单..."
    menu
}

# ----------------- 交互主菜单 -----------------
menu() {
    clear
    echo "====================================="
    echo "      SOCKS5 代理一键管理脚本        "
    echo "====================================="
    echo "  1. 安装 SOCKS5 代理"
    echo "  2. 卸载 SOCKS5 代理"
    echo "  3. 查看 SOCKS5 节点信息"
    echo "  0. 退出脚本"
    echo "====================================="
    read -p "请输入对应的数字 [0-3]: " num
    case "$num" in
        1)
            install_socks5
            ;;
        2)
            uninstall_socks5
            ;;
        3)
            view_info
            ;;
        0)
            echo "已退出脚本。"
            exit 0
            ;;
        *)
            echo "⚠️ 输入有误，请重新输入！"
            sleep 1
            menu
            ;;
    esac
}

# 启动主菜单
menu