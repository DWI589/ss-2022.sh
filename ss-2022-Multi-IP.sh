#!/usr/bin/env bash
set -e

# =========================================
# 作者: jinqians
# 日期: 2025年3月
# 网站：jinqians.com
# 描述: Shadowsocks Rust 管理脚本 (已集成多IP站群部署)
# =========================================

# 版本信息
SCRIPT_VERSION="1.7-MultiIP"
SS_VERSION=""

# 系统路径
SCRIPT_PATH=$(cd "$(dirname "$0")"; pwd)
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}")
SCRIPT_NAME=$(basename "$0")

# 安装路径
INSTALL_DIR="/etc/ss-rust"
BINARY_PATH="/usr/local/bin/ss-rust"
CONFIG_PATH="/etc/ss-rust/config.json"
VERSION_FILE="/etc/ss-rust/ver.txt"
SYSCTL_CONF="/etc/sysctl.d/local.conf"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PLAIN='\033[0m'
readonly BOLD='\033[1m'

# 状态提示
readonly INFO="${GREEN}[信息]${PLAIN}"
readonly ERROR="${RED}[错误]${PLAIN}"
readonly WARNING="${YELLOW}[警告]${PLAIN}"
readonly SUCCESS="${GREEN}[成功]${PLAIN}"

# 系统信息
OS_TYPE=""
OS_ARCH=""
OS_VERSION=""

# 配置信息
SS_PORT=""
SS_PASSWORD=""
SS_METHOD=""
SS_TFO=""
SS_DNS=""

# 错误处理函数
error_exit() {
    echo -e "${ERROR} $1" >&2
    exit 1
}

# 检查 root 权限
check_root() {
    if [[ $EUID != 0 ]]; then
        error_exit "当前非ROOT账号(或没有ROOT权限)，无法继续操作，请使用 sudo su 命令获取临时ROOT权限"
    fi
}

# 检测操作系统
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS_TYPE="centos"
    elif grep -q -E -i "debian" /etc/issue; then
        OS_TYPE="debian"
    elif grep -q -E -i "ubuntu" /etc/issue; then
        OS_TYPE="ubuntu"
    elif grep -q -E -i "centos|red hat|redhat" /etc/issue; then
        OS_TYPE="centos"
    elif grep -q -E -i "debian" /proc/version; then
        OS_TYPE="debian"
    elif grep -q -E -i "ubuntu" /proc/version; then
        OS_TYPE="ubuntu"
    elif grep -q -E -i "centos|red hat|redhat" /proc/version; then
        OS_TYPE="centos"
    else
        error_exit "不支持的操作系统"
    fi
}

# 检测系统架构
detect_arch() {
    local arch=$(uname -m)
    local os=$(uname -s)
    
    case "${os}" in
        "Darwin")
            case "${arch}" in
                "arm64")
                    OS_ARCH="aarch64-apple-darwin"
                    ;;
                "x86_64")
                    OS_ARCH="x86_64-apple-darwin"
                    ;;
            esac
            ;;
        "Linux")
            case "${arch}" in
                "x86_64")
                    OS_ARCH="x86_64-unknown-linux-musl"
                    ;;
                "aarch64")
                    OS_ARCH="aarch64-unknown-linux-gnu"
                    ;;
                "armv7l"|"armv7")
                    # 检查是否支持硬浮点
                    if grep -q "gnueabihf" /proc/cpuinfo; then
                        OS_ARCH="armv7-unknown-linux-gnueabihf"
                    else
                        OS_ARCH="arm-unknown-linux-gnueabi"
                    fi
                    ;;
                "armv6l")
                    OS_ARCH="arm-unknown-linux-gnueabi"
                    ;;
                "i686"|"i386")
                    OS_ARCH="i686-unknown-linux-musl"
                    ;;
                *)
                    error_exit "不支持的CPU架构: ${arch}"
                    ;;
            esac
            ;;
        *)
            error_exit "不支持的操作系统: ${os}"
            ;;
    esac
    
    echo -e "${INFO} 检测到系统架构为 [ ${OS_ARCH} ]"
}

