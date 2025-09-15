#!/bin/sh

# ==============================================================================
# 脚本名称: auto_nginx_ssl.sh
# 脚本功能: 自动化配置、管理 Nginx 反向代理及 Certbot SSL 证书
# 支持系统: Debian, Ubuntu, Alpine (POSIX sh 兼容)
# 作者: Gemini 2.5 Pro
# 版本: 1.2.2
# ==============================================================================

# --- 全局变量和颜色定义 ---
CONF_FILE="/etc/auto_nginx_ssl.conf" # 用于存储上次使用的邮箱

if tput setaf 1 > /dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    NC=$(tput sgr0)
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

# --- 辅助函数 ---
print_info() { printf '%b\n' "${BLUE}[INFO] $1${NC}"; }
print_success() { printf '%b\n' "${GREEN}[SUCCESS] $1${NC}"; }
print_warning() { printf '%b\n' "${YELLOW}[WARNING] $1${NC}"; }
print_error() { printf '%b\n' "${RED}[ERROR] $1${NC}" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# 获取 Nginx 版本号
get_nginx_version() {
    nginx -v 2>&1 | grep "nginx version" | sed 's#^.*/##'
}

# 比较版本号，如果 $1 < $2 则返回 0 (true)
version_lt() {
    [ "$1" = "$2" ] && return 1
    [ "$1" = "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n 1)" ]
}

# --- 初始化和环境检查 ---
check_privileges() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "此脚本需要以 root 用户或使用 sudo 权限运行。"
    fi
}

detect_os() {
    local OS_ID=""
    if [ -f /etc/os-release ]; then . /etc/os-release; OS_ID=$ID;
    elif type lsb_release >/dev/null 2>&1; then OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]');
    elif [ -f /etc/debian_version ]; then OS_ID="debian";
    elif [ -f /etc/alpine-release ]; then OS_ID="alpine";
    else OS_ID=$(uname -s); fi

    case "$OS_ID" in
        debian|ubuntu) OS_TYPE="debian"; PKG_MANAGER="apt-get"; NGINX_SERVICE="nginx";;
        alpine) OS_TYPE="alpine"; PKG_MANAGER="apk"; NGINX_SERVICE="nginx";;
        *) print_error "不支持的操作系统: $OS_ID";;
    esac
}

install_dependencies() {
    local packages_to_install=""
    local required_commands="nginx curl openssl"
    local cmd
    print_info "正在检查并安装依赖..."
    
    for cmd in $required_commands; do
        if ! command_exists "$cmd"; then
            packages_to_install="$packages_to_install $cmd"
        fi
    done

    if [ "$OS_TYPE" = "debian" ]; then
        if ! command_exists "certbot"; then
             packages_to_install="$packages_to_install certbot"
        fi
        if ! dpkg-query -W -f='${Status}' python3-certbot-nginx 2>/dev/null | grep -q "ok installed"; then
            packages_to_install="$packages_to_install python3-certbot-nginx"
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        if ! command_exists "certbot"; then
             packages_to_install="$packages_to_install certbot"
        fi
        if ! apk info -e certbot-nginx >/dev/null 2>&1; then
            packages_to_install="$packages_to_install certbot-nginx"
        fi
    fi

    packages_to_install=$(echo "$packages_to_install" | sed 's/^ *//')
    if [ -n "$packages_to_install" ]; then
        print_info "以下依赖将会被安装: $packages_to_install"
        if [ "$OS_TYPE" = "debian" ]; then
            $PKG_MANAGER update -y || print_error "更新软件包列表失败。"
            # shellcheck disable=SC2086
            $PKG_MANAGER install -y $packages_to_install || print_error "安装依赖包失败。"
        else
            $PKG_MANAGER update || print_error "更新软件包列表失败。"
            # shellcheck disable=SC2086
            $PKG_MANAGER add $packages_to_install || print_error "安装依赖包失败。"
        fi
    else
        print_success "所有依赖项均已安装。"
    fi
}

