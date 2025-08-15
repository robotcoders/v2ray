#!/bin/bash

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用root用户运行此脚本${PLAIN}"
    exit 1
fi

# 检查系统版本
if [[ ! -f /etc/os-release ]]; then
    echo -e "${RED}错误: 无法确定操作系统版本${PLAIN}"
    exit 1
fi

source /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    echo -e "${RED}错误: 此脚本仅支持Ubuntu系统${PLAIN}"
    exit 1
fi

if [[ "$VERSION_ID" != "24.04" ]]; then
    echo -e "${YELLOW}警告: 此脚本针对Ubuntu 24.04优化，当前系统为$VERSION_ID，可能会有兼容性问题${PLAIN}"
    read -p "是否继续? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# 配置信息
echo -e "${GREEN}开始配置V2Ray代理服务器...${PLAIN}"

# 读取用户输入
read -p "请输入您想使用的端口号 (1-65535): " PORT
while [[ $PORT -lt 1 || $PORT -gt 65535 ]]; do
    read -p "端口号无效，请重新输入 (1-65535): " PORT
done

read -p "请输入UUID (留空将自动生成): " UUID
if [[ -z "$UUID" ]]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo -e "${GREEN}已自动生成UUID: ${UUID}${PLAIN}"
fi

read -p "请输入伪装域名 (例如 www.microsoft.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    DOMAIN="www.microsoft.com"
    echo -e "${GREEN}使用默认伪装域名: ${DOMAIN}${PLAIN}"
fi

read -p "请输入传输协议 (ws/tcp/kcp/quic/grpc，默认ws): " TRANSPORT
if [[ -z "$TRANSPORT" ]]; then
    TRANSPORT="ws"
fi
TRANSPORT=$(echo $TRANSPORT | tr '[:upper:]' '[:lower:]')

read -p "请输入伪装路径 (默认为/): " PATH
if [[ -z "$PATH" ]]; then
    PATH="/"
fi

# 更新系统并安装必要工具
echo -e "${BLUE}更新系统并安装必要工具...${PLAIN}"
# 检查是否为WSL环境
if grep -q Microsoft /proc/version; then
    echo -e "${YELLOW}检测到WSL环境，使用apt-get命令...${PLAIN}"
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl wget unzip net-tools
else
    apt update -y
    apt upgrade -y
    apt install -y curl wget unzip net-tools
fi

# 安装V2Ray
echo -e "${BLUE}安装V2Ray...${PLAIN}"
# 检查curl命令是否可用
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}curl命令未找到，尝试安装curl...${PLAIN}"
    if grep -q Microsoft /proc/version; then
        apt-get install -y curl
    else
        apt install -y curl
    fi
fi

# 下载安装脚本并执行
echo -e "${BLUE}下载V2Ray安装脚本...${PLAIN}"
wget -O v2ray_install.sh https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh
chmod +x v2ray_install.sh
bash ./v2ray_install.sh

# 配置V2Ray
echo -e "${BLUE}配置V2Ray...${PLAIN}"
cat > /usr/local/etc/v2ray/config.json << EOF
{
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vmess",
    "settings": {
      "clients": [
        {
          "id": "${UUID}",
          "alterId": 0
        }
      ]
    },
    "streamSettings": {
      "network": "${TRANSPORT}",
      "wsSettings": {
        "path": "${PATH}",
        "headers": {
          "Host": "${DOMAIN}"
        }
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  }]
}
EOF

# 启动V2Ray并设置开机自启
echo -e "${BLUE}启动V2Ray并设置开机自启...${PLAIN}"

# 检查是否为WSL环境
if grep -q Microsoft /proc/version; then
    echo -e "${YELLOW}检测到WSL环境，使用service命令启动V2Ray...${PLAIN}"
    service v2ray start
    # 检查V2Ray状态
    if service v2ray status | grep -q "running"; then
        echo -e "${GREEN}V2Ray安装成功并正在运行!${PLAIN}"
    else
        echo -e "${YELLOW}尝试直接运行V2Ray...${PLAIN}"
        /usr/local/bin/v2ray run -c /usr/local/etc/v2ray/config.json &
        sleep 2
        if pgrep v2ray > /dev/null; then
            echo -e "${GREEN}V2Ray已手动启动并正在运行!${PLAIN}"
        else
            echo -e "${RED}V2Ray安装失败，请检查日志${PLAIN}"
            exit 1
        fi
    fi
else
    # 非WSL环境使用systemctl
    systemctl enable v2ray
    systemctl restart v2ray
    # 检查V2Ray状态
    if systemctl status v2ray | grep -q "active (running)"; then
        echo -e "${GREEN}V2Ray安装成功并正在运行!${PLAIN}"
    else
        echo -e "${RED}V2Ray安装失败，请检查日志${PLAIN}"
        exit 1
    fi
