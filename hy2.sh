#!/bin/bash

# 颜色代码
GREEN="\033[32m"
PINK="\033[35m"
RESET="\033[0m"

# 检测是否为 Alpine Linux
if ! grep -qi "alpine" /etc/os-release; then
    echo -e "${PINK}不支持此操作，当前系统不是 Alpine Linux。${RESET}"
    exit 1
fi

# 安装必要依赖组件（含 iptables/ip6tables 持久化组件与运行依赖）
# 容错（2026-11-19 CC 实测）：apk 数据库损坏时（如 mkinitfs 安装状态损坏）
# apk update/add 会报错，但所需依赖可能早已装齐——此时不应直接退出；
# 先跑一次 apk fix 修复损坏状态并重试，仍失败则逐项核对，齐了就继续、缺了才退出。
install_dependencies() {
    echo -e "${GREEN}正在更新软件源并安装依赖组件...${RESET}"
    if apk update && apk add --no-cache curl socat wget iptables ip6tables bash nano tzdata ca-certificates; then
        return 0
    fi
    echo -e "${PINK}apk 安装失败，尝试修复后重试...${RESET}"
    apk fix >/dev/null 2>&1
    apk update >/dev/null 2>&1
    apk add --no-cache curl socat wget iptables ip6tables bash nano tzdata ca-certificates >/dev/null 2>&1 || true
    local missing=""
    for cmd in curl socat wget iptables ip6tables bash nano; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    for pkg in tzdata ca-certificates; do
        apk info -e "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done
    if [ -n "$missing" ]; then
        echo -e "${PINK}安装组件失败，仍缺少:$missing，请检查网络设置与 apk 状态。${RESET}"
        exit 1
    fi
    echo -e "${GREEN}依赖检查通过（所需组件均已就绪），继续安装。${RESET}"
}

# 检查并自动补全 iptables 相关持久化插件
check_and_install_iptables_tools() {
    echo -e "${GREEN}正在检查 iptables 及持久化支持组件...${RESET}"

    # 检查核心工具是否存在
    local missing_pkgs=""
    if ! command -v iptables &> /dev/null; then
        missing_pkgs="$missing_pkgs iptables"
    fi
    if ! command -v ip6tables &> /dev/null; then
        missing_pkgs="$missing_pkgs ip6tables"
    fi

    # 如果有缺失的组件，自动通过 apk 安装
    if [ -n "$missing_pkgs" ]; then
        echo -e "${PINK}检测到缺少必要防火墙组件:$missing_pkgs，正在自动安装...${RESET}"
        apk add --no-cache iptables ip6tables
    fi

    # 确保 iptables 的 OpenRC 服务脚本存在（用于 rc-service iptables save）
    if [ ! -f /etc/init.d/iptables ]; then
        echo -e "${PINK}未检测到 iptables 服务脚本，正在尝试重新安装 iptables-openrc...${RESET}"
        apk add --no-cache iptables-openrc ip6tables-openrc 2>/dev/null || true
    fi

    echo -e "${GREEN}防火墙组件检查与安装完成。${RESET}"
}

# 读取当前配置的监听端口（取不到时默认 9443）
get_listen_port() {
    local p
    p=$(grep -E '^\s*listen:' /etc/hysteria/config.yaml 2>/dev/null | grep -oE '[0-9]+' | head -1)
    echo "${p:-9443}"
}

# 精确删除已有的端口跳跃规则：只删 PREROUTING 里 --to-ports 等于 hy2 监听端口的
# REDIRECT 规则，其他 NAT 规则（例如别的服务做的重定向）一律不动。
# （旧版用 -F 清空整条 PREROUTING，会误伤无关规则，这里修复。）
delete_hop_rules() {
    local tbl spec target
    target=$(get_listen_port)
    for tbl in iptables ip6tables; do
        command -v "$tbl" >/dev/null 2>&1 || continue
        # -S 输出形如：-A PREROUTING -p udp -m udp --dport 20000:40000 -j REDIRECT --to-ports 9443
        $tbl -t nat -S PREROUTING 2>/dev/null | grep -- "--to-ports $target" | while read -r spec; do
            $tbl -t nat $(echo "$spec" | sed 's/^-A /-D /') 2>/dev/null
        done
    done
}