disable_default_nginx_site() {
    if [ "$OS_TYPE" = "debian" ]; then
        if [ -L /etc/nginx/sites-enabled/default ]; then
            print_info "正在禁用 Debian/Ubuntu 的默认 Nginx 站点..."
            rm -f /etc/nginx/sites-enabled/default
            print_success "已禁用默认 Nginx 站点。"
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        if [ -f /etc/nginx/http.d/default.conf ]; then
            print_info "正在禁用 Alpine 的默认 Nginx 站点..."
            mv /etc/nginx/http.d/default.conf /etc/nginx/http.d/default.conf.bak
            print_success "已禁用默认 Nginx 站点。"
        fi
    fi
}

# --- 网络检查函数 ---
get_server_ip() {
    local ip_services="ifconfig.me ip.sb api.ipify.org ipinfo.io/ip"
    local service
    local ip
    for service in $ip_services; do
        ip=$(curl -s --connect-timeout 3 "$service")
        if echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

get_resolved_ip() {
    local domain="$1"
    local doh_services="https://dns.google/resolve https://dns.alidns.com/resolve"
    local service
    local resolved_ip
    for service in $doh_services; do
        resolved_ip=$(curl -s --max-time 1 "${service}?name=$domain&type=A" | grep -o '"data":"[^"]*' | head -n1 | cut -d'"' -f4)
        if [ -n "$resolved_ip" ]; then
            echo "$resolved_ip"
            return 0
        fi
    done
    return 1
}

check_port_80() {
    print_info "正在检查 80 端口是否被占用..."
    if command_exists ss; then
        if ss -tlpn | grep -q ':80 '; then
            print_warning "检测到 80 端口已被占用。请先停止占用该端口的服务。"
            ss -tlpn | grep ':80 '
            return 1
        fi
    elif command_exists netstat; then
        if netstat -tlpn | grep -q ':80 '; then
            print_warning "检测到 80 端口已被占用。请先停止占用该端口的服务。"
            netstat -tlpn | grep ':80 '
            return 1
        fi
    else
        print_warning "无法检测端口占用情况 (缺少 ss 或 netstat 命令)。"
    fi
    print_success "80 端口可供使用。"
    return 0
}

is_nginx_running() {
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl is-active --quiet "$NGINX_SERVICE"
        return $?
    elif [ "$OS_TYPE" = "alpine" ]; then
        rc-service "$NGINX_SERVICE" status >/dev/null 2>&1
        if [ $? -eq 0 ]; then return 0; else return 1; fi
    fi
    return 1
}

# --- 核心 Nginx & Certbot 操作 ---
apply_nginx_config() {
    local nginx_reload_output
    local start_output
    
    if is_nginx_running; then
        print_info "正在重新加载 Nginx 配置..."
        nginx_reload_output=$(nginx -s reload 2>&1)
        if [ $? -eq 0 ]; then
            print_success "Nginx 配置已成功重新加载。"
            return 0
        else
            printf '%b\n' "${RED}[ERROR] Nginx 重载失败！${NC}" >&2
            printf "\n--- Nginx 错误信息 ---\n%s\n-----------------------\n" "$nginx_reload_output" >&2
            return 1
        fi
    else
        print_warning "Nginx 未在运行，尝试启动..."
        if ! check_port_80; then return 1; fi
        
        start_output=""
        if [ "$OS_TYPE" = "debian" ]; then
            systemctl start "$NGINX_SERVICE" >/dev/null 2>&1
        elif [ "$OS_TYPE" = "alpine" ]; then
            rc-service "$NGINX_SERVICE" start >/dev/null 2>&1
        fi

        if is_nginx_running; then
            print_success "Nginx 已成功启动。"
            return 0
        else
            printf '%b\n' "${RED}[ERROR] Nginx 启动失败！${NC}" >&2
            if [ -n "$start_output" ]; then
                printf "\n--- Nginx 错误信息 ---\n%s\n-----------------------\n" "$start_output" >&2
            fi
            return 1
        fi
    fi
}

create_new_proxy() {
    disable_default_nginx_site
    if ! get_user_input; then
        print_info "用户取消输入，操作中止。"
        return
    fi
    
    if ! is_nginx_running; then
        if ! check_port_80; then
            print_error "端口检查失败，无法继续。"
        fi
    fi
    
    configure_nginx_http
    
    local nginx_test_output
    local nginx_conf_path
    nginx_test_output=$(nginx -t 2>&1)
    if [ $? -ne 0 ]; then
        printf '%b\n' "${RED}[ERROR] 生成的初始 Nginx HTTP 配置无效！${NC}" >&2
        printf "\n--- Nginx 错误信息 ---\n%s\n-----------------------\n" "$nginx_test_output" >&2
        
        print_warning "正在清理无效的配置文件..."
        if [ "$OS_TYPE" = "debian" ]; then 
            nginx_conf_path="/etc/nginx/sites-available/${PRIMARY_DOMAIN}.conf"
            rm -f "/etc/nginx/sites-enabled/${PRIMARY_DOMAIN}.conf"
        else 
            nginx_conf_path="/etc/nginx/http.d/${PRIMARY_DOMAIN}.conf"
        fi
        rm -f "$nginx_conf_path"
        print_warning "清理完成。"
        return 1
    fi

    if ! apply_nginx_config; then
        print_warning "应用初始 Nginx HTTP 配置失败，正在清理残留文件..."
        if [ "$OS_TYPE" = "debian" ]; then 
             nginx_conf_path="/etc/nginx/sites-available/${PRIMARY_DOMAIN}.conf"
             rm -f "/etc/nginx/sites-enabled/${PRIMARY_DOMAIN}.conf"
        else 
             nginx_conf_path="/etc/nginx/http.d/${PRIMARY_DOMAIN}.conf"
        fi
        rm -f "$nginx_conf_path"
        print_error "应用初始 Nginx HTTP 配置失败，操作已中止并清理。"
    fi

    if request_ssl_certificate; then
        enable_hsts_prompt
        print_info "正在测试证书自动续期功能...";
        if ! certbot renew --dry-run --cert-name "$PRIMARY_DOMAIN"; then
            print_warning "针对 ${PRIMARY_DOMAIN} 的续期测试失败。但这不影响当前证书使用。"
        else
            print_success "证书自动续期配置正常。"
        fi

        printf '\n'; print_success "所有操作已成功完成!"
        printf '%b\n' "-----------------------------------------------------"
        printf '%b\n' "您的网站 ${YELLOW}${PRIMARY_DOMAIN}${NC} 现已配置完成并通过 HTTPS 访问。"
        printf '%b\n' "Nginx 将流量反向代理到: ${YELLOW}${PROXY_PASS}${NC}"
        if [ "$OS_TYPE" = "debian" ]; then
            printf '%b\n' "Nginx 配置文件位于: ${YELLOW}/etc/nginx/sites-available/${PRIMARY_DOMAIN}.conf${NC}"
        else
            printf '%b\n' "Nginx 配置文件位于: ${YELLOW}/etc/nginx/http.d/${PRIMARY_DOMAIN}.conf${NC}"
        fi
        printf '%b\n' "SSL 证书文件位于: ${YELLOW}/etc/letsencrypt/live/${PRIMARY_DOMAIN}/${NC}"
        printf '%b\n' "-----------------------------------------------------"; printf '\n'
    else
        print_info "SSL 证书申请失败或已取消，正在清理初始配置..."
        if [ "$OS_TYPE" = "debian" ]; then 
             nginx_conf_path="/etc/nginx/sites-available/${PRIMARY_DOMAIN}.conf"
             rm -f "/etc/nginx/sites-enabled/${PRIMARY_DOMAIN}.conf"
        else 
             nginx_conf_path="/etc/nginx/http.d/${PRIMARY_DOMAIN}.conf"
        fi
        rm -f "$nginx_conf_path"
        
        apply_nginx_config || print_warning "重新加载 Nginx 配置失败，可能需要手动检查。"
        print_info "操作已中止，并已清理残留的 HTTP 配置。"
    fi
}

get_user_input() {
    local nginx_conf_path
    local choice
    local server_ip
    local resolved_ip
    local protocol
    local address
    local original_address
    local port
    local last_email
    local all_domains_valid
    local domain
    
    print_info "请输入以下配置信息:"
    while true; do
        printf "请输入您的域名 (多个域名请用空格分隔，输入 'q' 退出):\n(例如: yourdomain.com www.yourdomain.com): "; read -r ALL_DOMAINS_STR
        
        if [ "$ALL_DOMAINS_STR" = "q" ]; then return 1; fi
        if [ -z "$ALL_DOMAINS_STR" ]; then print_warning "域名不能为空，请重新输入。"; continue; fi
        
        all_domains_valid=1
        for domain in $ALL_DOMAINS_STR; do
            if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
                print_warning "域名 '$domain' 格式无效，请重新输入所有域名。"
                all_domains_valid=0
                break
            fi
        done
        if [ "$all_domains_valid" -eq 0 ]; then continue; fi

        PRIMARY_DOMAIN=$(echo "$ALL_DOMAINS_STR" | awk '{print $1}')
        
        if [ "$OS_TYPE" = "debian" ]; then nginx_conf_path="/etc/nginx/sites-available/${PRIMARY_DOMAIN}.conf"; 
        else nginx_conf_path="/etc/nginx/http.d/${PRIMARY_DOMAIN}.conf"; fi

        if [ -f "$nginx_conf_path" ]; then
            print_warning "主域名 ${PRIMARY_DOMAIN} 的配置已存在。"
            printf "请选择操作: 1) 覆盖现有配置 2) 重新输入域名 [1-2]: "
            read -r choice
            case "$choice" in
                1) ;;
                2) continue ;;
                *) print_warning "无效选择，请重新输入域名。"; continue ;;
            esac
        fi

        server_ip=$(get_server_ip)
        if [ -z "$server_ip" ]; then
            print_warning "无法自动获取服务器公网IP。请手动确认您的域名解析正确。"
        else
            print_info "正在验证所有域名的 DNS A 记录..."
            all_domains_valid=1
            for domain in $ALL_DOMAINS_STR; do
                resolved_ip=$(get_resolved_ip "$domain")
                if [ "$resolved_ip" = "$server_ip" ]; then
                    print_success "域名 ($domain) -> ${GREEN}匹配${NC} ($server_ip)"
                else
                    print_warning "域名 ($domain) -> ${RED}不匹配${NC} (解析到: $resolved_ip, 需要: $server_ip)"
                    all_domains_valid=0
                fi
            done
            
            if [ "$all_domains_valid" -eq 0 ]; then
                printf "一个或多个域名解析不正确。是否继续? (y/n): "
                read -r choice
                case "$choice" in
                    [Yy]) ;;
                    *) continue ;;
                esac
            fi
        fi
        break
    done
    
    while true; do
        printf "请选择反向代理目标的协议 [http/https] (默认: http): "; read -r protocol; protocol=${protocol:-http}
        if [ "$protocol" = "http" ] || [ "$protocol" = "https" ]; then break; else print_warning "输入无效，请输入 http 或 https。"; fi
    done
    
    while true; do
        printf "请输入反向代理的目标地址 (例如: 127.0.0.1:8080 或仅输入端口 8080): "; read -r address
        if [ -z "$address" ]; then print_warning "目标地址不能为空。"; continue; fi
        original_address="$address"
        if echo "$address" | grep -qE '^[0-9]+$'; then address="127.0.0.1:$address"; fi
        port=$(echo "$address" | sed 's/.*://')
        if ! echo "$port" | grep -qE '^[0-9]+$'; then print_warning "地址格式 '$original_address' 无效。"; continue; fi
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then print_warning "端口号 '$port' 无效 (1-65535)。"; continue; fi
        if echo "$original_address" | grep -qE '^[0-9]+$'; then print_info "自动补全为: $address"; fi
        break
    done
    
    PROXY_PASS="${protocol}://${address}"; print_info "反向代理目标地址已设置为: ${PROXY_PASS}"
    
    last_email=""; if [ -f "$CONF_FILE" ]; then last_email=$(cat "$CONF_FILE"); fi
    while true; do
        if [ -n "$last_email" ]; then printf "请输入您的邮箱地址 [默认: %s]: " "$last_email"; else printf "请输入您的邮箱地址: "; fi
        read -r EMAIL; EMAIL=${EMAIL:-$last_email}
        if echo "$EMAIL" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
            echo "$EMAIL" > "$CONF_FILE" || print_warning "无法保存邮箱地址到 $CONF_FILE"; break
        else print_warning "邮箱地址格式无效。"; fi
    done
    return 0
}