fi

# 获取服务器IP
IP=$(curl -s https://api.ipify.org)
if [[ -z "$IP" ]]; then
    IP=$(curl -s https://ipinfo.io/ip)
fi
if [[ -z "$IP" ]]; then
    IP=$(curl -s https://api.ip.sb/ip)
fi
if [[ -z "$IP" ]]; then
    IP=$(wget -qO- -t1 -T2 ipinfo.io/ip)
fi

# 生成Clash配置
echo -e "${BLUE}生成Clash配置文件...${PLAIN}"
cat > /root/clash_config.yaml << EOF
port: 7890
socks-port: 7891
allow-lan: true
mode: Rule
log-level: info
external-controller: 127.0.0.1:9090
proxies:
  - name: V2Ray_Server
    type: vmess
    server: ${IP}
    port: ${PORT}
    uuid: ${UUID}
    alterId: 0
    cipher: auto
    udp: true
    network: ${TRANSPORT}
    ws-opts:
      path: ${PATH}
      headers:
        Host: ${DOMAIN}

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - V2Ray_Server
      - DIRECT

rules:
  - DOMAIN-SUFFIX,google.com,PROXY
  - DOMAIN-SUFFIX,facebook.com,PROXY
  - DOMAIN-SUFFIX,twitter.com,PROXY
  - DOMAIN-SUFFIX,youtube.com,PROXY
  - DOMAIN-SUFFIX,netflix.com,PROXY
  - DOMAIN-SUFFIX,amazonaws.com,PROXY
  - DOMAIN-SUFFIX,cloudfront.net,PROXY
  - DOMAIN-SUFFIX,github.com,PROXY
  - DOMAIN-SUFFIX,telegram.org,PROXY
  - DOMAIN-KEYWORD,google,PROXY
  - DOMAIN-KEYWORD,facebook,PROXY
  - DOMAIN-KEYWORD,twitter,PROXY
  - DOMAIN-KEYWORD,youtube,PROXY
  - DOMAIN-KEYWORD,netflix,PROXY
  - DOMAIN-KEYWORD,github,PROXY
  - DOMAIN-KEYWORD,telegram,PROXY
  - IP-CIDR,91.108.4.0/22,PROXY
  - IP-CIDR,91.108.8.0/22,PROXY
  - IP-CIDR,91.108.12.0/22,PROXY
  - IP-CIDR,91.108.16.0/22,PROXY
  - IP-CIDR,91.108.56.0/22,PROXY
  - IP-CIDR,149.154.160.0/20,PROXY
  - GEOIP,CN,DIRECT
  - MATCH,DIRECT
EOF

# 显示配置信息
echo -e "${GREEN}==================================${PLAIN}"
echo -e "${GREEN}V2Ray安装成功!${PLAIN}"
echo -e "${GREEN}==================================${PLAIN}"
echo -e "${YELLOW}服务器信息:${PLAIN}"
echo -e "${YELLOW}IP地址: ${IP}${PLAIN}"
echo -e "${YELLOW}端口: ${PORT}${PLAIN}"
echo -e "${YELLOW}UUID: ${UUID}${PLAIN}"
echo -e "${YELLOW}传输协议: ${TRANSPORT}${PLAIN}"
echo -e "${YELLOW}伪装域名: ${DOMAIN}${PLAIN}"
echo -e "${YELLOW}伪装路径: ${PATH}${PLAIN}"
echo -e "${GREEN}==================================${PLAIN}"
echo -e "${YELLOW}Clash配置文件已生成: /root/clash_config.yaml${PLAIN}"
echo -e "${GREEN}==================================${PLAIN}"

# 防火墙设置
echo -e "${BLUE}配置防火墙...${PLAIN}"
# 检查是否为WSL环境
if grep -q Microsoft /proc/version; then
    echo -e "${YELLOW}检测到WSL环境，WSL使用宿主机的防火墙，跳过防火墙配置...${PLAIN}"
    echo -e "${YELLOW}请确保在Windows防火墙中开放${PORT}端口${PLAIN}"
else
    # 检查ufw命令是否可用
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}ufw命令未找到，尝试安装ufw...${PLAIN}"
        apt install -y ufw || apt-get install -y ufw
    fi
    
    # 配置防火墙
    ufw allow ${PORT}/tcp
    ufw allow ${PORT}/udp
    ufw allow 22/tcp
    
    # 如果防火墙未启用，询问是否启用
    if ! ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}防火墙当前未启用，是否启用? (y/n)${PLAIN}"
        read -p "" -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "y" | ufw enable
        fi
    fi
fi

echo -e "${GREEN}安装完成!${PLAIN}"