# 保存 v4/v6 规则并设开机自启；保存失败返回非 0，不再静默吞掉
save_iptables_rules() {
    local ok=1
    rc-service iptables save >/dev/null 2>&1 || ok=0
    rc-update add iptables default >/dev/null 2>&1
    if command -v ip6tables >/dev/null 2>&1; then
        rc-service ip6tables save >/dev/null 2>&1 || ok=0
        rc-update add ip6tables default >/dev/null 2>&1
    fi
    [ "$ok" = "1" ]
}

# 应用端口跳跃：先精确删除旧跳跃规则，再加新规则
# IPv4 必须成功；IPv6 失败单独提示（无 v6 的机器不影响 v4）；最后保存并回显规则确认
apply_hop_rules() {
    local start=$1 end=$2 target=$3
    delete_hop_rules
    if ! iptables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-port "$target"; then
        echo -e "${PINK}IPv4 跳跃规则添加失败。${RESET}"
        return 1
    fi
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-port "$target" 2>/dev/null; then
        echo -e "${GREEN}IPv6 跳跃规则已添加。${RESET}"
    else
        echo -e "${PINK}提示：IPv6 跳跃规则未添加（本机可能无 IPv6 或 ip6tables 不可用），不影响 IPv4。${RESET}"
    fi
    if ! save_iptables_rules; then
        echo -e "${PINK}规则已生效，但保存持久化失败，重启后可能丢失，请检查 iptables 服务。${RESET}"
        return 1
    fi
    echo -e "${GREEN}端口跳跃已生效并保存（UDP $start-$end -> $target），当前规则：${RESET}"
    iptables -t nat -S PREROUTING 2>/dev/null | grep REDIRECT || true
    ip6tables -t nat -S PREROUTING 2>/dev/null | grep REDIRECT || true
}

# 显示当前跳跃规则
show_hop_rules() {
    echo -e "${GREEN}当前 IPv4 跳跃规则：${RESET}"
    iptables -t nat -S PREROUTING 2>/dev/null | grep REDIRECT || echo "（无）"
    echo -e "${GREEN}当前 IPv6 跳跃规则：${RESET}"
    ip6tables -t nat -S PREROUTING 2>/dev/null | grep REDIRECT || echo "（无）"
}

# 端口跳跃设置子菜单：查看 / 设置或修改 / 关闭，修改完即时生效并自动保存
setup_port_hopping() {
    while true; do
        echo -e "${GREEN}====== 端口跳跃设置 ======${RESET}"
        echo -e "${GREEN}1) 查看当前跳跃规则${RESET}"
        echo -e "${GREEN}2) 设置/修改跳跃端口（IPv4+IPv6）${RESET}"
        echo -e "${GREEN}3) 关闭端口跳跃${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        read -p "$(echo -e "${PINK}请输入选项 (0-3): ${RESET}")" hop_opt
        case $hop_opt in
            1)
                show_hop_rules
                ;;
            2)
                local cur_target
                cur_target=$(get_listen_port)
                read -p "$(echo -e "${PINK}请输入跳跃端口范围的起始端口 (例如 20000): ${RESET}")" h_start
                read -p "$(echo -e "${PINK}请输入跳跃端口范围的结束端口 (例如 40000): ${RESET}")" h_end
                read -p "$(echo -e "${PINK}请输入目标端口 (直接回车默认当前监听端口 ${cur_target}): ${RESET}")" h_target
                h_target=${h_target:-$cur_target}
                if [[ ! "$h_start" =~ ^[0-9]+$ || ! "$h_end" =~ ^[0-9]+$ || ! "$h_target" =~ ^[0-9]+$ ]]; then
                    echo -e "${PINK}输入无效，端口必须为数字。${RESET}"
                elif [[ "$h_start" -ge "$h_end" ]]; then
                    echo -e "${PINK}起始端口必须小于结束端口。${RESET}"
                else
                    apply_hop_rules "$h_start" "$h_end" "$h_target"
                fi
                ;;
            3)
                delete_hop_rules
                if save_iptables_rules; then
                    echo -e "${GREEN}端口跳跃已关闭并保存。${RESET}"
                else
                    echo -e "${PINK}规则已删除，但保存失败，请检查 iptables 服务。${RESET}"
                fi
                show_hop_rules
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${PINK}无效选项，请输入 0 到 3 的数字。${RESET}"
                ;;
        esac
        echo -e "${GREEN}按任意键继续...${RESET}"
        read -n 1 -s
    done
}