configure_nginx_http() {
    local nginx_conf_path
    print_info "正在生成初始 Nginx HTTP 配置文件..."
    if [ "$OS_TYPE" = "debian" ]; then nginx_conf_path="/etc/nginx/sites-available/${PRIMARY_DOMAIN}.conf"; else nginx_conf_path="/etc/nginx/http.d/${PRIMARY_DOMAIN}.conf"; fi
    
    cat > "$nginx_conf_path" << EOF
# ${PRIMARY_DOMAIN} - Nginx Configuration
# Auto-generated by auto_nginx_ssl.sh
server {
    listen 80;
    listen [::]:80;
    server_name ${ALL_DOMAINS_STR};
    location / {
        proxy_pass ${PROXY_PASS};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    if [ "$OS_TYPE" = "debian" ]; then
        if [ ! -L "/etc/nginx/sites-enabled/${PRIMARY_DOMAIN}.conf" ]; then ln -s "$nginx_conf_path" "/etc/nginx/sites-enabled/"; fi
    fi
    print_success "Nginx HTTP 配置文件已生成: ${nginx_conf_path}"
}

request_ssl_certificate() {
    local certbot_domain_flags=""
    local domain
    local choice
    
    print_info "为域名 $ALL_DOMAINS_STR 准备申请 SSL 证书..."
    for domain in $ALL_DOMAINS_STR; do certbot_domain_flags="$certbot_domain_flags -d $domain"; done

    printf "是否先执行一次安全的证书申请测试 (dry-run)? (y/N): "; read -r choice
    case "$choice" in
        [Yy])
            print_info "正在执行证书申请测试 (dry-run)..."
            # shellcheck disable=SC2086
            if ! certbot certonly --nginx --dry-run --cert-name "$PRIMARY_DOMAIN" $certbot_domain_flags --email "$EMAIL" --agree-tos --no-eff-email -n --keep-until-expiring; then
                print_warning "证书申请测试失败。请检查 Certbot 输出的错误信息。"
                return 1
            fi
            print_success "证书申请测试成功！"

            printf "是否立即为以上域名申请证书? (Y/n): "; read -r choice
            case "$choice" in
                [Nn]) return 1 ;;
                *) ;;
            esac
            ;;
        *)
            ;;
    esac

    print_info "正在申请 SSL 证书 (服务将自动重载)..."
    # shellcheck disable=SC2086
    if ! certbot --nginx --cert-name "$PRIMARY_DOMAIN" $certbot_domain_flags --email "$EMAIL" --agree-tos --no-eff-email -n --keep-until-expiring --redirect; then
        print_warning "证书申请失败。Certbot 会尝试恢复 Nginx 配置。"
        return 1
    fi
    print_success "SSL 证书已成功申请并配置！"
    return 0
}