# 检查安装状态
check_installation() {
    if [[ ! -e ${BINARY_PATH} ]]; then
        error_exit "Shadowsocks Rust 未安装，请先安装！"
    fi
}

# 检查服务状态
check_service_status() {
    local status=$(systemctl is-active ss-rust)
    echo "${status}"
}

# 获取最新版本
get_latest_version() {
    SS_VERSION=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | \
                 jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    
    if [[ -z ${SS_VERSION} ]]; then
        error_exit "获取 Shadowsocks Rust 最新版本失败！"
    fi
    
    # 移除版本号中的 'v' 前缀
    SS_VERSION=${SS_VERSION#v}
    
    echo -e "${INFO} 检测到 Shadowsocks Rust 最新版本为 [ ${SS_VERSION} ]"
}

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m" && Yellow_font_prefix="\033[0;33m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[注意]${Font_color_suffix}"

check_installed_status() {
    if [[ ! -e ${BINARY_PATH} ]]; then
        echo -e "${Error} Shadowsocks Rust 没有安装，请检查！"
        return 1
    fi
    return 0
}

check_status() {
    if systemctl is-active ss-rust >/dev/null 2>&1; then
        status="running"
    else
        status="stopped"
    fi
}

check_new_ver() {
    new_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases| jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    [[ -z ${new_ver} ]] && echo -e "${Error} Shadowsocks Rust 最新版本获取失败！" && exit 1
    echo -e "${Info} 检测到 Shadowsocks Rust 最新版本为 [ ${new_ver} ]"
}

# 检查版本并比较
check_ver_comparison() {
    if [[ ! -f "${VERSION_FILE}" ]]; then
        echo -e "${Info} 未找到版本文件，可能是首次安装"
        return 0
    fi
    
    local now_ver=$(cat ${VERSION_FILE})
    if [[ "${now_ver}" != "${new_ver}" ]]; then
        echo -e "${Info} 发现 Shadowsocks Rust 新版本 [ ${new_ver} ]"
        echo -e "${Info} 当前版本 [ ${now_ver} ]"
        return 0
    else
        echo -e "${Info} 当前已是最新版本 [ ${new_ver} ]"
        return 1
    fi
}

# 获取当前安装版本
get_current_version() {
    if [[ -f "${VERSION_FILE}" ]]; then
        current_ver=$(cat "${VERSION_FILE}")
        echo "${current_ver}"
    else
        echo "0.0.0"
    fi
}

# 版本号比较函数
version_compare() {
    local current=$1
    local latest=$2
    
    # 移除版本号中的 'v' 前缀
    current=${current#v}
    latest=${latest#v}
    
    if [[ "${current}" == "${latest}" ]]; then
        return 1  # 版本相同
    fi
    
    # 将版本号分割为数组
    IFS='.' read -r -a current_parts <<< "${current}"
    IFS='.' read -r -a latest_parts <<< "${latest}"
    
    # 比较每个部分
    for i in "${!current_parts[@]}"; do
        if [[ "${current_parts[$i]}" -lt "${latest_parts[$i]}" ]]; then
            return 0  # 当前版本低于最新版本
        elif [[ "${current_parts[$i]}" -gt "${latest_parts[$i]}" ]]; then
            return 1  # 当前版本高于最新版本
        fi
    done
    
    return 1
}

# 下载 Shadowsocks Rust
download_ss() {
    local version=$1
    local arch=$2
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}"
    local filename=""

    case "${arch}" in
        "aarch64-apple-darwin"|"x86_64-apple-darwin") filename="shadowsocks-v${version}.${arch}.tar.xz" ;;
        "x86_64-unknown-linux-gnu"|"x86_64-unknown-linux-musl") filename="shadowsocks-v${version}.${arch}.tar.xz" ;;
        "aarch64-unknown-linux-gnu"|"aarch64-unknown-linux-musl") filename="shadowsocks-v${version}.${arch}.tar.xz" ;;
        "arm-unknown-linux-gnueabi"|"arm-unknown-linux-gnueabihf"|"arm-unknown-linux-musleabi"|"arm-unknown-linux-musleabihf") filename="shadowsocks-v${version}.${arch}.tar.xz" ;;
        "armv7-unknown-linux-gnueabihf"|"armv7-unknown-linux-musleabihf") filename="shadowsocks-v${version}.${arch}.tar.xz" ;;
        "i686-unknown-linux-musl") filename="shadowsocks-v${version}.${arch}.tar.xz" ;;
        "x86_64-pc-windows-gnu") filename="shadowsocks-v${version}.${arch}.zip" ;;
        "x86_64-pc-windows-msvc") filename="shadowsocks-v${version}.${arch}.zip" ;;
        *) error_exit "不支持的系统架构: ${arch}" ;;
    esac
    
    echo -e "${INFO} 开始下载 Shadowsocks Rust ${version}..."
    echo -e "${INFO} 下载地址：${url}/${filename}"
    wget --no-check-certificate -N "${url}/${filename}"
    
    if [[ ! -e "${filename}" ]]; then
        error_exit "Shadowsocks Rust 下载失败！"
    fi
    
    if [[ "${filename}" == *.tar.xz ]]; then
        if ! tar -xf "${filename}"; then error_exit "Shadowsocks Rust 解压失败！"; fi
    elif [[ "${filename}" == *.zip ]]; then
        if ! unzip -o "${filename}"; then error_exit "Shadowsocks Rust 解压失败！"; fi
    fi
    
    if [[ ! -e "ssserver" ]]; then error_exit "Shadowsocks Rust 解压后未找到主程序！"; fi
    
    rm -f "${filename}"
    chmod +x ssserver
    mv -f ssserver "${BINARY_PATH}"
    rm -f sslocal ssmanager ssservice ssurl
    
    echo "${version}" > "${VERSION_FILE}"
    echo -e "${SUCCESS} Shadowsocks Rust ${version} 下载安装完成！"
}

