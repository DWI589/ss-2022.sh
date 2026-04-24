#!/bin/bash

#=================================================
#  Linux 多 IP 底层网卡限速工具 (独立版)
#  采用 TC (Traffic Control) + HTB 算法
#=================================================

# 确保以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo "❌ 错误: 请使用 root 用户运行此脚本！"
    exit 1
fi

# 安装必要依赖
install_deps() {
    if ! command -v tc >/dev/null 2>&1; then
        echo "正在安装 iproute2 (TC 限速工具)..."
        if command -v yum >/dev/null 2>&1; then
            yum install -y iproute >/dev/null 2>&1
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update >/dev/null 2>&1 && apt-get install -y iproute2 >/dev/null 2>&1
        fi
    fi
}

# ----------------- 1. 开启限速 -----------------
start_limit() {
    clear
    echo "====================================="
    echo "       🚀 开启多 IP 智能带宽限速     "
    echo "====================================="
    install_deps

    echo "请输入服务器的【总带宽】 (单位: Mbps, 例如: 100):"
    read total_speed
    
    # 验证输入是否为正整数
    if ! [[ "$total_speed" =~ ^[0-9]+$ ]] || [ "$total_speed" -le 0 ]; then
        echo "❌ 错误: 带宽必须是大于0的整数！"
        sleep 2
        menu
        return
    fi

    echo "-------------------------------------"
    echo "正在扫描本机配置的有效 IP..."
    
    # 获取本机所有有效 IPv4 (排除 127.0.0.1)
    ips=($(ip -4 addr | grep inet | awk '{print $2}' | cut -d/ -f1 | grep -v "127.0.0.1"))
    node_count=${#ips[@]}

    if [ $node_count -eq 0 ]; then
        echo "⚠️ 错误：未检测到任何有效的网卡 IP！"
        sleep 2
        menu
        return
    fi

    # 计算平分后的单 IP 带宽
    per_ip_speed=$(( total_speed / node_count ))
    if [ $per_ip_speed -lt 1 ]; then
        per_ip_speed=1
    fi

    echo "✅ 扫描完毕！共发现 $node_count 个内网/公网 IP。"
    echo "👉 总带宽 ${total_speed} Mbps，自动分配每个 IP 限速: ${per_ip_speed} Mbps"
    echo "正在将规则写入底层网卡..."

    # 获取主出网网卡名称 (如 eth0, ens3, enp3s0)
    main_iface=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    
    # 先清理旧的规则
    tc qdisc del dev $main_iface root 2>/dev/null
    
    # 创建根节点，默认不匹配的流量走 10
    tc qdisc add dev $main_iface root handle 1: htb default 10

    # 为每个 IP 生成限速规则
    for ((i=0; i<node_count; i++)); do
        current_ip="${ips[i]}"
        class_id=$((100 + i))
        
        # 1. 划分带宽桶 (限制最大速度)
        tc class add dev $main_iface parent 1: classid 1:$class_id htb rate ${per_ip_speed}mbit ceil ${per_ip_speed}mbit
        
        # 2. 绑定过滤器 (只要是这个 IP 发出的数据，就被扔进上面的桶里限速)
        tc filter add dev $main_iface protocol ip parent 1:0 prio 1 u32 match ip src $current_ip flowid 1:$class_id
    done

    echo "====================================="
    echo " 🎉 限速开启成功！当前每个 IP 限速: ${per_ip_speed} Mbps"
    echo " （生效网卡: $main_iface）"
    echo "====================================="
    read -p "按回车键返回主菜单..."
    menu
}

# ----------------- 2. 关闭限速 -----------------
stop_limit() {
    clear
    echo "====================================="
    echo "       🛑 正在解除网卡带宽限速       "
    echo "====================================="
    
    main_iface=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    
    if [ -z "$main_iface" ]; then
        echo "⚠️ 无法获取主网卡信息。"
    else
        # 直接删除 root 节点即可清除所有规则
        tc qdisc del dev $main_iface root 2>/dev/null
        echo "✅ 网卡 [$main_iface] 的所有限速规则已彻底清除！"
        echo "网络已恢复无限制状态。"
    fi
    
    echo "====================================="
    read -p "按回车键返回主菜单..."
    menu
}

# ----------------- 3. 查看状态 -----------------
status_limit() {
    clear
    echo "====================================="
    echo "        📊 当前网卡限速带宽状态      "
    echo "====================================="
    
    main_iface=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    
    # 检查是否包含 htb 规则
    if tc qdisc show dev $main_iface 2>/dev/null | grep -q "htb"; then
        echo "▶️ 限速状态: 🟢 已开启"
        echo "▶️ 作用网卡: $main_iface"
        echo "-------------------------------------"
        echo "【当前各个IP通道分配的带宽速率】:"
        
        # 精准使用正则提取并显示每一个 class 的真实速率
        tc class show dev $main_iface | grep -E "htb 1:1[0-9]{2}" | while read -r line; do
            # 获取通道ID
            class_id=$(echo "$line" | awk '{print $3}')
            # 获取精准速率(rate)
            rate_limit=$(echo "$line" | grep -oE 'rate [^ ]+' | awk '{print $2}')
            
            echo " 🔹 通道 $class_id   --->   最大速率: $rate_limit"
        done
        
        echo "-------------------------------------"
        echo "说明: 如果服务器有5个IP，上方就会独立显示5个通道。"
        echo "速率带有 Mbit (兆比特) 或 Kbit (千比特) 单位。"
    else
        echo "▶️ 限速状态: 🔴 未开启 (无限制)"
    fi
    
    echo "====================================="
    read -p "按回车键返回主菜单..."
    menu
}

# ----------------- 主菜单 -----------------
menu() {
    clear
    echo "====================================="
    echo "    VPS 多 IP 智能限速工具"
    echo "====================================="
    echo "  1. 开启限速 (输入总带宽，自动平分)"
    echo "  2. 关闭限速 (恢复原始网卡速度)"
    echo "  3. 查看当前限速状态与带宽速率"
    echo "  0. 退出脚本"
    echo "====================================="
    read -p "请输入对应的数字 [0-3]: " num
    case "$num" in
        1) start_limit ;;
        2) stop_limit ;;
        3) status_limit ;;
        0) echo "已退出。"; exit 0 ;;
        *) echo "⚠️ 输入有误，请重新输入"; sleep 1; menu ;;
    esac
}

# 启动菜单
menu