# --- 功能二: 管理已有配置 ---
get_all_proxy_domains() {
    local nginx_conf_dir=""
    local domain_list=""
    local conf_file
    local domain
    if [ "$OS_TYPE" = "debian" ]; then nginx_conf_dir="/etc/nginx/sites-available";
    else nginx_conf_dir="/etc/nginx/http.d"; fi
    
    for conf_file in $(find "$nginx_conf_dir" -type f \( -name "*.conf" -o -name "*.conf.disabled" \) 2>/dev/null); do
        if grep -q "Auto-generated by auto_nginx_ssl.sh" "$conf_file"; then
            domain=$(basename "$conf_file" .conf)
            domain=$(basename "$domain" .conf.disabled)
            case " $domain_list " in *" $domain "*) ;; *) domain_list="$domain_list $domain" ;; esac
        fi
    done

    echo "$domain_list" | sed 's/^ *//'
}

manage_proxies_menu() {
    local domain_list
    local count
    local domain
    local status_text
    local is_active
    local choice
    local selected_domain
    while true; do
        clear; print_info "管理已有的反向代理配置"
        domain_list=$(get_all_proxy_domains)
        if [ -z "$domain_list" ]; then
            printf "\n没有找到由本脚本创建的配置。\n\n按 Enter 键返回主菜单..."; read -r _; break
        fi
        
        count=0
        for domain in $domain_list; do
            count=$((count + 1))
            is_active=0
            if [ "$OS_TYPE" = "debian" ]; then
                if [ -L "/etc/nginx/sites-enabled/$domain.conf" ]; then is_active=1; fi
            else
                if [ -f "/etc/nginx/http.d/$domain.conf" ]; then is_active=1; fi
            fi
            if [ "$is_active" -eq 1 ]; then status_text="${GREEN}(运行中)${NC}"; else status_text="${YELLOW}(已暂停)${NC}"; fi
            printf "  %s) %-30s %b\n" "$count" "$domain" "$status_text"
        done

        printf "\n请输入要管理的配置编号 (输入 'B' 或按 Enter 返回主菜单): "; read -r choice
        case "$choice" in
            ""|[Bb]*) break ;;
            *)
                selected_domain=$(echo "$domain_list" | awk -v n="$choice" '{print $n}')
                if [ -n "$selected_domain" ]; then manage_single_proxy_menu "$selected_domain";
                else print_warning "无效的选项 '$choice'。"; sleep 2; fi;;
        esac
    done
}