# 下载主函数
download() {
    if [[ ! -e "${INSTALL_DIR}" ]]; then
        mkdir -p "${INSTALL_DIR}"
    fi
    download_ss "${SS_VERSION}" "${OS_ARCH}"
}

# 安装系统服务
install_service() {
    echo -e "${INFO} 开始安装系统服务..."
    cat > /etc/systemd/system/ss-rust.service << EOF
[Unit]
Description=Shadowsocks Rust Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${BINARY_PATH} -c ${CONFIG_PATH}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${INFO} 重新加载 systemd 配置..."
    systemctl daemon-reload
    
    echo -e "${INFO} 启用 ss-rust 服务..."
    systemctl enable ss-rust
    
    echo -e "${SUCCESS} Shadowsocks Rust 服务配置完成！"
}

# 安装依赖
install_dependencies() {
    echo -e "${INFO} 开始安装系统依赖..."
    
    if [[ ${OS_TYPE} == "centos" ]]; then
        yum update -y
        # 新增: 安装 iptables-services 并设置开机自启
        yum install -y jq gzip wget curl unzip xz openssl qrencode tar iptables-services
        systemctl enable iptables >/dev/null 2>&1
    else
        apt-get update
        # 新增: 加上 DEBIAN_FRONTEND=noninteractive 防止安装弹窗卡住脚本，并安装持久化插件
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq gzip wget curl unzip xz-utils openssl qrencode tar iptables-persistent netfilter-persistent
        systemctl enable netfilter-persistent >/dev/null 2>&1
    fi
    
    # 设置时区
    echo -e "${CYAN}正在设置时区...${RESET}"
    if [ -f "/usr/share/zoneinfo/Asia/Shanghai" ]; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
    else
        echo -e "${RED}时区文件不存在，跳过设置${RESET}"
    fi
    echo -e "${SUCCESS} 系统依赖安装完成！"
}

