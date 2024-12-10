#!/bin/bash

# 设置变量
INSTALL_PATH="/usr/local/frp"
SERVICE_PATH="/etc/systemd/system"
MANAGER_PATH="/usr/local/bin/frpc_manager.sh"

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ] && [ "$USER" != "root" ]; then 
    echo "请使用root权限运行此脚本"
    exit 1
fi

# 创建管理脚本
create_manager_script() {
    cat > "$MANAGER_PATH" << 'EEOF'
#!/bin/bash

# 配置文件路径
INSTALL_PATH="/usr/local/frp"
CONFIG_FILE="$INSTALL_PATH/frpc.toml"

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ] && [ "$USER" != "root" ]; then 
    echo "请使用root权限运行此脚本"
    exit 1
fi

# 检查frp是否已安装
if [ ! -f "$CONFIG_FILE" ]; then
    echo "未检测到frp配置文件，请先运行安装脚本"
    exit 1
fi

# 显示当前配置
show_current_config() {
    echo "当前配置信息："
    echo "------------------------"
    echo "服务器信息："
    grep "serverAddr" "$CONFIG_FILE" | head -n 1
    grep "serverPort" "$CONFIG_FILE" | head -n 1
    grep "auth.token" "$CONFIG_FILE" | head -n 1
    echo ""
    echo "代理规则："
    grep -A 5 "^\[\[proxies\]\]" "$CONFIG_FILE"
    echo "------------------------"
}

# 添加新规则
add_new_rule() {
    echo "添加新的代理规则"
    echo "请选择代理类型:"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) HTTP"
    echo "4) HTTPS"
    read -r proxy_type_num
    
    case $proxy_type_num in
        1) proxy_type="tcp";;
        2) proxy_type="udp";;
        3) proxy_type="http";;
        4) proxy_type="https";;
        *) echo "无效选择，使用 tcp"; proxy_type="tcp";;
    esac
    
    echo "请输入代理规则名称 (例如: ssh, web等):"
    read -r proxy_name
    
    # 检查规则名称是否为空
    if [ -z "$proxy_name" ]; then
        echo "错误: 规则名称不能为空"
        return 1
    fi
    
    # 检查规则名是否已存在
    if grep -q "name = \"$proxy_name\"" "$CONFIG_FILE"; then
        echo "错误: 规则名称已存在"
        return 1
    fi
    
    echo "请输入本地IP (默认: 127.0.0.1):"
    read -r local_ip
    local_ip=${local_ip:-127.0.0.1}
    
    echo "请输入本地端口:"
    read -r local_port
    
    # 检查本地端口是否为空或非数字
    if [ -z "$local_port" ] || ! [[ "$local_port" =~ ^[0-9]+$ ]]; then
        echo "错误: 本地端口必须是有效的数字"
        return 1
    fi
    
    if [ "$proxy_type" = "tcp" ] || [ "$proxy_type" = "udp" ]; then
        echo "请输入远程端口 (供外网访问的端口):"
        read -r remote_port
        
        # 检查远程端口是否为空或非数字
        if [ -z "$remote_port" ] || ! [[ "$remote_port" =~ ^[0-9]+$ ]]; then
            echo "错误: 远程端口必须是有效的数字"
            return 1
        fi
        
        cat >> "$CONFIG_FILE" << EOF

[[proxies]]
name = "${proxy_name}"
type = "${proxy_type}"
localIP = "${local_ip}"
localPort = ${local_port}
remotePort = ${remote_port}
EOF
    else
        echo "请输入域名 (例如: web.example.com):"
        read -r custom_domain
        
        # 检查域名是否为空
        if [ -z "$custom_domain" ]; then
            echo "错误: 域名不能为空"
            return 1
        fi
        
        cat >> "$CONFIG_FILE" << EOF

[[proxies]]
name = "${proxy_name}"
type = "${proxy_type}"
localIP = "${local_ip}"
localPort = ${local_port}
customDomains = ["${custom_domain}"]
EOF
    fi
    
    echo "规则添加成功！"
    systemctl restart frpc
    echo "服务已重启"
}