manage_single_proxy_menu() {
    local domain="$1"
    local is_active
    local toggle_action_text
    local sub_choice
    while true; do
        clear; printf "正在管理域名: %b\n" "${YELLOW}$domain${NC}"; printf -- "----------------------------------------\n"
        is_active=0;
        if [ "$OS_TYPE" = "debian" ]; then
            if [ -L "/etc/nginx/sites-enabled/$domain.conf" ]; then is_active=1; fi
        else
            if [ -f "/etc/nginx/http.d/$domain.conf" ]; then is_active=1; fi
        fi

        if [ "$is_active" -eq 1 ]; then
            printf "当前状态: %b\n\n" "${GREEN}运行中${NC}"; toggle_action_text="暂停"
        else
            printf "当前状态: %b\n\n" "${YELLOW}已暂停${NC}"; toggle_action_text="恢复"
        fi
        
        printf "请选择操作:\n"; printf "  1) %s\n" "$toggle_action_text"
        printf "  2) 修改反代目标\n"; printf "  3) 手动续期证书\n"
        printf "  4) %b\n" "${RED}删除配置${NC}"; printf "  5) 返回上一级\n"
        printf "请输入选项 [1-5]: "; read -r sub_choice

        case "$sub_choice" in
            1) toggle_proxy_status "$domain" "$is_active"; break ;;
            2) modify_proxy_target "$domain"; break ;;
            3) renew_certificate "$domain"; break;;
            4) delete_proxy "$domain"; break;;
            5) break;;
            *) print_warning "无效的选项。"; sleep 2;;
        esac
    done
}