# 写入配置文件
write_config() {
    cat > ${CONFIG_PATH} << EOF
{
    "server": "::",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "fast_open": ${SS_TFO},
    "mode": "tcp_and_udp",
    "user": "nobody",
    "timeout": 300${SS_DNS:+",\n    \"nameserver\":\"${SS_DNS}\""}
}
EOF
    echo -e "${SUCCESS} 配置文件写入完成！"
}

# 读取配置文件
read_config() {
    if [[ ! -e ${CONFIG_PATH} ]]; then
        error_exit "Shadowsocks Rust 配置文件不存在！"
    fi
    SS_PORT=$(jq -r '.server_port' ${CONFIG_PATH})
    SS_PASSWORD=$(jq -r '.password' ${CONFIG_PATH})
    SS_METHOD=$(jq -r '.method' ${CONFIG_PATH})
    SS_TFO=$(jq -r '.fast_open' ${CONFIG_PATH})
    SS_DNS=$(jq -r '.nameserver // empty' ${CONFIG_PATH})
}

# 检查防火墙并开放端口
check_firewall() {
    local port=$1
    echo -e "${INFO} 检查防火墙配置..."
    
    # 1. 检查并配置 firewalld (CentOS/Alma/Rocky 默认)
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        echo -e "${INFO} 检测到 firewalld 防火墙..."
        firewall-cmd --permanent --add-port=${port}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=${port}/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "${SUCCESS} firewalld 端口开放并持久化完成！"
        return 0
    fi

    # 2. 检查并配置 UFW (Ubuntu/Debian 默认)
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -qw active; then
            echo -e "${INFO} 检测到 UFW 防火墙..."
            ufw allow ${port}/tcp >/dev/null 2>&1
            ufw allow ${port}/udp >/dev/null 2>&1
            echo -e "${SUCCESS} UFW 端口开放完成！(UFW自动持久化)"
            return 0
        fi
    fi
    
    # 3. 检查并配置 iptables (备用方案)
    if command -v iptables >/dev/null 2>&1; then
        echo -e "${INFO} 检测到 iptables 防火墙..."
        iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
        iptables -I INPUT -p udp --dport ${port} -j ACCEPT
        
        # 尝试使用各种方式持久化 iptables 规则
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        elif command -v service >/dev/null 2>&1 && systemctl is-active iptables >/dev/null 2>&1; then
            service iptables save >/dev/null 2>&1
        else
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        fi
        echo -e "${SUCCESS} iptables 端口开放并尝试保存完成！"
    fi
}

# 生成随机端口
generate_random_port() {
    local min_port=10000
    local max_port=65535
    echo $(shuf -i ${min_port}-${max_port} -n 1)
}

# 设置端口
set_port() {
    SS_PORT=$(generate_random_port)
    echo -e "${INFO} 已生成随机端口：${SS_PORT}"
    echo -e "${Tip} 是否使用该随机端口？\n 1. 是\n 2. 否，我要自定义端口"
    read -e -p "(默认: 1. 使用随机端口)：" port_choice
    [[ -z "${port_choice}" ]] && port_choice="1"
    
    if [[ ${port_choice} == "2" ]]; then
        while true; do
            read -e -p "请输入 Shadowsocks Rust 端口 [1-65535] (默认:2525)：" SS_PORT
            [[ -z "${SS_PORT}" ]] && SS_PORT="2525"
            if [[ ${SS_PORT} =~ ^[0-9]+$ ]] && (( SS_PORT >= 1 && SS_PORT <= 65535 )); then
                break
            else
                echo -e "${Error} 输入错误，端口范围必须在 1-65535 之间"
            fi
        done
    fi
    check_firewall "${SS_PORT}"
}

