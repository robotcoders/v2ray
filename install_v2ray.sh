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

# 确保基本命令可用
echo -e "${BLUE}检查并安装基本命令...${PLAIN}"

# 检查是否为WSL环境
if [ -f /proc/version ] && grep -q Microsoft /proc/version 2>/dev/null; then
    echo -e "${YELLOW}检测到WSL环境...${PLAIN}"
    WSL_ENV=true
else
    WSL_ENV=false
fi

# 确保基本命令可用
if ! command -v apt &> /dev/null && ! command -v apt-get &> /dev/null; then
    echo -e "${RED}错误: 无法找到apt或apt-get命令，请确保系统是基于Debian/Ubuntu的发行版${PLAIN}"
    exit 1
fi

# 优先使用apt-get，因为在某些WSL环境中apt可能不可用
if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt-get"
else
    PKG_MANAGER="apt"
 fi

# 安装基本工具
echo -e "${BLUE}安装基本工具...${PLAIN}"
$PKG_MANAGER update -y

# 安装必要的基础工具
echo -e "${BLUE}安装必要的基础工具...${PLAIN}"
$PKG_MANAGER install -y curl wget unzip net-tools grep

# 安装V2Ray
echo -e "${BLUE}安装V2Ray...${PLAIN}"

# 确保所有必要的命令都可用
for cmd in curl wget chmod bash; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${YELLOW}${cmd}命令未找到，尝试安装${cmd}...${PLAIN}"
        $PKG_MANAGER install -y $cmd
        
        # 再次检查命令是否安装成功
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}错误: 无法安装${cmd}命令，请手动安装后重试${PLAIN}"
            exit 1
        fi
    fi
done

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

# 确保pgrep和sleep命令可用
for cmd in pgrep sleep; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${YELLOW}${cmd}命令未找到，尝试安装${cmd}...${PLAIN}"
        $PKG_MANAGER install -y $cmd || $PKG_MANAGER install -y procps
    fi
done

# 根据环境选择启动方式
if [ "$WSL_ENV" = true ]; then
    echo -e "${YELLOW}WSL环境中启动V2Ray...${PLAIN}"
    
    # 尝试使用service命令
    if command -v service &> /dev/null; then
        echo -e "${BLUE}尝试使用service命令启动V2Ray...${PLAIN}"
        service v2ray start
        sleep 2
        
        # 检查是否成功启动
        if service v2ray status 2>/dev/null | grep -q "running"; then
            echo -e "${GREEN}V2Ray已通过service命令成功启动!${PLAIN}"
        else
            echo -e "${YELLOW}service命令启动失败，尝试直接运行V2Ray...${PLAIN}"
            nohup /usr/local/bin/v2ray run -c /usr/local/etc/v2ray/config.json > /var/log/v2ray.log 2>&1 &
            sleep 2
            
            if pgrep v2ray > /dev/null; then
                echo -e "${GREEN}V2Ray已手动启动并正在运行!${PLAIN}"
                echo -e "${YELLOW}注意: 在WSL环境中，您需要手动创建启动脚本以便系统重启后自动启动V2Ray${PLAIN}"
                
                # 创建启动脚本
                cat > /etc/init.d/v2ray << EOFSERVICE
#!/bin/sh
### BEGIN INIT INFO
# Provides:          v2ray
# Required-Start:    $network $local_fs $remote_fs
# Required-Stop:     $network $local_fs $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: V2Ray proxy service
### END INIT INFO

case "\$1" in
  start)
    echo "Starting V2Ray..."
    nohup /usr/local/bin/v2ray run -c /usr/local/etc/v2ray/config.json > /var/log/v2ray.log 2>&1 &
    ;;
  stop)
    echo "Stopping V2Ray..."
    pkill v2ray
    ;;
  restart)
    \$0 stop
    sleep 1
    \$0 start
    ;;
  status)
    if pgrep v2ray > /dev/null; then
      echo "V2Ray is running"
    else
      echo "V2Ray is not running"
    fi
    ;;
  *)
    echo "Usage: \$0 {start|stop|restart|status}"
    exit 1
    ;;
esac

exit 0
EOFSERVICE
                chmod +x /etc/init.d/v2ray
                echo -e "${GREEN}已创建V2Ray启动脚本: /etc/init.d/v2ray${PLAIN}"
                echo -e "${YELLOW}您可以使用 '/etc/init.d/v2ray start|stop|restart|status' 来控制V2Ray${PLAIN}"
            else
                echo -e "${RED}V2Ray启动失败，请检查日志: /var/log/v2ray.log${PLAIN}"
                exit 1
            fi
        fi
    else
        # 如果service命令不可用，直接运行V2Ray
        echo -e "${YELLOW}service命令不可用，直接运行V2Ray...${PLAIN}"
        nohup /usr/local/bin/v2ray run -c /usr/local/etc/v2ray/config.json > /var/log/v2ray.log 2>&1 &
        sleep 2
        
        if pgrep v2ray > /dev/null; then
            echo -e "${GREEN}V2Ray已手动启动并正在运行!${PLAIN}"
            # 创建启动脚本同上
        else
            echo -e "${RED}V2Ray启动失败，请检查日志: /var/log/v2ray.log${PLAIN}"
            exit 1
        fi
    fi