modify_proxy_target() {
    local domain="$1"
    local conf_path
    local current_proxy_pass
    local address
    local original_address
    local port
    local protocol
    local new_proxy_pass
    local nginx_test_output

    if [ "$OS_TYPE" = "debian" ]; then conf_path="/etc/nginx/sites-available/$domain.conf"; else conf_path="/etc/nginx/http.d/$domain.conf"; fi
    if [ ! -f "$conf_path" ]; then conf_path="${conf_path}.disabled"; fi
    if [ ! -f "$conf_path" ]; then print_warning "找不到配置文件: $domain"; sleep 2; return; fi

    current_proxy_pass=$(grep "proxy_pass" "$conf_path" | head -n 1 | sed -e 's/^[[:space:]]*proxy_pass[[:space:]]*//' -e 's/;//')
    print_info "当前的反向代理目标是: ${current_proxy_pass}"
    
    while true; do
        printf "请输入新的反向代理目标地址 (例如: 127.0.0.1:9000): "; read -r address
        if [ -z "$address" ]; then print_warning "目标地址不能为空。"; continue; fi
        original_address="$address"
        if echo "$address" | grep -qE '^[0-9]+$'; then address="127.0.0.1:$address"; fi
        port=$(echo "$address" | sed 's/.*://')
        if ! echo "$port" | grep -qE '^[0-9]+$'; then print_warning "地址格式 '$original_address' 无效。"; continue; fi
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then print_warning "端口号 '$port' 无效 (1-65535)。"; continue; fi
        if echo "$original_address" | grep -qE '^[0-9]+$'; then print_info "自动补全为: $address"; fi
        break
    done
    printf "请选择协议 [http/https] (默认: http): "; read -r protocol; protocol=${protocol:-http}
    new_proxy_pass="${protocol}://${address}"

    print_info "准备将目标更新为: $new_proxy_pass"
    cp "$conf_path" "$conf_path.bak" 
    sed -i "s|proxy_pass.*|proxy_pass ${new_proxy_pass};|" "$conf_path"

    nginx_test_output=$(nginx -t 2>&1)
    if [ $? -eq 0 ]; then
        if apply_nginx_config; then
             print_success "配置更新成功。"
             rm "$conf_path.bak"
        else
            print_warning "未能应用新的 Nginx 配置！正在回滚..."
            mv "$conf_path.bak" "$conf_path"
            print_warning "更改已回滚。"
        fi
    else
        printf '%b\n' "${RED}[ERROR] 新的配置未能通过 Nginx 测试！正在回滚...${NC}" >&2
        printf "\n--- Nginx 错误信息 ---\n%s\n-----------------------\n" "$nginx_test_output" >&2
        mv "$conf_path.bak" "$conf_path"
        print_warning "更改已回滚。"
    fi
    sleep 2
}