# 设置密码
set_password() {
    read -e -p "请输入 Shadowsocks Rust 密码 (默认：随机生成)：" SS_PASSWORD
    if [[ -z "${SS_PASSWORD}" ]]; then
        case "${SS_METHOD}" in
            "2022-blake3-aes-128-gcm") SS_PASSWORD=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64) ;;
            "2022-blake3-aes-256-gcm"|"2022-blake3-chacha20-poly1305"|"2022-blake3-chacha8-poly1305")
                raw_key=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)
                while [[ ${#raw_key} -ne 44 ]]; do raw_key=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64); done
                SS_PASSWORD="${raw_key}"
                ;;
            *) SS_PASSWORD=$(head -c 100 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 8) ;;
        esac
    fi
}

# 设置加密方式
set_method() {
    echo -e "请选择 Shadowsocks Rust 加密方式\n 1. aes-128-gcm\n 2. aes-256-gcm (默认)\n 3. chacha20-ietf-poly1305\n ..."
    read -e -p "(默认: 2)：" method_choice
    [[ -z "${method_choice}" ]] && method_choice="2"
    case ${method_choice} in
        1) SS_METHOD="aes-128-gcm" ;;
        2) SS_METHOD="aes-256-gcm" ;;
        3) SS_METHOD="chacha20-ietf-poly1305" ;;
        13) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        14) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        15) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        *) SS_METHOD="aes-256-gcm" ;;
    esac
}

# 设置 TFO
set_tfo() {
    read -e -p "是否启用 TFO ？\n 1. 启用\n 2. 禁用 (默认)：" tfo_choice
    [[ -z "${tfo_choice}" ]] && tfo_choice="2"
    if [[ ${tfo_choice} == "2" ]]; then SS_TFO="true"; else SS_TFO="false"; fi
}

# 设置 DNS
set_dns() {
    read -e -p "DNS 配置：\n 1. 系统默认 (默认)\n 2. 自定义：" dns_choice
    [[ -z "${dns_choice}" ]] && dns_choice="1"
    if [[ ${dns_choice} == "2" ]]; then
        read -e -p "输入自定义 DNS (如:8.8.8.8)：" SS_DNS
        [[ -z "${SS_DNS}" ]] && SS_DNS="8.8.8.8"
    else
        SS_DNS=""
    fi
}

# 修改配置
modify_config() {
    check_installation
    echo -e "你要做什么？\n 1. 修改 端口\n 2. 修改 密码\n 3. 修改 加密\n 4. 修改 TFO\n 5. 修改 DNS\n 6. 修改 全部"
    read -e -p "(默认：取消)：" modify
    [[ -z "${modify}" ]] && echo "已取消..." && Start_Menu
    case "${modify}" in
        1) read_config; set_port; write_config; Restart ;;
        2) read_config; set_password; write_config; Restart ;;
        3) read_config; set_method; write_config; Restart ;;
        4) read_config; set_tfo; write_config; Restart ;;
        5) read_config; set_dns; write_config; Restart ;;
        6) read_config; set_port; set_password; set_method; set_tfo; set_dns; write_config; Restart ;;
        *) modify_config ;;
    esac
}

# 安装
Install() {
    [[ -e ${BINARY_PATH} ]] && echo -e "${Error} 检测到 Shadowsocks Rust 已安装！" && exit 1
    
    detect_os
    set_port
    set_method
    set_password
    set_tfo
    set_dns
    install_dependencies
    detect_arch
    get_latest_version
    download
    write_config
    install_service

	echo -e "${Info} 创建命令快捷方式..."
    cp -f "$0" "/usr/local/bin/ss-2022.sh" || true
    chmod +x "/usr/local/bin/ss-2022.sh" || true
    if [ -f "/usr/local/bin/ssrust" ]; then
        rm -f "/usr/local/bin/ssrust" || true
    fi
    ln -s "/usr/local/bin/ss-2022.sh" "/usr/local/bin/ssrust" || true
    
    echo -e "${Info} 所有步骤安装完毕，开始启动服务..."
    start_service
    
    if [[ "$?" == "0" ]]; then
        echo -e "${SUCCESS} Shadowsocks Rust 安装并启动成功！"
        View
        Before_Start_Menu
    else
        echo -e "${Error} Shadowsocks Rust 启动失败，请检查日志！"
        Before_Start_Menu
    fi
}