# 生成随机 Gmail 邮箱地址
generate_random_email() {
    local length=10
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local email=""
    for i in $(seq 1 $length); do
        email+="${chars:RANDOM%${#chars}:1}"
    done
    echo "${email}@gmail.com"
}

# 配置 OpenRC 服务
# 修复：改用 supervise-daemon 跟踪进程。旧写法 command_background + pidfile
# 在 hysteria 这类不写 pidfile 的常驻进程上经常对不上，会出现"进程在跑
# 但 rc-service status 显示 crashed"的情况。
setup_openrc_service() {
    cat > /etc/init.d/hysteria-server << 'EOF'
#!/sbin/openrc-run

name="hysteria-server"
description="Hysteria 2 Server Service"
supervisor=supervise-daemon
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.err"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/hysteria-server
}

# 写入独立的 hysteria 二进制安装/更新脚本（供菜单安装、手动更新、定时更新共用）
# 官方 get.hy2.sh 只支持 systemd 且依赖 grep -P / useradd，在 Alpine 上不可用，
# 这里改为从 GitHub release 直接下载对应架构的二进制文件
setup_hy2_installer() {
    cat > /usr/local/bin/hy2-install.sh << 'EOF'
#!/bin/bash
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv6l) ARCH="arm" ;;
    *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
esac
URL="https://download.hysteria.network/app/latest/hysteria-linux-${ARCH}"
TMP=/usr/local/bin/hysteria.new
echo "下载最新版本: $URL"
curl -fsSL -o "$TMP" "$URL" || { echo "下载失败" >&2; rm -f "$TMP"; exit 1; }
chmod +x "$TMP"
VER=$("$TMP" version 2>/dev/null | grep -i '^Version' | awk '{print $2}')
[ -n "$VER" ] || { echo "新二进制校验失败" >&2; rm -f "$TMP"; exit 1; }
mv "$TMP" /usr/local/bin/hysteria
echo "Hysteria $VER 安装完成。"
EOF
    chmod +x /usr/local/bin/hy2-install.sh
}

# 配置定时自动检查更新
setup_auto_update() {
    echo -e "${GREEN}配置每日自动更新任务...${RESET}"
    rc-update add crond default >/dev/null 2>&1
    rc-service crond start >/dev/null 2>&1

    cat > /usr/local/bin/hy2-autoupdate.sh << 'EOF'
#!/bin/bash
/usr/local/bin/hy2-install.sh && rc-service hysteria-server restart
EOF
    chmod +x /usr/local/bin/hy2-autoupdate.sh

    # 每天凌晨 04:00 自动检查并更新二进制文件
    if ! crontab -l 2>/dev/null | grep -q "hy2-autoupdate.sh"; then
        (crontab -l 2>/dev/null; echo "0 4 * * * /usr/local/bin/hy2-autoupdate.sh >/dev/null 2>&1") | crontab -
    fi
}