# 删除规则
delete_rule() {
    echo "当前配置的规则："
    grep "name = " "$CONFIG_FILE" | nl
    
    if [ $? -ne 0 ]; then
        echo "没有找到任何代理规则"
        return 1
    fi
    
    echo "请输入要删除的规则序号:"
    read -r rule_number
    
    if ! [[ "$rule_number" =~ ^[0-9]+$ ]]; then
        echo "错误: 请输入有效的数字"
        return 1
    fi
    
    # 获取规则名称
    rule_name=$(grep "name = " "$CONFIG_FILE" | sed -n "${rule_number}p" | cut -d'"' -f2)
    
    if [ -z "$rule_name" ]; then
        echo "错误: 未找到指定的规则"
        return 1
    fi
    
    # 创建临时文件
    temp_file=$(mktemp)
    
    # 删除选中的规则块
    awk -v name="$rule_name" '
    /\[\[proxies\]\]/ {
        buf = $0 ORS
        inside = 1
        next
    }
    inside {
        buf = buf $0 ORS
        if ($0 ~ "^$") {
            if (buf !~ "name = \"" name "\"") 
                printf "%s", buf
            buf = ""
            inside = 0
        }
        next
    }
    { print }' "$CONFIG_FILE" > "$temp_file"
    
    # 替换原文件
    mv "$temp_file" "$CONFIG_FILE"
    
    echo "规则 '$rule_name' 已删除"
    systemctl restart frpc
    echo "服务已重启"
}

# 修改服务器配置
modify_server_config() {
    echo "当前服务器配置："
    grep "serverAddr" "$CONFIG_FILE" | head -n 1
    grep "serverPort" "$CONFIG_FILE" | head -n 1
    grep "auth.token" "$CONFIG_FILE" | head -n 1
    
    echo "请输入新的服务器地址 (留空保持不变):"
    read -r new_server_addr
    
    echo "请输入新的服务器端口 (留空保持不变):"
    read -r new_server_port
    
    echo "请输入新的认证令牌 (留空保持不变):"
    read -r new_token
    
    # 创建临时文件
    temp_file=$(mktemp)
    
    # 更新配置
    while IFS= read -r line; do
        if [[ -n "$new_server_addr" ]] && [[ "$line" =~ ^serverAddr ]]; then
            echo "serverAddr = \"$new_server_addr\""
        elif [[ -n "$new_server_port" ]] && [[ "$line" =~ ^serverPort ]]; then
            echo "serverPort = $new_server_port"
        elif [[ -n "$new_token" ]] && [[ "$line" =~ ^auth.token ]]; then
            echo "auth.token = \"$new_token\""
        else
            echo "$line"
        fi
    done < "$CONFIG_FILE" > "$temp_file"
    
    # 替换原文件
    mv "$temp_file" "$CONFIG_FILE"
    
    echo "服务器配置已更新"
    systemctl restart frpc
    echo "服务已重启"
}

# 主菜单
while true; do
    echo ""
    echo "frpc 配置管理工具"
    echo "------------------------"
    echo "1) 显示当前配置"
    echo "2) 添加新规则"
    echo "3) 删除规则"
    echo "4) 修改服务器配置"
    echo "5) 查看服务状态"
    echo "6) 查看服务日志"
    echo "0) 退出"
    echo "------------------------"
    echo "请选择操作:"
    read -r choice
    
    case $choice in
        1) show_current_config;;
        2) add_new_rule;;
        3) delete_rule;;
        4) modify_server_config;;
        5) systemctl status frpc;;
        6) journalctl -u frpc -f;;
        0) exit 0;;
        *) echo "无效选择";;
    esac
done
EEOF

    chmod +x "$MANAGER_PATH"
    echo "管理工具已创建：$MANAGER_PATH"
}

# 检查是否已安装
check_installation() {
    local need_manager=0
    
    if [ ! -f "$MANAGER_PATH" ]; then
        need_manager=1
    fi
    
    if [ -f "$INSTALL_PATH/frpc" ] && [ -f "$SERVICE_PATH/frpc.service" ]; then
        echo "检测到已安装 frpc"
        if systemctl is-active --quiet frpc; then
            echo "frpc 服务正在运行"
            if [ $need_manager -eq 1 ]; then
                echo "未检测到管理工具，将为您创建..."
                create_manager_script
                echo "管理工具已创建，您可以使用以下命令管理frpc："
                echo "frpc_manager.sh"
            else
                echo "如果需要重新配置，请使用管理工具："
                echo "frpc_manager.sh"
            fi
            exit 0
        else
            echo "frpc 已安装但服务未运行"
            echo "是否要重新安装？(y/n)"
            read -r reinstall
            if [ "$reinstall" != "y" ]; then
                if [ $need_manager -eq 1 ]; then
                    echo "未检测到管理工具，将为您创建..."
                    create_manager_script
                    echo "管理工具已创建，您可以使用以下命令管理frpc："
                fi
                echo "请使用管理工具配置和启动服务："
                echo "frpc_manager.sh"
                exit 0
            fi
        fi
    fi
}