# 启动服务
start_service() {
    check_installed_status || return 1
    check_status
    if [[ "$status" == "running" ]]; then return 1; fi
    systemctl start ss-rust
    sleep 2
    if ! systemctl is-active ss-rust >/dev/null 2>&1; then
        echo -e "${ERROR} Shadowsocks Rust 启动失败！"
        return 1
    fi
    echo -e "${SUCCESS} Shadowsocks Rust 启动成功！"
}

# 停止
Stop() {
    check_installed_status || return 1
    systemctl stop ss-rust
    echo -e "${Info} Shadowsocks Rust 已停止！"
}

# 重启
Restart() {
    check_installed_status || return 1
    systemctl restart ss-rust
    echo -e "${Info} Shadowsocks Rust 重启完毕！"
}

# 更新
Update() {
    check_installed_status
    current_ver=$(get_current_version)
    check_new_ver
    if version_compare "${current_ver}" "${new_ver}"; then
        echo -e "${Info} 发现新版本 [ ${new_ver} ]，开始更新..."
        detect_arch
        download_ss "${new_ver#v}" "${OS_ARCH}"
        systemctl restart ss-rust
    fi
    sleep 3s
    Start_Menu
}

# 卸载
Uninstall() {
    check_installed_status || return 1
    read -e -p "确定要卸载 Shadowsocks Rust ? (y/N)：" unyn
    if [[ ${unyn} == [Yy] ]]; then
        systemctl stop ss-rust >/dev/null 2>&1
        systemctl disable ss-rust >/dev/null 2>&1
        rm -rf "${INSTALL_DIR}" "${BINARY_PATH}" "/usr/local/bin/ssrust" "/usr/local/bin/ss-2022.sh"
        # 同时清理多IP节点残留服务和配置
        systemctl stop ss-rust@* >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/ss-rust@.service
        systemctl daemon-reload
        echo "卸载完成！"
    fi
}

