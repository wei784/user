#!/bin/bash

# ==============================================================================
# 脚本名称: auto_nginx_ssl.sh
# 脚本功能: 自动化配置 Nginx 反向代理并使用 Certbot 自动续期 SSL/TLS 证书
# 支持系统: Debian, Ubuntu, Alpine
# 作者: Gemini
# 版本: 1.3
# ==============================================================================

# --- 全局变量和颜色定义 ---
# 使用 tput 动态检测终端能力，更具可移植性
if tput setaf 1 > /dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    NC=$(tput sgr0) # No Color
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

# --- 辅助函数 ---

# 打印信息
print_info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# 打印成功信息
print_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

# 打印警告信息
print_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# 打印错误信息并退出
print_error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
    exit 1
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- 主要功能函数 ---

# 1. 权限检查
check_privileges() {
    print_info "正在检查脚本运行权限..."
    if [[ $(id -u) -ne 0 ]]; then
        print_error "此脚本需要以 root 用户或使用 sudo 权限运行。"
    fi
    print_success "权限检查通过。"
}

# 2. 系统检测
detect_os() {
    print_info "正在检测操作系统..."
    if [ -f /etc/os-release ]; then
        # freedesktop.org 和 systemd
        . /etc/os-release
        OS_ID=$ID
    elif type lsb_release >/dev/null 2>&1; then
        # a-la LSB
        OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    elif [ -f /etc/lsb-release ]; then
        # For some versions of Ubuntu without lsb_release command
        . /etc/lsb-release
        OS_ID=$DISTRIB_ID
    elif [ -f /etc/debian_version ]; then
        # Older Debian/Ubuntu/etc.
        OS_ID="debian"
    elif [ -f /etc/alpine-release ]; then
        OS_ID="alpine"
    else
        # Fallback to uname, e.g. "Linux <version>", also works for BSD, etc.
        OS_ID=$(uname -s)
    fi

    case "$OS_ID" in
        debian|ubuntu)
            OS_TYPE="debian"
            PKG_MANAGER="apt-get"
            NGINX_SERVICE="nginx"
            ;;
        alpine)
            OS_TYPE="alpine"
            PKG_MANAGER="apk"
            NGINX_SERVICE="nginx"
            ;;
        *)
            print_error "不支持的操作系统: $OS_ID"
            ;;
    esac
    print_success "检测到操作系统为: $OS_ID"
}

# 3. 安装依赖
install_dependencies() {
    print_info "正在检查并安装依赖..."
    local packages_to_install=""
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        local required_commands=("nginx" "certbot" "curl")
        local command_to_package=(
            ["nginx"]="nginx"
            ["certbot"]="certbot python3-certbot-nginx"
            ["curl"]="curl"
        )
        for cmd in "${required_commands[@]}"; do
            if ! command_exists "$cmd"; then
                packages_to_install+=" ${command_to_package[$cmd]}"
            fi
        done
        
        if [[ -n "$packages_to_install" ]]; then
            print_info "以下依赖将会被安装:$packages_to_install"
            $PKG_MANAGER update -y || print_error "更新软件包列表失败。"
            # shellcheck disable=SC2086
            $PKG_MANAGER install -y $packages_to_install || print_error "安装依赖包失败。"
        else
            print_success "所有依赖项均已安装。"
        fi

    elif [[ "$OS_TYPE" == "alpine" ]]; then
        local required_commands=("nginx" "certbot" "curl")
        for cmd in "${required_commands[@]}"; do
            if ! command_exists "$cmd"; then
                packages_to_install+=" $cmd"
            fi
        done
        
        if [[ -n "$packages_to_install" ]]; then
            print_info "以下依赖将会被安装:$packages_to_install"
            $PKG_MANAGER update || print_error "更新软件包列表失败。"
            # shellcheck disable=SC2086
            $PKG_MANAGER add $packages_to_install || print_error "安装依赖包失败。"
        else
            print_success "所有依赖项均已安装。"
        fi
    fi
    print_success "依赖检查与安装完成。"
}