# 主菜单循环
while true; do
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}    Hysteria 2 - Alpine Linux       ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}1) 域名证书安装 Hysteria${RESET}"
    echo -e "${GREEN}2) 修改 Hysteria 配置${RESET}"
    echo -e "${GREEN}3) 输出当前 Hysteria 配置${RESET}"
    echo -e "${GREEN}4) 查看 Hysteria 运行状态${RESET}"
    echo -e "${GREEN}5) 重启 Hysteria${RESET}"
    echo -e "${GREEN}6) 停止 Hysteria${RESET}"
    echo -e "${GREEN}7) 查看 Hysteria 日志${RESET}"
    echo -e "${GREEN}8) 立即更新 Hysteria 核心${RESET}"
    echo -e "${GREEN}9) 卸载 Hysteria${RESET}"
    echo -e "${GREEN}10) 端口跳跃设置${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e "${PINK}请输入选项 (0-10): ${RESET}")" option

    case $option in
        1)
            install_dependencies
            setup_hy2_installer
            random_email=$(generate_random_email)

            read -p "$(echo -e "${PINK}输入解析好的域名 (例如 ${GREEN}example.com${RESET}): ${RESET}")" domain
            echo -e "${GREEN}随机生成的邮箱地址为: ${PINK}${random_email}${RESET}"

            read -p "$(echo -e "${PINK}输入自定义端口 (例如 ${GREEN}9443${RESET}): ${RESET}")" port

            read -sp "$(echo -e "${PINK}输入您希望的密码 (输入将被隐藏): ${RESET}")" password
            echo

            # 流量混淆 obfs（可选）：启用后客户端需填相同的混淆类型与密码才能连接
            read -p "$(echo -e "${PINK}是否启用流量混淆 obfs？(y/n): ${RESET}")" enable_obfs
            obfs_type=""
            obfs_password=""
            if [ "$enable_obfs" = "y" ] || [ "$enable_obfs" = "Y" ]; then
                read -p "$(echo -e "${PINK}混淆类型 (gecko/salamander，直接回车默认 gecko): ${RESET}")" obfs_type
                obfs_type=${obfs_type:-gecko}
                read -sp "$(echo -e "${PINK}输入混淆密码 (输入将被隐藏): ${RESET}")" obfs_password
                echo
            fi

            # 下载 hysteria 二进制程序（直接从 GitHub release 获取）
            echo -e "${GREEN}正在下载并安装 Hysteria...${RESET}"
            if ! /usr/local/bin/hy2-install.sh; then
                echo -e "${PINK}安装 Hysteria 失败，退出中...${RESET}"
                exit 1
            fi

            # 注册 OpenRC 服务
            setup_openrc_service
            rc-update add hysteria-server default

            # 生成配置文件
            # 修复：密码用 $(printf '%s' ...) 写入，含 $、反引号、反斜杠的密码
            # 不会被 heredoc 的 shell 展开吃掉，原样写入 YAML
            mkdir -p /etc/hysteria
            echo -e "${GREEN}正在写入配置到 /etc/hysteria/config.yaml...${RESET}"
            cat > /etc/hysteria/config.yaml <<EOF
listen: :$port

acme:
  domains:
    - $domain
  email: $random_email

auth:
  type: password
  password: $(printf '%s' "$password")

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

            echo -e "${GREEN}Hysteria 配置已写入到 /etc/hysteria/config.yaml${RESET}"

            # 启用了 obfs 时把混淆段追加到配置末尾（密码同样防 shell 展开原样写入）
            if [ -n "$obfs_type" ]; then
                cat >> /etc/hysteria/config.yaml <<EOF

obfs:
  type: $obfs_type
  $obfs_type:
    password: $(printf '%s' "$obfs_password")