# 提取IP
getipv4() { set +e; ipv4=$(curl -m 2 -s4 https://api.ipify.org); [[ -z "${ipv4}" ]] && ipv4="IPv4_Error"; set -e; }
getipv6() { set +e; ipv6=$(curl -m 2 -s6 https://api64.ipify.org); [[ -z "${ipv6}" ]] && ipv6="IPv6_Error"; set -e; }

# 查看配置信息
View() {
    check_installed_status
    getipv4
    getipv6
    
    if [[ -f "${CONFIG_PATH}" ]]; then
        local config_port=$(jq -r '.server_port' "${CONFIG_PATH}")
        local config_password=$(jq -r '.password' "${CONFIG_PATH}")
        local config_method=$(jq -r '.method' "${CONFIG_PATH}")
        echo -e " 主IP配置查看（多IP节点请查看 /root/nodes_info.txt）"
        echo -e " 端口：${config_port} | 密码：${config_password} | 加密：${config_method}"
    else
        echo -e "${Error} 单实例配置文件不存在（可能已切换为多IP模式）！"
    fi
}

# 查看运行状态
Status() {
    systemctl status ss-rust || true
    echo -e "${Tip} 如果是多IP模式，请使用 systemctl status ss-rust@IP地址 查看特定IP状态"
    Start_Menu
}

# 更新脚本
Update_Shell() {
    echo -e "${Info} 更新脚本功能已禁用，以免覆盖集成的多IP部署功能。"
    sleep 2s
}

# 安装 ShadowTLS
install_shadowtls() {
    echo -e "${Info} 暂不支持 ShadowTLS"
    Before_Start_Menu
}

# 批量部署站群多 IP 节点
Deploy_Multi_IP() {
    check_root
    if [[ ! -e ${BINARY_PATH} ]]; then
        echo -e "${Error} 未检测到 ss-rust 主程序，请先在主菜单选 1 随便进行一次单节点安装！"
        Before_Start_Menu
        return 1
    fi

    echo -e "${Info} 开始批量部署多 IP 节点..."
    echo -e "${Tip} 此操作将停用原有单实例，并为本机抓取到的所有 IPv4 地址生成独立配置进程！"
    read -e -p "是否继续？[Y/n]: " yn
    [[ -z "${yn}" ]] && yn="y"
    if [[ ${yn} != [Yy] ]]; then
        echo "已取消。"
        Before_Start_Menu
        return 0
    fi

    # 1. 停止原单实例
    systemctl stop ss-rust >/dev/null 2>&1 || true
    systemctl disable ss-rust >/dev/null 2>&1 || true

    # 2. 准备目录与模板服务 (修复 BUG 1：去除 network-online.target 依赖)
    mkdir -p /etc/ss-rust/configs
    cat > /etc/systemd/system/ss-rust@.service << EOF
[Unit]
Description=Shadowsocks Rust Service for %i
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ss-rust -c /etc/ss-rust/configs/%i.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload

    # 3. 提取所有本地 IP
    set +e
    IPS=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.')
    set -e
    if [[ -z "$IPS" ]]; then
        echo -e "${Error} 未检测到可用的本地 IPv4 地址！"
        Before_Start_Menu
        return 1
    fi

    # 4. 配置节点参数
    read -e -p "请输入分配的起始端口 (默认: 10000): " START_PORT
    [[ -z "${START_PORT}" ]] && START_PORT=10000

    echo -e "请选择全部节点的统一加密方式："
    echo -e " 1. aes-128-gcm\n 2. aes-256-gcm (默认)\n 3. chacha20-ietf-poly1305"
    read -e -p "选择: " m_choice
    case $m_choice in
        1) MULTI_METHOD="aes-128-gcm" ;;
        3) MULTI_METHOD="chacha20-ietf-poly1305" ;;
        *) MULTI_METHOD="aes-256-gcm" ;;
    esac

    # (导出为 txt 格式与后缀)
	OUTPUT_FILE="/root/nodes_info.txt"
    echo "IP/端口/加密/密码" > "$OUTPUT_FILE"

    PORT=$START_PORT
    echo -e "${Info} 正在生成配置并启动服务，请稍候..."
    
    # 5. 循环部署
    for IP in $IPS; do
        PASSWORD=$(head -c 100 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 8)
        
        cat > /etc/ss-rust/configs/${IP}.json << EOF
{
    "server": "${IP}",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "method": "${MULTI_METHOD}",
    "mode": "tcp_and_udp",
    "fast_open": false,
    "user": "nobody",
    "timeout": 300
}
EOF
        systemctl enable ss-rust@${IP} >/dev/null 2>&1
        systemctl restart ss-rust@${IP} >/dev/null 2>&1
        
        echo "${IP}/${PORT}/${MULTI_METHOD}/${PASSWORD}" >> "$OUTPUT_FILE"
        echo -e "${SUCCESS} 已启动独立节点 -> IP: ${IP} | 端口: ${PORT}"
        
        ((PORT++))
    done

    # 6. 批量放行本地防火墙端口范围 (修复 BUG 2)
    local END_PORT=$((PORT-1))
    echo -e "${INFO} 正在为多IP节点放行本地防火墙端口范围：${START_PORT}-${END_PORT}..."
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${START_PORT}-${END_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=${START_PORT}-${END_PORT}/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v ufw >/dev/null 2>&1 && ufw status | grep -qw active; then
        ufw allow ${START_PORT}:${END_PORT}/tcp >/dev/null 2>&1
        ufw allow ${START_PORT}:${END_PORT}/udp >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport ${START_PORT}:${END_PORT} -j ACCEPT
        iptables -I INPUT -p udp --dport ${START_PORT}:${END_PORT} -j ACCEPT
        if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save >/dev/null 2>&1;
        elif command -v service >/dev/null 2>&1; then service iptables save >/dev/null 2>&1; fi
    fi

    echo -e "================================================="
    echo -e "${SUCCESS} 站群多 IP 批量部署圆满完成！"
    echo -e "${INFO} 所有节点连接明细已保存至表格：${Green_font_prefix}${OUTPUT_FILE}${Font_color_suffix}"
    echo -e "${Tip} 重要提示：请务必去【云服务器厂商网页控制台】的安全组中，放行端口范围 [ ${START_PORT} - ${END_PORT} ]"
    echo -e "================================================="
    Before_Start_Menu
}

# 返回主菜单
Before_Start_Menu() {
    echo && echo -n -e "${Yellow_font_prefix}* 按回车返回主菜单 *${Font_color_suffix}" && read temp
}

# 主菜单
Start_Menu() {
    while true; do
        clear
        check_root
        detect_os
        action=${1:-}
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}          SS - 2022 管理脚本 ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "  
 ${Green_font_prefix}0.${Font_color_suffix} 更新脚本 (已禁用)
——————————————————————————————————
 ${Green_font_prefix}1.${Font_color_suffix} 安装 Shadowsocks Rust (单节点)
 ${Green_font_prefix}2.${Font_color_suffix} 更新 Shadowsocks Rust
 ${Green_font_prefix}3.${Font_color_suffix} 卸载 Shadowsocks Rust
——————————————————————————————————
 ${Green_font_prefix}4.${Font_color_suffix} 启动 Shadowsocks Rust
 ${Green_font_prefix}5.${Font_color_suffix} 停止 Shadowsocks Rust
 ${Green_font_prefix}6.${Font_color_suffix} 重启 Shadowsocks Rust
——————————————————————————————————
 ${Green_font_prefix}7.${Font_color_suffix} 设置 配置信息
 ${Green_font_prefix}8.${Font_color_suffix} 查看 配置信息
 ${Green_font_prefix}9.${Font_color_suffix} 查看 运行状态
——————————————————————————————————
 ${Green_font_prefix}10.${Font_color_suffix} 安装 ShadowTLS
 ${Green_font_prefix}11.${Font_color_suffix} ${Red_background_prefix} 批量部署 站群多IP节点 (新功能) ${Font_color_suffix}
 ${Green_font_prefix}12.${Font_color_suffix} 退出脚本
——————————————————————————————————
==================================" && echo
        
        if [[ -e ${BINARY_PATH} ]]; then
            echo -e " 当前状态：${Green_font_prefix}主程序已安装${Font_color_suffix}"
        else
            echo -e " 当前状态：${Red_font_prefix}未安装${Font_color_suffix}"
        fi
        echo
        read -e -p " 请输入数字 [0-12]：" num
        case "$num" in
            0) Update_Shell ;;
            1) Install ;;
            2) Update ;;
            3) Uninstall; sleep 2 ;;
            4) start_service; sleep 2 ;;
            5) Stop; sleep 2 ;;
            6) Restart; sleep 2 ;;
            7) modify_config ;;
            8) View; Before_Start_Menu ;;
            9) Status ;;
            10) install_shadowtls ;;
            11) Deploy_Multi_IP ;;
            12) echo -e "${INFO} 退出脚本..."; exit 0 ;;
            *) echo -e "${ERROR} 请输入正确数字 [0-12]"; sleep 2 ;;
        esac
    done
}

# 启动脚本
Start_Menu "$@"
