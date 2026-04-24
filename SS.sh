#!/bin/bash

set -e

# ---------- 自动检测网卡并设置 MTU ----------
echo "▶ 正在检测默认网卡..."
DEFAULT_IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)

if [ -z "$DEFAULT_IFACE" ]; then
    # 遍历所有非回环网卡
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        if ip -4 addr show $iface | grep -q "inet"; then
            DEFAULT_IFACE=$iface
            break
        fi
    done
fi

if [ -n "$DEFAULT_IFACE" ]; then
    echo "✅ 检测到默认网卡: $DEFAULT_IFACE"
    CURRENT_MTU=$(cat /sys/class/net/$DEFAULT_IFACE/mtu)
    echo "当前 MTU: $CURRENT_MTU"
    
    # 设置 MTU 为 1400
    ip link set dev $DEFAULT_IFACE mtu 1400
    echo "✅ 已设置 MTU 为 1400"
else
    echo "⚠️ 未能检测到活动网卡，跳过 MTU 设置"
fi

# ---------- 启用 BBR ----------
echo "▶ 启用 BBR 拥塞控制算法..."
cat >> /etc/sysctl.conf <<EOF
# Xray Game Optimization
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
EOF
sysctl -p

# ---------- 安装 Xray 核心（如果未安装）----------
if ! command -v xrayLL &>/dev/null; then
    echo "▶ 安装 Xray 核心..."
    apt update && apt install -y wget unzip curl
    wget -O Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
    unzip -o Xray-linux-64.zip
    mv xray /usr/local/bin/xrayLL
    chmod +x /usr/local/bin/xrayLL
fi

# ---------- 更新 geoip.dat 和 geosite.dat ----------
echo "▶ 更新 geoip.dat 和 geosite.dat..."
if command -v bash &>/dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata || {
        echo "⚠️ 官方更新失败，尝试直接下载..."
        GEO_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
        mkdir -p /usr/local/share/xray
        wget -q -O /usr/local/share/xray/geoip.dat ${GEO_URL}/geoip.dat
        wget -q -O /usr/local/share/xray/geosite.dat ${GEO_URL}/geosite.dat
    }
fi

# 复制到 Xray 配置目录
mkdir -p /etc/xrayLL
cp /usr/local/share/xray/geoip.dat /etc/xrayLL/ 2>/dev/null || true
cp /usr/local/share/xray/geosite.dat /etc/xrayLL/ 2>/dev/null || true
echo "✅ geo 文件更新完成"

# ---------- 创建 systemd 服务 ----------
cat > /etc/systemd/system/xrayLL.service <<EOF
[Unit]
Description=xrayLL Service (Game Optimized)
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayLL -c /etc/xrayLL/config.json
Restart=on-failure
User=nobody
RestartSec=3
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

# ---------- 生成随机凭证 ----------
UUID=$(cat /proc/sys/kernel/random/uuid)
SS_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 24 | head -n1)

# ---------- 写入完整 JSON 配置（同上，省略节省篇幅）----------
cat > /etc/xrayLL/config.json <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "udp": true,
        "clients": [{"id": "${UUID}"}]
      },
      "streamSettings": {
        "network": "tcp",
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveIdle": 300
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "port": 20000,
      "protocol": "vmess",
      "settings": {
        "udp": true,
        "clients": [{"id": "${UUID}"}]
      },
      "streamSettings": {
        "network": "tcp",
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveIdle": 300
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
	  "port": 30000,
	  "protocol": "shadowsocks",
	  "settings": {
		"method": "aes-256-gcm",
		"password": "${SS_PASS}",
		"udp": true,
		"network": "tcp,udp"
	  },
	  "streamSettings": {
		"network": "tcp",
		"sockopt": {
		  "tcpFastOpen": true,
		  "tcpKeepAliveIdle": 300
		}
	  },
	  "sniffing": {
		"enabled": true,
		"destOverride": ["http", "tls", "quic"]
	  }
	},
    {
      "port": 40000,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "udp": true,
        "accounts": [{"user": "user1", "pass": "${SS_PASS}"}]
      },
      "streamSettings": {
        "network": "tcp",
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveIdle": 300
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 5,
        "connIdle": 300
      }
    }
  }
}
EOF

# 替换 UUID 和密码
sed -i "s/\${UUID}/$UUID/g" /etc/xrayLL/config.json
sed -i "s/\${SS_PASS}/$SS_PASS/g" /etc/xrayLL/config.json

# ---------- 启动服务 ----------
systemctl daemon-reload
systemctl enable xrayLL.service
systemctl restart xrayLL.service
sleep 2

# ---------- 获取 IP 并输出信息 ----------
IPV4=$(curl -s4m6 ip.sb -k)
VMESS_LINK="vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"${IPV4}-vmess\",\"add\":\"${IPV4}\",\"port\":\"20000\",\"id\":\"${UUID}\",\"net\":\"tcp\"}" | base64 -w 0)"
VLESS_LINK="vless://${UUID}@${IPV4}:10000?encryption=none&security=none&type=tcp#${IPV4}-vless"
SS_LINK="ss://$(echo -n "aes-256-gcm:${SS_PASS}@${IPV4}:30000" | base64 -w 0)#${IPV4}-ss"

cat <<EOF

==============================================================
✅ 游戏优化代理部署完成！
==============================================================
服务器 IP：${IPV4}
默认网卡：${DEFAULT_IFACE:-未检测到}
MTU 设置：${DEFAULT_IFACE:+已设为1400}${DEFAULT_IFACE:-跳过}
geo 文件：已更新至最新

------------------- 各协议连接信息 -------------------

1️⃣ VLESS (TCP)
端口： 10000
UUID： ${UUID}
链接： ${VLESS_LINK}

2️⃣ VMess (TCP)
端口： 20000
UUID： ${UUID}
链接： ${VMESS_LINK}

3️⃣ Shadowsocks (TCP)
端口： 30000
密码： ${SS_PASS}
加密： aes-256-gcm
链接： ${SS_LINK}

4️⃣ SOCKS5 (TCP/UDP)
端口： 40000
用户名： user1
密码： ${SS_PASS}

------------------------------------------------------
🌐 所有入站均已开启 UDP 转发
🔥 防火墙请放行端口（TCP/UDP）：10000,20000,30000,40000
==============================================================