EOF
                echo -e "${GREEN}已启用 obfs 混淆（类型 $obfs_type），客户端需填相同的混淆密码。${RESET}"
            fi

            # 配置端口跳跃 (使用 REDIRECT 模式)
            read -p "$(echo -e "${PINK}是否配置端口跳跃？(y/n): ${RESET}")" enable_hop
            if [ "$enable_hop" = "y" ] || [ "$enable_hop" = "Y" ]; then
                # 在配置端口跳跃前，自动检查并补全 iptables 相关插件
                check_and_install_iptables_tools

                read -p "$(echo -e "${PINK}请输入跳跃端口范围的起始端口 (例如 20000): ${RESET}")" START_PORT
                read -p "$(echo -e "${PINK}请输入跳跃端口范围的结束端口 (例如 40000): ${RESET}")" END_PORT
                read -p "$(echo -e "${PINK}请输入目标端口 (例如 9443): ${RESET}")" TARGET_PORT

                if [[ ! "$START_PORT" =~ ^[0-9]+$ || ! "$END_PORT" =~ ^[0-9]+$ || ! "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
                    echo -e "${PINK}输入无效，端口必须为数字。${RESET}"
                    exit 1
                fi

                if [[ "$START_PORT" -ge "$END_PORT" ]]; then
                    echo -e "${PINK}起始端口必须小于结束端口。${RESET}"
                    exit 1
                fi

                # 设置端口跳跃（精确删除旧跳跃规则后重加，v4/v6 一并处理，加完回显确认并持久化）
                echo -e "${GREEN}设置端口跳跃规则 ($START_PORT-$END_PORT -> $TARGET_PORT)...${RESET}"
                apply_hop_rules "$START_PORT" "$END_PORT" "$TARGET_PORT"
            fi

            # 配置自动更新
            setup_auto_update

            # 启动服务
            echo -e "${GREEN}启动 hysteria-server 服务...${RESET}"
            rc-service hysteria-server start

            # 检查服务状态
            if ! rc-service hysteria-server status | grep -q "started"; then
                echo -e "${PINK}Hysteria 服务未能成功启动。请检查配置或日志 (/var/log/hysteria.err)。${RESET}"
                exit 1
            fi

            echo -e "${GREEN}Hysteria 服务已成功启动！${RESET}"
            ;;

        2)
            echo -e "${GREEN}正在编辑 Hysteria 配置...${RESET}"
            nano /etc/hysteria/config.yaml

            echo -e "${GREEN}修改已保存，重启 Hysteria 服务...${RESET}"
            rc-service hysteria-server restart
            echo -e "${GREEN}Hysteria 服务已重启！${RESET}"
            ;;

        3)
            echo -e "${GREEN}当前 Hysteria 配置: ${RESET}"
            cat /etc/hysteria/config.yaml
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        4)
            echo -e "${GREEN}Hysteria 服务状态: ${RESET}"
            rc-service hysteria-server status
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        5)
            echo -e "${GREEN}重启 Hysteria 服务...${RESET}"
            rc-service hysteria-server restart
            echo -e "${GREEN}Hysteria 服务已重启！${RESET}"
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        6)
            echo -e "${GREEN}停止 Hysteria 服务...${RESET}"
            rc-service hysteria-server stop
            echo -e "${GREEN}Hysteria 服务已停止！${RESET}"
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        7)
            echo -e "${GREEN}查看 Hysteria 日志 (按 Ctrl+C 退出日志查看)...${RESET}"
            tail -n 50 -f /var/log/hysteria.log /var/log/hysteria.err 2>/dev/null
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        8)
            echo -e "${GREEN}正在检查并更新 Hysteria 核心...${RESET}"
            setup_hy2_installer
            /usr/local/bin/hy2-install.sh
            rc-service hysteria-server restart
            echo -e "${GREEN}更新完成，服务已重启！${RESET}"
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        9)
            echo -e "${PINK}正在卸载 Hysteria...${RESET}"
            rc-service hysteria-server stop 2>/dev/null
            rc-update del hysteria-server default 2>/dev/null
            # 先清端口跳跃规则再删配置：delete_hop_rules 要读配置里的监听端口来定位规则，
            # 配置先删掉就只能靠默认 9443 兜底，非 9443 的机器会漏删跳跃规则
            delete_hop_rules
            save_iptables_rules
            rm -f /etc/init.d/hysteria-server
            rm -rf /etc/hysteria/
            rm -f /usr/local/bin/hysteria
            rm -f /usr/local/bin/hy2-install.sh
            rm -f /usr/local/bin/hy2-autoupdate.sh
            rm -f /var/log/hysteria.log /var/log/hysteria.err
            crontab -l 2>/dev/null | grep -v "hy2-autoupdate.sh" | crontab -
            echo -e "${GREEN}Hysteria 已成功完全卸载！${RESET}"
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        10)
            check_and_install_iptables_tools
            setup_port_hopping
            ;;

        0)
            echo -e "${GREEN}退出...${RESET}"
            exit 0
            ;;

        *)
            echo -e "${PINK}无效选项，请输入 0 到 10 的数字。${RESET}"
            sleep 1
            ;;
    esac
done