toggle_proxy_status() {
    local domain="$1"
    local is_active="$2"
    local nginx_test_output
    
    print_info "正在切换 '$domain' 的状态..."
    nginx_test_output=$(nginx -t 2>&1)
    if [ $? -ne 0 ]; then
        print_warning "Nginx 全局配置存在错误，无法继续操作。请先手动修复 Nginx 配置。"
        printf "\n--- Nginx 错误信息 ---\n%s\n-----------------------\n" "$nginx_test_output" >&2
        sleep 2
        return
    fi
    
    if [ "$is_active" -eq 1 ]; then 
        if [ "$OS_TYPE" = "debian" ]; then rm -f "/etc/nginx/sites-enabled/$domain.conf";
        else mv "/etc/nginx/http.d/$domain.conf" "/etc/nginx/http.d/$domain.conf.disabled"; fi
    else
        if [ "$OS_TYPE" = "debian" ]; then ln -s "/etc/nginx/sites-available/$domain.conf" "/etc/nginx/sites-enabled/";
        else mv "/etc/nginx/http.d/$domain.conf.disabled" "/etc/nginx/http.d/$domain.conf"; fi
    fi

    if apply_nginx_config; then
        if [ "$is_active" -eq 1 ]; then print_success "'$domain' 已暂停。"; else print_success "'$domain' 已恢复。"; fi
    else
        print_warning "正在回滚文件系统更改以保持状态一致..."
        if [ "$is_active" -eq 1 ]; then
            if [ "$OS_TYPE" = "debian" ]; then ln -s "/etc/nginx/sites-available/$domain.conf" "/etc/nginx/sites-enabled/";
            else mv "/etc/nginx/http.d/$domain.conf.disabled" "/etc/nginx/http.d/$domain.conf"; fi
        else
            if [ "$OS_TYPE" = "debian" ]; then rm -f "/etc/nginx/sites-enabled/$domain.conf";
            else mv "/etc/nginx/http.d/$domain.conf" "/etc/nginx/http.d/$domain.conf.disabled"; fi
        fi
        print_warning "更改已回滚。"
    fi
    sleep 2
}

delete_proxy() {
    local domain="$1"
    local confirm
    printf "您确定要永久删除 '$domain' 的所有配置吗？(y/N): "; read -r confirm
    case "$confirm" in
        [Yy])
            print_info "正在删除 '$domain'..."
            if command_exists certbot; then
                print_info "第 1 步: 正在删除 SSL 证书..."
                if ! certbot delete --cert-name "$domain" --non-interactive; then
                    print_warning "Certbot 证书删除失败。可能是证书不存在或 Certbot 出错。"
                    printf "是否仍要继续删除 Nginx 配置文件? (y/N): "
                    read -r confirm_nginx_delete
                    case "$confirm_nginx_delete" in
                        [Yy]) ;;
                        *) print_info "删除操作已中止。"; sleep 2; return ;;
                    esac
                fi
            fi

            print_info "第 2 步: 正在删除 Nginx 配置文件..."
            if [ "$OS_TYPE" = "debian" ]; then
                rm -f "/etc/nginx/sites-enabled/$domain.conf"
                rm -f "/etc/nginx/sites-available/$domain.conf"
            else
                rm -f "/etc/nginx/http.d/$domain.conf"
                rm -f "/etc/nginx/http.d/$domain.conf.disabled"
            fi
            print_success "Nginx 配置文件已删除。"
            
            apply_nginx_config || print_warning "Nginx 重载或启动失败，请稍后手动检查。"
            print_success "'$domain' 已被彻底删除。"; sleep 2
            ;;
        *) print_info "删除操作已取消。"; sleep 2;;
    esac
}