else
    # 非WSL环境使用systemctl
    if command -v systemctl &> /dev/null; then
        echo -e "${BLUE}使用systemctl启动V2Ray...${PLAIN}"
        systemctl enable v2ray
        systemctl restart v2ray
        sleep 2
        
        # 检查V2Ray状态
        if systemctl status v2ray | grep -q "active (running)"; then
            echo -e "${GREEN}V2Ray安装成功并正在运行!${PLAIN}"
        else
            echo -e "${RED}V2Ray安装失败，请检查日志${PLAIN}"
            exit 1
        fi
    else
        echo -e "${YELLOW}systemctl命令不可用，尝试使用service命令...${PLAIN}"
        service v2ray start
        sleep 2
        
        if service v2ray status | grep -q "running"; then
            echo -e "${GREEN}V2Ray已通过service命令成功启动!${PLAIN}"
        else
            echo -e "${RED}V2Ray启动失败，请检查系统服务管理器${PLAIN}"
            exit 1
        fi
    fi
fi

# 获取服务器IP
echo -e "${BLUE}获取服务器IP...${PLAIN}"

# 在WSL环境中，尝试获取宿主机Windows的IP
if [ "$WSL_ENV" = true ]; then
    echo -e "${YELLOW}WSL环境中获取IP地址...${PLAIN}"
    
    # 尝试获取WSL宿主机IP
    if command -v ipconfig.exe &> /dev/null; then
        # 尝试使用Windows的ipconfig命令获取IP
        WINDOWS_IP=$(ipconfig.exe | grep -A 5 "Wireless LAN adapter" | grep "IPv4 Address" | head -n 1 | awk '{print $NF}' | tr -d '\r')
        if [ -n "$WINDOWS_IP" ]; then
            IP=$WINDOWS_IP
            echo -e "${GREEN}已获取Windows宿主机IP: ${IP}${PLAIN}"
        fi
    fi
fi

# 如果在WSL中未能获取宿主机IP，或者不是WSL环境，则尝试获取公网IP
if [ -z "$IP" ]; then
    if command -v curl &> /dev/null; then
        IP=$(curl -s https://api.ipify.org)
    fi
    
    if [ -z "$IP" ] && command -v curl &> /dev/null; then
        IP=$(curl -s https://ipinfo.io/ip)
    fi
    
    if [ -z "$IP" ] && command -v curl &> /dev/null; then
        IP=$(curl -s https://api.ip.sb/ip)
    fi
    
    if [ -z "$IP" ] && command -v wget &> /dev/null; then
        IP=$(wget -qO- -t1 -T2 ipinfo.io/ip)
    fi
fi

# 如果仍然无法获取IP，使用本地IP
if [ -z "$IP" ]; then
    echo -e "${YELLOW}无法获取公网IP，尝试获取本地IP...${PLAIN}"
    if command -v hostname &> /dev/null; then
        IP=$(hostname -I | awk '{print $1}')
    elif command -v ip &> /dev/null; then
        IP=$(ip addr show | grep -E 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    fi
    
    if [ -z "$IP" ]; then
        echo -e "${RED}警告: 无法获取IP地址，使用127.0.0.1作为默认值${PLAIN}"
        IP="127.0.0.1"
    fi
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
if [ "$WSL_ENV" = true ]; then
    echo -e "${YELLOW}检测到WSL环境，WSL使用宿主机的防火墙，跳过防火墙配置...${PLAIN}"
    echo -e "${YELLOW}请确保在Windows防火墙中开放${PORT}端口${PLAIN}"
    
    # 提供Windows防火墙配置指南
    echo -e "${GREEN}==================================${PLAIN}"
    echo -e "${YELLOW}Windows防火墙配置指南:${PLAIN}"
    echo -e "1. 打开Windows控制面板"
    echo -e "2. 进入'系统和安全' -> 'Windows Defender防火墙'"
    echo -e "3. 点击左侧的'高级设置'"
    echo -e "4. 右键点击'入站规则'，选择'新建规则'"
    echo -e "5. 选择'端口'，点击'下一步'"
    echo -e "6. 选择'TCP'和'特定本地端口'，输入'${PORT}'，点击'下一步'"
    echo -e "7. 选择'允许连接'，点击'下一步'"
    echo -e "8. 选择应用规则的网络类型，点击'下一步'"
    echo -e "9. 输入规则名称(如'V2Ray-TCP-${PORT}')，点击'完成'"
    echo -e "10. 重复步骤4-9，为UDP协议创建相同的规则"
    echo -e "${GREEN}==================================${PLAIN}"
else
    # 非WSL环境配置防火墙
    if command -v ufw &> /dev/null; then
        echo -e "${BLUE}使用ufw配置防火墙...${PLAIN}"
        
        # 配置防火墙规则
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
    elif command -v firewall-cmd &> /dev/null; then
        echo -e "${BLUE}使用firewall-cmd配置防火墙...${PLAIN}"
        firewall-cmd --permanent --add-port=${PORT}/tcp
        firewall-cmd --permanent --add-port=${PORT}/udp
        firewall-cmd --reload
    elif command -v iptables &> /dev/null; then
        echo -e "${BLUE}使用iptables配置防火墙...${PLAIN}"
        iptables -A INPUT -p tcp --dport ${PORT} -j ACCEPT
        iptables -A INPUT -p udp --dport ${PORT} -j ACCEPT
        echo -e "${YELLOW}注意: iptables规则在系统重启后会丢失，请考虑安装iptables-persistent${PLAIN}"
    else
        echo -e "${YELLOW}未找到支持的防火墙管理工具(ufw/firewall-cmd/iptables)，请手动配置防火墙${PLAIN}"
        echo -e "${YELLOW}需要开放的端口: ${PORT}/tcp, ${PORT}/udp${PLAIN}"
    fi
fi

echo -e "${GREEN}安装完成!${PLAIN}"