# 4. 获取用户输入
get_user_input() {
    print_info "请输入以下配置信息:"
    
    # 获取域名
    while true; do
        read -p "请输入您的域名 (例如: sub.yourdomain.com): " DOMAIN
        if [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            # 检查域名解析
            local resolved_ip
            resolved_ip=$(curl -s "https://dns.google/resolve?name=$DOMAIN&type=A" | grep -o '"data":"[^"]*' | head -n1 | cut -d'"' -f4)
            local server_ip
            server_ip=$(curl -s ifconfig.me)
            if [[ "$resolved_ip" == "$server_ip" ]]; then
                print_success "域名 ($DOMAIN) 已成功解析到本机 IP ($server_ip)。"
                break
            else
                print_warning "域名 ($DOMAIN) 解析的 IP ($resolved_ip) 与本机 IP ($server_ip) 不匹配。"
                read -p "是否继续? (y/n): " choice
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    break
                fi
            fi
        else
            print_warning "域名格式无效，请重新输入。"
        fi
    done

    # 获取反向代理目标地址
    local protocol
    while true; do
        read -p "请选择反向代理目标的协议 [http/https] (默认: http): " protocol
        protocol=${protocol:-http} # 设置默认值为 http
        if [[ "$protocol" == "http" || "$protocol" == "https" ]]; then
            break
        else
            print_warning "输入无效，请输入 http 或 https。"
        fi
    done

    local address
    while true; do
        read -p "请输入反向代理的目标地址 (例如: 127.0.0.1:8080 或仅输入端口 8080): " address
        if [[ -n "$address" ]]; then
            # 检查是否只输入了端口号
            if [[ "$address" =~ ^[0-9]+$ ]]; then
                address="127.0.0.1:$address"
                print_info "检测到仅输入端口，已自动补全为: $address"
            fi
            break
        else
            print_warning "目标地址不能为空，请重新输入。"
        fi
    done
    
    PROXY_PASS="${protocol}://${address}"
    print_info "反向代理目标地址已设置为: ${PROXY_PASS}"

    # 获取邮箱
    while true; do
        read -p "请输入您的邮箱地址 (用于 Let's Encrypt 证书通知): " EMAIL
        if [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            print_warning "邮箱地址格式无效，请重新输入。"
        fi
    done
    
    # 询问是否以测试模式运行
    TEST_MODE="no"
    local test_choice
    read -p "是否以测试模式运行 Certbot (dry-run)? [y/N] (默认: N): " test_choice
    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        TEST_MODE="yes"
        print_info "Certbot 将以测试模式 (--dry-run) 运行。"
    else
        print_info "Certbot 将以生产模式运行。"
    fi
}


# 5. 申请 SSL 证书
request_ssl_certificate() {
    print_info "正在为域名 $DOMAIN 申请 SSL 证书..."
    
    local dry_run_flag=""
    if [[ "$TEST_MODE" == "yes" ]]; then
        dry_run_flag="--dry-run"
        print_info "执行 Certbot 测试运行 (dry-run)..."
    fi
    
    # 临时停止 Nginx 以释放 80 端口
    print_info "正在临时停止 Nginx 服务..."
    if [[ "$OS_TYPE" == "debian" ]]; then
        systemctl stop $NGINX_SERVICE
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        rc-service $NGINX_SERVICE stop
    fi

    # 使用 standalone 模式申请证书
    certbot certonly --standalone $dry_run_flag -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email -n
    
    if [[ $? -ne 0 ]]; then
        # 无论如何都尝试重启 Nginx
        print_info "尝试重启 Nginx 服务..."
        if [[ "$OS_TYPE" == "debian" ]]; then systemctl start $NGINX_SERVICE; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service $NGINX_SERVICE start; fi
        print_error "SSL 证书申请失败。请检查域名解析、防火墙设置 (80端口是否开放) 以及 Certbot 的输出日志。"
    fi
    
    if [[ "$TEST_MODE" == "yes" ]]; then
        print_success "Certbot 测试运行成功！"
        print_info "您的环境配置正确，可以正式申请证书。请在无测试模式下重新运行脚本。"
        print_info "正在重启 Nginx 服务..."
        if [[ "$OS_TYPE" == "debian" ]]; then systemctl start $NGINX_SERVICE; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service $NGINX_SERVICE start; fi
        exit 0
    fi

    print_success "SSL 证书已成功申请。"

    # FIX: 为续订配置添加 pre-hook 和 post-hook，以解决续订时的端口冲突问题
    print_info "正在为证书配置自动续订挂钩..."
    local renewal_conf="/etc/letsencrypt/renewal/${DOMAIN}.conf"
    
    if [ -f "$renewal_conf" ]; then
        local pre_hook_cmd
        local post_hook_cmd

        if [[ "$OS_TYPE" == "debian" ]]; then
            pre_hook_cmd="systemctl stop $NGINX_SERVICE"
            post_hook_cmd="systemctl start $NGINX_SERVICE"
        elif [[ "$OS_TYPE" == "alpine" ]]; then
            pre_hook_cmd="rc-service $NGINX_SERVICE stop"
            post_hook_cmd="rc-service $NGINX_SERVICE start"
        fi

        # 将钩子添加到 [renewalparams] 部分（如果它们尚不存在）
        if ! grep -q -E "^\s*pre_hook" "$renewal_conf"; then
            sed -i "/\[renewalparams\]/a pre_hook = $pre_hook_cmd" "$renewal_conf"
        fi
        
        if ! grep -q -E "^\s*post_hook" "$renewal_conf"; then
            sed -i "/\[renewalparams\]/a post_hook = $post_hook_cmd" "$renewal_conf"
        fi
        
        print_success "续订挂钩已成功配置。"
    else
        print_warning "找不到续订配置文件: $renewal_conf。自动续订可能需要手动配置挂钩。"
    fi
}

# 6. 配置 Nginx
configure_nginx() {
    print_info "正在生成 Nginx 配置文件..."
    
    local nginx_conf_path
    if [[ "$OS_TYPE" == "debian" ]]; then
        # For Debian/Ubuntu, use sites-available and sites-enabled
        nginx_conf_path="/etc/nginx/sites-available/${DOMAIN}.conf"
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        # For Alpine, place config directly in conf.d
        nginx_conf_path="/etc/nginx/http.d/${DOMAIN}.conf"
    fi

    # 使用 HEREDOC 生成配置文件
    cat > "$nginx_conf_path" << EOF
# ${DOMAIN} - Nginx Configuration
# Auto-generated by auto_nginx_ssl.sh

# HTTP to HTTPS Redirect
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # Allow Let's Encrypt challenges
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS Server Block
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    
    # Modern SSL security settings from Mozilla Intermediate configuration
    # https://ssl-config.mozilla.org/
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # 使用基于域名的唯一会话缓存区，避免多站点配置时冲突
    ssl_session_cache shared:SSL_${DOMAIN}:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # HSTS (optional, but recommended)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Reverse Proxy Configuration
    location / {
        proxy_pass ${PROXY_PASS};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # 启用配置 (仅 Debian/Ubuntu 需要)
    if [[ "$OS_TYPE" == "debian" ]]; then
        if [ -L "/etc/nginx/sites-enabled/${DOMAIN}.conf" ]; then
            print_warning "配置文件链接已存在，跳过创建链接。"
        else
            ln -s "$nginx_conf_path" "/etc/nginx/sites-enabled/"
        fi
    fi

    print_success "Nginx 配置文件已生成: ${nginx_conf_path}"

    # 测试 Nginx 配置
    print_info "正在测试 Nginx 配置..."
    nginx -t
    if [[ $? -ne 0 ]]; then
        print_error "Nginx 配置测试失败。请检查生成的配置文件。"
    fi
    print_success "Nginx 配置测试通过。"
}

# 7. 重启服务并验证
finalize_setup() {
    print_info "正在启动 Nginx 服务..."
    if [[ "$OS_TYPE" == "debian" ]]; then
        systemctl start $NGINX_SERVICE
        systemctl enable $NGINX_SERVICE
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        rc-service $NGINX_SERVICE start
        rc-update add $NGINX_SERVICE default
    fi
    print_success "Nginx 服务已启动。"

    print_info "正在测试证书自动续期功能..."
    certbot renew --dry-run
    if [[ $? -ne 0 ]]; then
        print_warning "证书续期干预性测试（dry-run）失败。但这不一定代表真实续期会失败。请关注您的邮箱通知。"
    else
        print_success "证书自动续期配置正常。"
    fi
}

# --- 脚本主入口 ---
main() {
    clear
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}  Nginx & Certbot 一键反代与 SSL 证书自动化脚本  ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo

    check_privileges
    detect_os
    install_dependencies
    get_user_input
    request_ssl_certificate
    configure_nginx
    finalize_setup

    echo
    print_success "所有操作已成功完成!"
    echo "-----------------------------------------------------"
    echo -e "您的网站 ${YELLOW}${DOMAIN}${NC} 现已配置完成并通过 HTTPS 访问。"
    echo -e "Nginx 将流量反向代理到: ${YELLOW}${PROXY_PASS}${NC}"
    if [[ "$OS_TYPE" == "debian" ]]; then
        echo -e "Nginx 配置文件位于: ${YELLOW}/etc/nginx/sites-available/${DOMAIN}.conf${NC}"
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        echo -e "Nginx 配置文件位于: ${YELLOW}/etc/nginx/http.d/${DOMAIN}.conf${NC}"
    fi
    echo -e "SSL 证书文件位于: ${YELLOW}/etc/letsencrypt/live/${DOMAIN}/${NC}"
    echo "-----------------------------------------------------"
    echo
}

# 执行 main 函数
main