# 定义启动和检查服务的函数
start_and_check_service() {
    echo "正在启动 frpc 服务..."
    systemctl start frpc
    
    # 等待服务启动
    sleep 2
    
    # 检查服务状态
    if ! systemctl is-active --quiet frpc; then
        echo "警告: frpc 服务未能正常启动"
        echo "查看详细错误信息："
        systemctl status frpc
        journalctl -u frpc -n 50 --no-pager
        exit 1
    fi
    
    echo "frpc 服务已启动"
}

# 配置函数
configure_frpc() {
    echo "开始配置 frpc..."
    echo "请输入 frp 服务器地址 (例如: frp.example.com):"
    read -r server_addr
    
    # 检查服务器地址是否为空
    if [ -z "$server_addr" ]; then
        echo "错误: 服务器地址不能为空"
        exit 1
    fi
    
    echo "请输入 frp 服务器端口 (默认: 7000):"
    read -r server_port
    server_port=${server_port:-7000}
    
    echo "请输入认证令牌 (token):"
    read -r auth_token
    
    # 检查认证令牌是否为空
    if [ -z "$auth_token" ]; then
        echo "错误: 认证令牌不能为空"
        exit 1
    fi
    
    # 创建基础配置
    cat > $INSTALL_PATH/frpc.toml << EOF
serverAddr = "${server_addr}"
serverPort = ${server_port}

auth.method = "token"
auth.token = "${auth_token}"

# 添加日志配置
log.to = "console"
log.level = "info"
log.maxDays = 3

EOF
}

# 主安装流程开始

# 首先检查是否已安装
check_installation

# 检查必要的命令
command -v curl >/dev/null 2>&1 || { echo "需要 curl 命令，请先安装"; exit 1; }
command -v wget >/dev/null 2>&1 || { echo "需要 wget 命令，请先安装"; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "需要 tar 命令，请先安装"; exit 1; }

# 创建安装目录
mkdir -p $INSTALL_PATH

# 获取最新版本号
echo "正在获取最新版本信息..."
latest_version=$(curl -s "https://api.github.com/repos/fatedier/frp/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')

if [ -z "$latest_version" ]; then
    echo "获取版本号失败，尝试使用备用API地址..."
    latest_version=$(curl -s "https://ghp.ci/https://api.github.com/repos/fatedier/frp/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
fi

if [ -z "$latest_version" ]; then
    echo "无法获取最新版本号"
    exit 1
fi

version=${latest_version#v}  # 移除版本号中的 'v' 前缀
echo "检测到最新版本: ${latest_version} (${version})"

# 下载并解压
DOWNLOAD_URL="https://ghp.ci/https://github.com/fatedier/frp/releases/download/${latest_version}/frp_${version}_linux_amd64.tar.gz"
echo "正在下载 frp ${latest_version}..."
wget --no-check-certificate -O /tmp/frp.tar.gz "$DOWNLOAD_URL" || {
    echo "下载失败，尝试使用备用地址..."
    BACKUP_URL="https://mirror.ghproxy.com/https://github.com/fatedier/frp/releases/download/${latest_version}/frp_${version}_linux_amd64.tar.gz"
    wget --no-check-certificate -O /tmp/frp.tar.gz "$BACKUP_URL" || {
        echo "下载失败，请检查网络连接"
        exit 1
    }
}

echo "正在解压文件..."
tar -xzf /tmp/frp.tar.gz -C /tmp || {
    echo "解压失败"
    exit 1
}

# 复制文件
cp -f "/tmp/frp_${version}_linux_amd64/frpc" "$INSTALL_PATH/"

# 运行配置向导
configure_frpc

# 创建系统服务
cat > $SERVICE_PATH/frpc.service << EOF
[Unit]
Description=frp Client Service
After=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
ExecStart=$INSTALL_PATH/frpc -c $INSTALL_PATH/frpc.toml

[Install]
WantedBy=multi-user.target
EOF

# 设置权限
chmod +x $INSTALL_PATH/frpc

# 启用并启动服务
systemctl daemon-reload
systemctl enable frpc
start_and_check_service

# 创建管理脚本（如果不存在）
if [ ! -f "$MANAGER_PATH" ]; then
    create_manager_script
fi

# 清理临时文件
rm -f /tmp/frp.tar.gz
rm -rf "/tmp/frp_${version}_linux_amd64"

echo "安装完成！"
echo "配置文件位置：$INSTALL_PATH/frpc.toml"
echo ""
echo "管理命令："
echo "运行 'frpc_manager.sh' 来管理frpc配置"