renew_certificate() {
    local domain="$1"
    local choice
    print_info "为域名 ${domain} 手动续期证书..."
    printf "是否先执行一次安全的续期测试 (dry-run)? (y/N): "; read -r choice
    case "$choice" in
        [Yy])
            print_info "正在执行续期测试 (dry-run)..."
            if ! certbot renew --dry-run --cert-name "$domain"; then
                print_warning "续期测试失败。请检查错误信息。"
                sleep 2; return
            fi
            print_success "续期测试成功！"
            ;;
    esac

    printf "是否立即为 ${domain} 续期证书? (Y/n): "; read -r choice
    case "$choice" in
        [Nn]) print_info "操作已取消。"; sleep 2; return ;;
    esac

    print_info "正在执行证书续期..."
    if certbot renew --cert-name "$domain" --deploy-hook "nginx -s reload"; then
        print_success "证书续期成功，Nginx 已自动重载。"
    else
        print_warning "证书续期失败。"
    fi
    sleep 2
}

enable_hsts_prompt() {
    local choice
    printf "\n"
    print_info "HSTS (HTTP Strict Transport Security) 是一项重要的安全功能，可以防止中间人攻击。"
    printf "是否为 ${PRIMARY_DOMAIN} 开启 HSTS？ (y/N): "; read -r choice
    case "$choice" in
        [Yy])
            enable_hsts "$PRIMARY_DOMAIN"
            ;;
        *)
            print_info "已跳过开启 HSTS。"
            ;;
    esac
}

enable_hsts() {
    local domain="$1"
    local conf_path
    local nginx_test_output
    local hsts_header

    print_info "正在为 ${domain} 开启 HSTS..."
    if [ "$OS_TYPE" = "debian" ]; then
        conf_path="/etc/nginx/sites-available/${domain}.conf"
    else
        conf_path="/etc/nginx/http.d/${domain}.conf"
    fi

    if [ ! -f "$conf_path" ]; then
        print_warning "找不到配置文件: ${conf_path}"
        sleep 2; return
    fi

    if grep -q "Strict-Transport-Security" "$conf_path"; then
        print_warning "HSTS 配置已存在。"
        sleep 2; return
    fi
    
    hsts_header='"max-age=31536000" always;'

    cp "$conf_path" "$conf_path.bak"
    # 在 ssl_certificate_key 后面添加 HSTS header
    sed -i "/ssl_certificate_key/a \        add_header Strict-Transport-Security ${hsts_header}" "$conf_path"

    nginx_test_output=$(nginx -t 2>&1)
    if [ $? -eq 0 ]; then
        if apply_nginx_config; then
            print_success "HSTS 已成功开启。"
        else
            print_warning "未能应用 HSTS 配置！正在回滚..."
            mv "$conf_path.bak" "$conf_path"
            print_warning "HSTS 配置已回滚。"
            apply_nginx_config
        fi
    else
        printf '%b\n' "${RED}[ERROR] HSTS 配置未能通过 Nginx 测试！正在回滚...${NC}" >&2
        printf "\n--- Nginx 错误信息 ---\n%s\n-----------------------\n" "$nginx_test_output" >&2
        mv "$conf_path.bak" "$conf_path"
        print_warning "HSTS 配置已回滚。"
    fi
    sleep 2
}

# --- 脚本主入口 ---
main() {
    local choice
    check_privileges
    detect_os
    install_dependencies
    
    while true; do
        clear
        printf '%b\n' "${GREEN}=====================================================${NC}"
        printf '%b\n' "${GREEN}      Nginx & Certbot 一键反代与 SSL 管理脚本      ${NC}"
        printf '%b\n' "${GREEN}=====================================================${NC}"; printf '\n'

        printf "请选择要执行的操作:\n"
        printf "  1) 创建新的反向代理配置\n"
        printf "  2) 管理已有的反代配置\n"
        printf "  3) 退出\n"
        printf "请输入选项 [1-3]: "; read -r choice

        case "$choice" in
            1) create_new_proxy; printf "\n按 Enter 键返回主菜单..."; read -r _;;
            2) manage_proxies_menu;;
            3) print_info "脚本已退出。"; exit 0;;
            *) print_warning "无效的选项。"; sleep 2;;
        esac
    done
}

main

