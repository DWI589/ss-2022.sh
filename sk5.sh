#!/bin/bash

#=================================================
#	SOCKS5 自动映射版 (Xray v1.8.10) - 修复UDP路由与防火墙持久化
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

    # 安装 unzip 和 curl 工具
    if command -v yum >/dev/null 2>&1; then
        yum install -y unzip curl || { echo "unzip/curl 安装失败"; exit 1; }
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y unzip curl || { echo "unzip/curl 安装失败"; exit 1; }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y unzip curl || { echo "unzip/curl 安装失败"; exit 1; }
    else
        echo "未找到支持的包管理器 (yum/apt-get/dnf)"
        exit 1
    fi

    # Xray 安装 v1.8.10
    XRAY_VERSION="v1.8.10"
    XRAY_FILE="Xray-linux-64.zip"
    XRAY_PATH="/root/${XRAY_FILE}"

    if [ ! -f "${XRAY_PATH}" ]; then
        echo "开始下载 Xray ${XRAY_VERSION}..."

        URL1="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_FILE}"
        URL2="https://ghproxy.com/${URL1}"

        wget -c -O "${XRAY_PATH}" "$URL1" \
        || wget -c -O "${XRAY_PATH}" "$URL2" \
        || { echo "所有下载源失败"; exit 1; }

    else
        echo "/root 目录下已有 ${XRAY_FILE}，跳过下载步骤"
    fi

    # 校验文件是否正常
    if [ ! -s "${XRAY_PATH}" ]; then
        echo "文件为空或损坏，删除重试"
        rm -f "${XRAY_PATH}"
        exit 1
    fi

    # 创建 Xray 目录（如果不存在）
    if [ ! -d "/root/e1" ]; then
        mkdir -p /root/e1 || { echo "创建目录 /root/e1 失败"; exit 1; }
    fi

    # 解压文件到 /root/e1 目录
    unzip -o "${XRAY_PATH}" -d /root/e1/ >/dev/null 2>&1 \
    || { echo "解压失败"; exit 1; }

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

    # 创建信息文本文件，格式：用户名_密码_nodes.txt
    filename="/root/ip/${socks_user}_${socks_pass}_nodes.txt"
    > "$filename"

    generated_ports=()
    node_count=0

    echo "-------------------------------------"
    echo "正在自动探测并映射内网与公网IP关系 (增强版)，请稍候..."
    
    # 【修复】自动检测并安装 iptables 以及 Debian 持久化工具 iptables-persistent
    if command -v yum >/dev/null 2>&1; then
        if ! command -v iptables >/dev/null 2>&1; then
            yum install -y iptables iptables-services >/dev/null 2>&1
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        # 强制安装 iptables 和 iptables-persistent (无交互模式防卡死)
        apt-get update >/dev/null 2>&1 
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent >/dev/null 2>&1
    fi

    # 获取本机所有有效 IPv4 地址
    ips=$(ip -4 addr | grep inet | awk '{print $2}' | cut -d/ -f1)

    # 循环遍历并自动配对 IP
    for current_in_ip in $ips; do
        # 跳过本地回环地址
        [[ $current_in_ip == "127.0.0.1" ]] && continue

        # 定义多个探测接口，防止单一接口失效或被墙
        pub_apis=(
            "api.ipify.org"
            "icanhazip.com"
            "ident.me"
            "ifconfig.me"
            "ip.sb"
        )

        show_pub_ip=""
        # 遍历 API 列表进行重试获取
        for api in "${pub_apis[@]}"; do
            # 增加 3 秒单次超时，清除结果中的换行符和空格
            tmp_ip=$(curl -s --interface "$current_in_ip" "$api" --max-time 3 | tr -d '[:space:]')
            
            # 使用正则表达式验证返回的是否为合法的 IPv4 地址
            if [[ "$tmp_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                show_pub_ip="$tmp_ip"
                break # 获取成功，跳出当前 IP 的 API 探测循环
            fi
        done

        # 如果成功获取到公网IP，则生成该节点的配置
        if [[ -n "$show_pub_ip" ]]; then
            node_count=$((node_count+1))
            # 生成 10666-38888 之间的随机端口
            current_port=$(shuf -i 10666-38888 -n 1)
            generated_ports+=($current_port)

            # 追加配置到 serve.toml 文件 
            # 核心修复点：listen 改为严格绑定当前的内网 IP，配合 sendThrough 彻底解决辅助网卡 UDP 串台问题
            cat <<EOF >> /etc/xray/serve.toml
[[inbounds]]
listen = "${current_in_ip}"
port = $current_port
protocol = "socks"
tag = "in_${node_count}"

[inbounds.settings]
auth = "password"
udp = true
ip = "${show_pub_ip}"

[[inbounds.settings.accounts]]
user = "$socks_user"
pass = "$socks_pass"

[[routing.rules]]
type = "field"
inboundTag = "in_${node_count}"
outboundTag = "out_${node_count}"

[[outbounds]]
sendThrough = "${current_in_ip}"
protocol = "freedom"
tag = "out_${node_count}"
EOF
            # 追加信息到文本文件（纯净格式：IP/端口/用户名/密码）
            echo "${show_pub_ip}/${current_port}/${socks_user}/${socks_pass}" >> "$filename"
        fi
    done

    # 如果没有任何IP映射成功，容错退出
    if [ $node_count -eq 0 ]; then
        echo "⚠️ 警告：无法自动获取任何公网IP，请检查服务器外网连接！"
        exit 1
    fi

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
        
        # 【修复】确保规则持久化目录存在
        mkdir -p /etc/iptables
        mkdir -p /etc/sysconfig
        
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi

        # 【修复】Debian/Ubuntu 专用持久化保存命令
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        fi

        # 【修复】CentOS 专用持久化开机自启
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q iptables.service; then
            systemctl enable iptables >/dev/null 2>&1
            service iptables save >/dev/null 2>&1
        fi

        echo "防火墙规则已通过 iptables 配置并持久化保存。"
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
LimitNOFILE=512000

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
    
    # 直接输出文件内容，保证完美的 IP/端口/用户名/密码 格式
    if [ -f "$filename" ]; then
        cat "$filename"
    fi

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

        # 卸载时一并清理持久化的规则文件
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save >/dev/null 2>&1
            fi
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
                # 直接输出文件内容，保留精确格式
                cat "$file"
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
