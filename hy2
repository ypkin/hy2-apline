#!/bin/sh

# 颜色代码
GREEN="\033[32m"
PINK="\033[35m"
RESET="\033[0m"

# 检测是否为 Alpine Linux
if ! grep -qi "alpine" /etc/os-release; then
    echo -e "${PINK}不支持此操作，当前系统不是 Alpine Linux。${RESET}"
    exit 1
fi

# 安装必要依赖组件
install_dependencies() {
    echo -e "${GREEN}更新软件源并安装基础依赖...${RESET}"
    apk update
    apk add --no-cache curl socat wget iptables ip6tables bash nano tzdata ca-certificates
}

# 生成随机 Gmail 地址
generate_random_email() {
    local length=10
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local email=""
    for i in $(seq 1 $length); do
        rand=$(tr -dc '0-9' < /dev/urandom | head -c 4)
        pos=$((rand % ${#chars}))
        email="${email}${chars:$pos:1}"
    done
    echo "${email}@gmail.com"
}

# 配置 OpenRC 服务
setup_openrc_service() {
    cat > /etc/init.d/hysteria-server << 'EOF'
#!/sbin/openrc-run

name="hysteria-server"
description="Hysteria 2 Server Service"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.err"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/hysteria-server
}

# 配置定时自动更新任务
setup_auto_update() {
    echo -e "${GREEN}配置 Hysteria 2 自动更新定时任务...${RESET}"
    
    # 确保 cron 服务自启
    rc-update add crond default
    service crond start >/dev/null 2>&1

    # 写入自动检查更新脚本
    cat > /usr/local/bin/hy2-autoupdate.sh << 'EOF'
#!/bin/sh
# 检测并更新 Hysteria 2
bash <(curl -fsSL https://get.hy2.sh/) --check >/dev/null 2>&1
if [ $? -eq 0 ]; then
    bash <(curl -fsSL https://get.hy2.sh/)
    service hysteria-server restart
fi
EOF
    chmod +x /usr/local/bin/hy2-autoupdate.sh

    # 添加到 crontab（每周一凌晨 3:30 执行更新检查）
    if ! crontab -l 2>/dev/null | grep -q "hy2-autoupdate.sh"; then
        (crontab -l 2>/dev/null; echo "30 3 * * 1 /usr/local/bin/hy2-autoupdate.sh >/dev/null 2>&1") | crontab -
    fi
    echo -e "${GREEN}已添加每周自动更新任务。${RESET}"
}

# 主菜单循环
while true; do
    echo -e "${GREEN}====== Hysteria 2 for Alpine Linux ======${RESET}"
    echo -e "${GREEN}1) 域名证书安装 Hysteria${RESET}"
    echo -e "${GREEN}2) 修改 Hysteria 配置${RESET}"
    echo -e "${GREEN}3) 输出当前 Hysteria 配置${RESET}"
    echo -e "${GREEN}4) 查看 Hysteria 运行状态${RESET}"
    echo -e "${GREEN}5) 重启 Hysteria${RESET}"
    echo -e "${GREEN}6) 停止 Hysteria${RESET}"
    echo -e "${GREEN}7) 查看 Hysteria 日志${RESET}"
    echo -e "${GREEN}8) 立即检查并更新 Hysteria 程序${RESET}"
    echo -e "${GREEN}9) 卸载 Hysteria${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e "${PINK}请输入选项 (0-9): ${RESET}")" option

    case $option in
        1)
            install_dependencies
            random_email=$(generate_random_email)

            read -p "$(echo -e "${PINK}输入解析好的域名: ${RESET}")" domain
            echo -e "${GREEN}分配随机邮箱地址: ${PINK}${random_email}${RESET}"
            read -p "$(echo -e "${PINK}输入自定义端口: ${RESET}")" port
            read -sp "$(echo -e "${PINK}输入您希望的密码: ${RESET}")" password
            echo

            # 下载官方二进制
            echo -e "${GREEN}下载并安装 Hysteria 2...${RESET}"
            if ! bash <(curl -fsSL https://get.hy2.sh/); then
                echo -e "${PINK}安装核心失败，请检查网络。${RESET}"
                exit 1
            fi

            mkdir -p /etc/hysteria

            # 写入 YAML 配置
            echo -e "${GREEN}写入配置到 /etc/hysteria/config.yaml...${RESET}"
            cat > /etc/hysteria/config.yaml <<EOF
listen: :$port

acme:
  domains:
    - $domain
  email: $random_email

auth:
  type: password
  password: $password

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

resolver:
  type: udp
  udp:
    addr: 8.8.8.8:53

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: 80,443,20000-40000
  udpPorts: all

outbounds:
  - name: v4_prefer
    type: direct
    direct:
      mode: 46
  - name: v4
    type: direct
    direct:
      mode: 4
  - name: v6
    type: direct
    direct:
      mode: 6
acl:
  inline:
    - v4_prefer(all)
EOF

            # 注册并启用 OpenRC 服务
            setup_openrc_service
            rc-update add hysteria-server default

            # 网卡与端口跳跃配置
            NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "eth|ens" | head -n 1)
            if [ -z "$NIC" ]; then
                echo -e "${PINK}未能自动获取网卡，跳过端口跳跃配置。${RESET}"
            else
                echo -e "${GREEN}检测到网卡: $NIC${RESET}"
                read -p "$(echo -e "${PINK}是否启用端口跳跃？(y/n): ${RESET}")" enable_hop
                if [ "$enable_hop" = "y" ] || [ "$enable_hop" = "Y" ]; then
                    read -p "$(echo -e "${PINK}起始端口 (例如 20000): ${RESET}")" START_PORT
                    read -p "$(echo -e "${PINK}结束端口 (例如 40000): ${RESET}")" END_PORT
                    
                    # 规则写入
                    iptables -t nat -A PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$port"
                    ip6tables -t nat -A PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$port" 2>/dev/null

                    # Alpine 下保存 iptables
                    /etc/init.d/iptables save 2>/dev/null
                    /etc/init.d/ip6tables save 2>/dev/null
                    rc-update add iptables default 2>/dev/null
                    rc-update add ip6tables default 2>/dev/null
                    echo -e "${GREEN}端口跳跃规则已应用并保存。${RESET}"
                fi
            fi

            # 配置自动更新
            setup_auto_update

            # 启动服务
            service hysteria-server start
            echo -e "${GREEN}Hysteria 2 安装并已尝试启动。${RESET}"
            ;;

        2)
            nano /etc/hysteria/config.yaml
            service hysteria-server restart
            echo -e "${GREEN}配置已保存并重启服务。${RESET}"
            ;;

        3)
            echo -e "${GREEN}当前配置文件 (/etc/hysteria/config.yaml):${RESET}"
            cat /etc/hysteria/config.yaml
            echo -e "${GREEN}按任意键返回...${RESET}"
            read -n 1 -s
            ;;

        4)
            service hysteria-server status
            echo -e "${GREEN}按任意键返回...${RESET}"
            read -n 1 -s
            ;;

        5)
            service hysteria-server restart
            echo -e "${GREEN}服务已重启。${RESET}"
            ;;

        6)
            service hysteria-server stop
            echo -e "${GREEN}服务已停止。${RESET}"
            ;;

        7)
            echo -e "${GREEN}查看最近日志 (Ctrl+C 退出):${RESET}"
            tail -f -n 50 /var/log/hysteria.log /var/log/hysteria.err 2>/dev/null
            ;;

        8)
            echo -e "${GREEN}正在拉取最新版本更新...${RESET}"
            bash <(curl -fsSL https://get.hy2.sh/)
            service hysteria-server restart
            echo -e "${GREEN}程序更新完成并已重启服务。${RESET}"
            ;;

        9)
            echo -e "${PINK}开始卸载 Hysteria 2...${RESET}"
            service hysteria-server stop >/dev/null 2>&1
            rc-update del hysteria-server default >/dev/null 2>&1
            rm -f /etc/init.d/hysteria-server
            rm -rf /etc/hysteria
            rm -f /usr/local/bin/hysteria
            rm -f /usr/local/bin/hy2-autoupdate.sh
            crontab -l 2>/dev/null | grep -v "hy2-autoupdate.sh" | crontab -
            echo -e "${GREEN}卸载完成。${RESET}"
            ;;

        0)
            exit 0
            ;;

        *)
            echo -e "${PINK}无效选项，请输入 0-9。${RESET}"
            sleep 1
            ;;
    esac
done
