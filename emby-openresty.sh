#!/bin/bash
# =============================================================================
# Script Name: emby-openresty.sh (通用增强版)
# Description: Emby OpenResty 反向代理一键配置脚本（兼容 1Panel 及标准系统）
# Version: 3.4.0
# Author: Siu
# Date: 2026-03-11
# License: MIT
#
# Features:
#   - 兼容 1Panel 面板及标准系统 (Ubuntu/CentOS/Debian 等)
#   - 自动检测 OpenResty/Nginx 环境
#   - 智能选择配置目录结构 (conf.d 或 sites-available/sites-enabled)
#   - 终端颜色自适应 (修复乱码问题)
#   - 支持任意端口配置 (1-65535)
#   - HTTP/HTTPS 双模式支持
#   - UA 欺骗功能（伪装客户端）
#   - WebSocket 支持
#   - 安全头部配置
#   - 端口占用检测
#   - 配置备份与回滚
#   - 详细日志记录
#   - 输入验证与错误处理
#   - 跨平台 sed 兼容（GNU/BSD）
# =============================================================================

set -euo pipefail

# =============================================================================
# 全局配置
# =============================================================================
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly LOG_FILE="/var/log/emby-openresty.log"

# =============================================================================
# 颜色输出 (修复乱码 - 自适应终端环境)
# =============================================================================
init_colors() {
    if [[ -t 1 ]] && [[ -n "${TERM:-}" ]] && [[ "$TERM" != "dumb" ]]; then
        if command -v tput &>/dev/null && tput cols &>/dev/null 2>&1; then
            readonly RED="$(tput setaf 1)"
            readonly GREEN="$(tput setaf 2)"
            readonly YELLOW="$(tput setaf 3)"
            readonly BLUE="$(tput setaf 4)"
            readonly CYAN="$(tput setaf 6)"
            readonly NC="$(tput sgr0)"
        else
            readonly RED='\e[0;31m'
            readonly GREEN='\e[0;32m'
            readonly YELLOW='\e[1;33m'
            readonly BLUE='\e[0;34m'
            readonly CYAN='\e[0;36m'
            readonly NC='\e[0m'
        fi
    else
        readonly RED=''
        readonly GREEN=''
        readonly YELLOW=''
        readonly BLUE=''
        readonly CYAN=''
        readonly NC=''
    fi
}
init_colors

# =============================================================================
# 环境检测 (1Panel 或标准系统)
# =============================================================================
detect_environment() {
    if [[ -d "/opt/1Panel" ]] || [[ -d "/www/server/panel" ]]; then
        echo "1panel"
    else
        echo "standard"
    fi
}

# =============================================================================
# OpenResty/Nginx 路径检测 (支持多环境)
# =============================================================================
detect_webserver_paths() {
    local env_type="$1"
    local possible_paths=()
    
    if [[ "$env_type" == "1panel" ]]; then
        # 1Panel 环境路径
        possible_paths=(
            "/opt/1panel/apps/openresty/openresty"
            "/opt/1panel/apps/openresty"
            "/www/server/panel/vhost/openresty"
        )
    else
        # 标准系统路径
        possible_paths=(
            "/usr/local/openresty"
            "/etc/openresty"
            "/usr/local/nginx"
            "/etc/nginx"
            "/usr/share/nginx"
        )
    fi
    
    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" ]]; then
            # 检查是否有 conf.d 或 conf 目录
            if [[ -d "$path/conf.d" ]] || [[ -d "$path/nginx/conf.d" ]] || \
               [[ -d "$path/conf" ]] || [[ -d "$path/nginx/conf" ]]; then
                echo "$path"
                return 0
            fi
        fi
    done
    
    # 尝试通过命令查找
    if command -v openresty &>/dev/null; then
        local openresty_path
        openresty_path="$(openresty -V 2>&1 | grep -o 'prefix=[^ ]*' | cut -d'=' -f2)"
        if [[ -n "$openresty_path" ]] && [[ -d "$openresty_path" ]]; then
            echo "$openresty_path"
            return 0
        fi
    elif command -v nginx &>/dev/null; then
        local nginx_path
        nginx_path="$(nginx -V 2>&1 | grep -o 'prefix=[^ ]*' | cut -d'=' -f2)"
        if [[ -n "$nginx_path" ]] && [[ -d "$nginx_path" ]]; then
            echo "$nginx_path"
            return 0
        fi
    fi
    
    # 默认返回
    if [[ "$env_type" == "1panel" ]]; then
        echo "/opt/1panel/apps/openresty/openresty"
    else
        echo "/usr/local/openresty"
    fi
}

readonly ENV_TYPE="$(detect_environment)"
readonly WEBSERVER_BASE="$(detect_webserver_paths "$ENV_TYPE")"

# 根据环境自动判断配置目录
init_config_dirs() {
    if [[ -d "$WEBSERVER_BASE/conf.d" ]]; then
        readonly CONF_D_DIR="$WEBSERVER_BASE/conf.d"
        readonly USE_SITES_STYLE="false"
    elif [[ -d "$WEBSERVER_BASE/nginx/conf.d" ]]; then
        readonly CONF_D_DIR="$WEBSERVER_BASE/nginx/conf.d"
        readonly USE_SITES_STYLE="false"
    elif [[ -d "$WEBSERVER_BASE/conf/conf.d" ]]; then
        readonly CONF_D_DIR="$WEBSERVER_BASE/conf/conf.d"
        readonly USE_SITES_STYLE="false"
    elif [[ -d "$WEBSERVER_BASE/nginx/conf/vhosts" ]] || [[ -d "/etc/nginx/sites-available" ]]; then
        # sites-available/sites-enabled 风格 (Debian/Ubuntu)
        readonly SITES_AVAILABLE="${SITES_AVAILABLE:-/etc/nginx/sites-available}"
        readonly SITES_ENABLED="${SITES_ENABLED:-/etc/nginx/sites-enabled}"
        readonly USE_SITES_STYLE="true"
    else
        # 默认使用 conf.d
        readonly CONF_D_DIR="${CONF_D_DIR:-$WEBSERVER_BASE/conf.d}"
        readonly USE_SITES_STYLE="false"
    fi
    
    # 主配置文件
    if [[ -f "$WEBSERVER_BASE/nginx.conf" ]]; then
        readonly MAIN_CONF="$WEBSERVER_BASE/nginx.conf"
    elif [[ -f "$WEBSERVER_BASE/nginx/conf/nginx.conf" ]]; then
        readonly MAIN_CONF="$WEBSERVER_BASE/nginx/conf/nginx.conf"
    elif [[ -f "/etc/nginx/nginx.conf" ]]; then
        readonly MAIN_CONF="/etc/nginx/nginx.conf"
    else
        readonly MAIN_CONF=""
    fi
    
    # 备份目录
    readonly BACKUP_DIR="$WEBSERVER_BASE/.emby_backup"
    
    # PID 文件
    if [[ -f "/run/openresty.pid" ]]; then
        readonly PID_FILE="/run/openresty.pid"
    elif [[ -f "/run/nginx.pid" ]]; then
        readonly PID_FILE="/run/nginx.pid"
    elif [[ -f "/var/run/nginx.pid" ]]; then
        readonly PID_FILE="/var/run/nginx.pid"
    else
        readonly PID_FILE=""
    fi
}
init_config_dirs

# 检测使用的二进制文件
if command -v openresty &>/dev/null; then
    readonly WEB_BIN="openresty"
    readonly WEB_NAME="OpenResty"
elif command -v nginx &>/dev/null; then
    readonly WEB_BIN="nginx"
    readonly WEB_NAME="Nginx"
else
    readonly WEB_BIN=""
    readonly WEB_NAME=""
fi

# =============================================================================
# UA 选项映射
# =============================================================================
declare -A UA_OPTIONS=(
    [1]="AfuseKt-2.9.8.6-10617"
    [2]="Hills-1.4.8"
    [3]="SenPlayer-5.10.0"
    [4]="Lenna-1.0.10"
    [5]="SenPlayer-5.9.0"
    [6]="Infuse-Direct-8.3.7"
)

declare -A UA_DEVICES=(
    [1]="vivo-V2454DA"
    [2]="PD2454"
    [3]="iPhone"
    [4]="iPhone"
    [5]="Apple TV"
    [6]="Apple TV"
)

# =============================================================================
# 工具函数
# =============================================================================
log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE" 2>/dev/null || true
}

info()  { echo -e "${GREEN}[INFO]${NC} $*"; log "INFO" "$*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; log "WARN" "$*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; log "ERROR" "$*"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本 (sudo ./$SCRIPT_NAME)"
    fi
    log "INFO" "Root 权限验证通过"
}

check_dependencies() {
    local deps=("grep" "sed" "awk")
    local missing=()
    for cmd in "${deps[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -gt 0 ]] && warn "缺少命令：${missing[*]}"
    
    if [[ -z "$WEB_BIN" ]]; then
        error "OpenResty/Nginx 未安装，请先安装 OpenResty 或 Nginx"
    fi
    log "INFO" "依赖检查完成"
}

check_webserver() {
    if [[ -n "$WEB_BIN" ]]; then
        local web_ver
        web_ver="$($WEB_BIN -v 2>&1 | head -1)"
        info "检测到 $WEB_NAME: $web_ver"
    else
        error "OpenResty/Nginx 未安装，请先安装 OpenResty 或 Nginx"
    fi
    
    # 确保配置目录存在
    if [[ "$USE_SITES_STYLE" == "true" ]]; then
        mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED" 2>/dev/null || true
    else
        mkdir -p "$CONF_D_DIR" 2>/dev/null || true
    fi
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    
    # 环境信息
    info "检测到环境类型：$ENV_TYPE"
    info "$WEB_NAME 基础路径：$WEBSERVER_BASE"
    if [[ "$USE_SITES_STYLE" == "true" ]]; then
        info "配置目录：$SITES_AVAILABLE (sites 风格)"
    else
        info "配置目录：$CONF_D_DIR (conf.d 风格)"
    fi
    
    log "INFO" "$WEB_NAME 验证通过"
}

validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

validate_path() {
    local path="$1"
    local real_path
    real_path="$(realpath "$path" 2>/dev/null)" || return 1
    [[ "$real_path" =~ ^/ ]] && [[ ! "$real_path" =~ ^/tmp ]]
    if [[ -d "$real_path" ]]; then
        [[ -f "$real_path/fullchain.pem" ]] && [[ -f "$real_path/privkey.pem" ]]
    else
        return 1
    fi
}

check_port_available() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]" && return 1
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]" && return 1
    fi
    return 0
}

backup_config() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        mkdir -p "$BACKUP_DIR"
        local backup_name
        backup_name="$(basename "$config_file").$(date +%Y%m%d%H%M%S).bak"
        cp -p "$config_file" "$BACKUP_DIR/$backup_name"
        info "配置已备份：$BACKUP_DIR/$backup_name"
        log "INFO" "备份创建：$backup_name"
        echo "$BACKUP_DIR/$backup_name"
    fi
}

test_webserver_config() {
    info "测试 $WEB_NAME 配置..."
    if $WEB_BIN -t 2>&1; then
        log "INFO" "$WEB_NAME 配置测试通过"
        return 0
    else
        log "ERROR" "$WEB_NAME 配置测试失败"
        return 1
    fi
}

reload_webserver() {
    info "重载 $WEB_NAME 服务..."
    
    # 尝试 systemctl
    if command -v systemctl &>/dev/null; then
        if systemctl reload openresty 2>/dev/null; then
            info "$WEB_NAME 重载成功 (systemctl openresty)"
            return 0
        elif systemctl reload nginx 2>/dev/null; then
            info "$WEB_NAME 重载成功 (systemctl nginx)"
            return 0
        fi
    fi
    
    # 尝试 service
    if command -v service &>/dev/null; then
        if service openresty reload 2>/dev/null; then
            info "$WEB_NAME 重载成功 (service openresty)"
            return 0
        elif service nginx reload 2>/dev/null; then
            info "$WEB_NAME 重载成功 (service nginx)"
            return 0
        fi
    fi
    
    # 尝试直接命令
    if $WEB_BIN -s reload 2>/dev/null; then
        info "$WEB_NAME 重载成功 (direct)"
        return 0
    fi
    
    # 重启作为最后手段
    warn "reload 失败，尝试 restart..."
    if command -v systemctl &>/dev/null; then
        systemctl restart openresty 2>/dev/null && return 0
        systemctl restart nginx 2>/dev/null && return 0
    fi
    
    error "$WEB_NAME 服务操作失败"
}

# =============================================================================
# 菜单函数
# =============================================================================
show_main_menu() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    Emby 反向代理配置脚本 v3.4${NC}"
    echo -e "${CYAN}    (兼容 1Panel 及标准系统)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} - 安装/配置反向代理"
    echo -e "  ${GREEN}2${NC} - 修改 User-Agent"
    echo -e "  ${GREEN}3${NC} - 卸载配置"
    echo -e "  ${GREEN}4${NC} - 查看已配置域名"
    echo -e "  ${GREEN}5${NC} - 查看日志"
    echo -e "  ${GREEN}6${NC} - $WEB_NAME 状态诊断"
    echo -e "  ${RED}0${NC} - 退出"
    echo ""
}

list_configured_domains() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    已配置的反向代理域名${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    local count=0
    
    if [[ "$USE_SITES_STYLE" == "true" ]]; then
        # sites-enabled 风格
        if [[ -d "$SITES_ENABLED" ]]; then
            for config in "$SITES_ENABLED"/*; do
                [[ -e "$config" ]] || continue
                local domain
                domain="$(basename "$config" .conf)"
                local config_file="$SITES_AVAILABLE/${domain}.conf"
                if [[ -f "$config_file" ]] && grep -q "# Emby Proxy Config" "$config_file" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} $domain"
                    ((count++))
                fi
            done
        fi
    else
        # conf.d 风格
        if [[ -d "$CONF_D_DIR" ]]; then
            for config in "$CONF_D_DIR"/*.conf; do
                [[ -e "$config" ]] || continue
                if grep -q "# Emby Proxy Config" "$config" 2>/dev/null; then
                    local domain
                    domain="$(basename "$config" .conf)"
                    echo -e "  ${GREEN}✓${NC} $domain"
                    ((count++))
                fi
            done
        fi
    fi
    
    [[ $count -eq 0 ]] && echo -e "  ${YELLOW}暂无已配置的反向代理${NC}" || { echo ""; echo -e "  共 ${GREEN}$count${NC} 个配置"; }
    echo ""
}

diagnose_webserver() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    $WEB_NAME 状态诊断${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    info "环境类型：$ENV_TYPE"
    info "$WEB_NAME 基础路径：$WEBSERVER_BASE"
    if [[ "$USE_SITES_STYLE" == "true" ]]; then
        info "配置目录：$SITES_AVAILABLE (sites 风格)"
    else
        info "配置目录：$CONF_D_DIR (conf.d 风格)"
    fi
    echo ""
    
    info "二进制文件:"
    command -v "$WEB_BIN" && $WEB_BIN -v 2>&1 || echo "  未找到"
    echo ""
    
    info "$WEB_NAME 进程状态:"
    ps aux | grep -E "[o]penresty|[n]ginx" | head -5 || echo "  无运行进程"
    echo ""
    
    info "监听端口:"
    ss -tlnp 2>/dev/null | grep -E ":(80|443|8080|8443)" || netstat -tlnp 2>/dev/null | grep -E ":(80|443|8080|8443)" || echo "  无"
    echo ""
    
    info "配置测试:"
    $WEB_BIN -t 2>&1 || echo "  测试失败"
    echo ""
    
    info "错误日志 (最近 10 行):"
    local error_log=""
    if [[ -n "$WEBSERVER_BASE" ]]; then
        if [[ -f "$WEBSERVER_BASE/nginx/logs/error.log" ]]; then
            error_log="$WEBSERVER_BASE/nginx/logs/error.log"
        elif [[ -f "$WEBSERVER_BASE/logs/error.log" ]]; then
            error_log="$WEBSERVER_BASE/logs/error.log"
        elif [[ -f "/var/log/nginx/error.log" ]]; then
            error_log="/var/log/nginx/error.log"
        fi
    fi
    [[ -n "$error_log" ]] && [[ -f "$error_log" ]] && tail -n 10 "$error_log" || echo "  日志文件不存在"
    echo ""
    
    info "系统服务状态:"
    if command -v systemctl &>/dev/null; then
        systemctl status openresty 2>/dev/null | head -5 || systemctl status nginx 2>/dev/null | head -5 || echo "  无法获取"
    else
        echo "  无服务管理器"
    fi
    echo ""
}

# =============================================================================
# 配置生成函数
# =============================================================================
generate_webserver_config() {
    local domain="$1" use_https="$2" listen_port="$3" cert_path="$4"
    local source_host="$5" source_port="$6" source_protocol="$7"
    local block_ip="$8" block_root="$9" custom_ua="${10}"
    
    cat <<EOF
# Emby Proxy Config - Generated by emby-openresty.sh v3.4
# Domain: $domain
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

server {
EOF
    
    if [[ "$use_https" == "true" ]]; then
        cat <<EOF
    listen ${listen_port} ssl http2;
    server_name ${domain};

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    ssl_certificate ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;
    ssl_stapling on;
    ssl_stapling_verify on;

EOF
        [[ "$listen_port" == "443" ]] && cat <<'EOF'
    error_page 497 301 =307 https://$host$request_uri;

EOF
    else
        cat <<EOF
    listen ${listen_port};
    server_name ${domain};

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

EOF
    fi
    
    [[ "$block_ip" == "true" ]] && cat <<'EOF'
    if ($host ~* ^\d+\.\d+\.\d+\.\d+$) {
        return 444;
    }

EOF
    
    [[ "$block_root" == "true" ]] && cat <<'EOF'
    location = / {
        return 502;
    }

EOF
    
    cat <<EOF
    location / {
        resolver 1.1.1.1 8.8.8.8 valid=30s ipv6=off;
        
        if (\$host != \$server_name) {
            return 403;
        }
        
        proxy_pass ${source_protocol}://${source_host}:${source_port};
        
EOF
    
    if [[ "$source_protocol" == "https" ]]; then
        cat <<EOF
        proxy_ssl_name ${source_host};
        proxy_ssl_server_name on;
        proxy_ssl_verify off;
        
EOF
    fi
    
    cat <<EOF
        proxy_set_header Host ${source_host};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Protocol \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
EOF
    
    [[ -n "$custom_ua" ]] && cat <<EOF
        # UA Spoofing
        proxy_set_header User-Agent "${custom_ua}";
        
EOF
    
    cat <<'EOF'
    }
}
EOF
    
    if [[ "$use_https" == "true" ]] && [[ "$listen_port" == "443" ]]; then
        cat <<EOF

server {
    listen 80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}
EOF
    fi
}

# =============================================================================
# 核心功能函数
# =============================================================================
install_proxy() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    安装/配置反向代理${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    local domain
    while true; do
        read -p "请输入你的域名 (例如：emby.example.com): " domain
        [[ -z "$domain" ]] && { warn "域名不能为空"; continue; }
        validate_domain "$domain" || { warn "无效的域名格式，请重新输入"; continue; }
        break
    done
    
    # 根据配置风格确定配置文件路径
    local config_file
    if [[ "$USE_SITES_STYLE" == "true" ]]; then
        config_file="$SITES_AVAILABLE/${domain}.conf"
    else
        config_file="$CONF_D_DIR/${domain}.conf"
    fi
    
    if [[ -f "$config_file" ]]; then
        warn "域名 $domain 的配置已存在"
        read -p "是否覆盖现有配置？(y/n): " overwrite
        [[ "${overwrite,,}" != "y" ]] && { info "已取消配置"; return; }
        backup_config "$config_file"
    fi
    
    local use_https="false" listen_port cert_path=""
    read -p "是否启用 HTTPS (SSL)? (y/n，推荐 n 以获得更好性能): " https_choice
    if [[ "${https_choice,,}" == "y" ]]; then
        use_https="true"
        while true; do
            read -p "请输入 HTTPS 端口 (默认 443): " listen_port
            [[ -z "$listen_port" ]] && listen_port="443"
            validate_port "$listen_port" || { warn "端口必须在 1-65535 之间"; continue; }
            check_port_available "$listen_port" || {
                warn "端口 $listen_port 已被占用"
                read -p "是否继续？(y/n): " cc; [[ "${cc,,}" != "y" ]] && continue
            }
            break
        done
        while true; do
            read -p "请输入 SSL 证书路径 (例如：/etc/letsencrypt/live/example.com): " cert_path
            [[ -z "$cert_path" ]] && { warn "证书路径不能为空"; continue; }
            validate_path "$cert_path" || { warn "证书路径无效或证书文件不完整"; continue; }
            break
        done
    else
        while true; do
            read -p "请输入 HTTP 端口 (默认 80): " listen_port
            [[ -z "$listen_port" ]] && listen_port="80"
            validate_port "$listen_port" || { warn "端口必须在 1-65535 之间"; continue; }
            check_port_available "$listen_port" || {
                warn "端口 $listen_port 已被占用"
                read -p "是否继续？(y/n): " cc; [[ "${cc,,}" != "y" ]] && continue
            }
            break
        done
    fi
    
    local source_host
    while true; do
        read -p "请输入 Emby 源服务器地址 (例如：emby-origin.example.com): " source_host
        [[ -z "$source_host" ]] && { warn "源地址不能为空"; continue; }
        validate_domain "$source_host" || { warn "无效的源地址格式"; continue; }
        break
    done
    
    local source_port
    while true; do
        read -p "请输入 Emby 源服务器端口 (1-65535): " source_port
        [[ -z "$source_port" ]] && { warn "端口不能为空"; continue; }
        validate_port "$source_port" || { warn "端口必须在 1-65535 之间"; continue; }
        break
    done
    
    local source_protocol=""
    echo ""
    echo -e "${CYAN}请选择源服务器协议：${NC}"
    echo -e "  ${GREEN}1${NC} - HTTP"
    echo -e "  ${GREEN}2${NC} - HTTPS"
    echo ""
    while true; do
        read -p "请选择协议 (1-2): " protocol_choice
        case "$protocol_choice" in
            1) source_protocol="http"; info "已选择 HTTP 协议"; break ;;
            2) source_protocol="https"; info "已选择 HTTPS 协议"; break ;;
            *) warn "无效的选项，请输入 1 或 2" ;;
        esac
    done
    
    local block_ip="false" block_root="false"
    read -p "是否禁止 IP 直接访问？(y/n): " bip; [[ "${bip,,}" == "y" ]] && block_ip="true"
    read -p "是否禁止根路径访问 / (返回 502)? (y/n): " br; [[ "${br,,}" == "y" ]] && block_root="true"
    
    echo ""
    echo -e "${CYAN}常见 Emby 设备 User-Agent 选项：${NC}"
    echo -e "  ${GREEN}1${NC} - vivo-V2454DA | AfuseKt-2.9.8.6-10617"
    echo -e "  ${GREEN}2${NC} - PD2454 | Hills-1.4.8"
    echo -e "  ${GREEN}3${NC} - iPhone | SenPlayer-5.10.0"
    echo -e "  ${GREEN}4${NC} - iPhone | Lenna-1.0.10"
    echo -e "  ${GREEN}5${NC} - Apple TV | SenPlayer-5.9.0"
    echo -e "  ${GREEN}6${NC} - Apple TV | Infuse-Direct-8.3.7"
    echo -e "  ${RED}0${NC} - 不启用 UA 欺骗"
    echo ""
    
    local ua_option custom_ua=""
    while true; do
        read -p "请选择 UA 欺骗选项 (0-6): " ua_option
        [[ "$ua_option" =~ ^[0-6]$ ]] && break
        warn "无效的选项，请输入 0-6"
    done
    [[ "$ua_option" != "0" ]] && { custom_ua="${UA_OPTIONS[$ua_option]}"; info "已选择：${UA_DEVICES[$ua_option]} | $custom_ua"; }
    
    echo ""
    info "配置信息确认："
    echo -e "  ${CYAN}域名${NC}: $domain"
    echo -e "  ${CYAN}协议${NC}: $([ "$use_https" == "true" ] && echo "HTTPS" || echo "HTTP")，端口：$listen_port"
    [[ "$use_https" == "true" ]] && echo -e "  ${CYAN}证书路径${NC}: $cert_path"
    echo -e "  ${CYAN}源地址${NC}: $source_host:$source_port"
    echo -e "  ${CYAN}源协议${NC}: ${GREEN}${source_protocol^^}${NC}"
    echo -e "  ${CYAN}禁止 IP 访问${NC}: $block_ip"
    echo -e "  ${CYAN}禁止根路径${NC}: $block_root"
    [[ -n "$custom_ua" ]] && echo -e "  ${CYAN}UA 欺骗${NC}: 已启用 ($custom_ua)"
    echo ""
    
    read -p "确认配置？(y/n): " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消配置"; return; }
    
    info "正在生成 $WEB_NAME 配置文件..."
    if [[ "$USE_SITES_STYLE" == "true" ]]; then
        mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED"
    else
        mkdir -p "$CONF_D_DIR"
    fi
    generate_webserver_config "$domain" "$use_https" "$listen_port" "$cert_path" "$source_host" "$source_port" "$source_protocol" "$block_ip" "$block_root" "$custom_ua" > "$config_file"
    info "配置文件已生成：$config_file"
    
    # 创建符号链接 (仅 sites 风格需要)
    if [[ "$USE_SITES_STYLE" == "true" ]]; then
        local symlink="$SITES_ENABLED/${domain}.conf"
        [[ -L "$symlink" || -f "$symlink" ]] && rm -f "$symlink"
        ln -sf "$config_file" "$symlink"
        info "符号链接已创建：$symlink"
    fi
    
    test_webserver_config || error "$WEB_NAME 配置测试失败，配置未应用"
    reload_webserver
    
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ 配置完成！${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "访问地址:"
    if [[ "$use_https" == "true" ]]; then
        [[ "$listen_port" == "443" ]] && echo -e "  ${GREEN}https://$domain${NC}" || echo -e "  ${GREEN}https://$domain:$listen_port${NC}"
    else
        [[ "$listen_port" == "80" ]] && echo -e "  ${GREEN}http://$domain${NC}" || echo -e "  ${GREEN}http://$domain:$listen_port${NC}"
    fi
    echo ""
    echo "配置文件：$config_file"
    echo "日志文件：$LOG_FILE"
    echo ""
    log "INFO" "配置完成：domain=$domain, https=$use_https, port=$listen_port, source=$source_protocol://$source_host:$source_port"
}

modify_ua() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    修改 User-Agent${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    read -p "请输入要修改的域名：" domain
    [[ -z "$domain" ]] && error "域名不能为空"
    
    local config_file
    if [[ "$USE_SITES_STYLE" == "true" ]]; then
        config_file="$SITES_AVAILABLE/${domain}.conf"
    else
        config_file="$CONF_D_DIR/${domain}.conf"
    fi
    
    [[ ! -f "$config_file" ]] && error "配置文件不存在：$config_file"
    
    local backup
    backup="$(backup_config "$config_file")"
    
    echo ""
    echo -e "${CYAN}User-Agent 选项：${NC}"
    echo -e "  ${GREEN}1${NC} - vivo-V2454DA | AfuseKt-2.9.8.6-10617"
    echo -e "  ${GREEN}2${NC} - PD2454 | Hills-1.4.8"
    echo -e "  ${GREEN}3${NC} - iPhone | SenPlayer-5.10.0"
    echo -e "  ${GREEN}4${NC} - iPhone | Lenna-1.0.10"
    echo -e "  ${GREEN}5${NC} - Apple TV | SenPlayer-5.9.0"
    echo -e "  ${GREEN}6${NC} - Apple TV | Infuse-Direct-8.3.7"
    echo -e "  ${RED}0${NC} - 移除 UA 欺骗"
    echo ""
    
    local ua_option new_ua="" ua_name="无"
    while true; do
        read -p "请选择选项 (0-6): " ua_option
        [[ "$ua_option" =~ ^[0-6]$ ]] && break
        warn "无效的选项"
    done
    [[ "$ua_option" != "0" ]] && { new_ua="${UA_OPTIONS[$ua_option]}"; ua_name="${UA_DEVICES[$ua_option]}"; }
    
    echo ""
    info "将设置 User-Agent: $ua_name"
    read -p "确认修改？(y/n): " confirm
    [[ "${confirm,,}" != "y" ]] && error "已取消"
    
    if [[ -z "$new_ua" ]]; then
        info "移除 UA 欺骗配置..."
        sed -i '/# UA Spoofing/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/proxy_set_header User-Agent/d' "$config_file"
    else
        if grep -q "proxy_set_header User-Agent" "$config_file"; then
            info "更新现有的 User-Agent 配置..."
            sed -i "s|proxy_set_header User-Agent \"[^\"]*\"|proxy_set_header User-Agent \"$new_ua\"|g" "$config_file"
        else
            info "添加新的 User-Agent 配置..."
            sed -i '/proxy_buffering off;/a\        # UA Spoofing\n        proxy_set_header User-Agent "'"$new_ua"'";' "$config_file"
        fi
    fi
    
    if ! test_webserver_config; then
        warn "配置测试失败，正在回滚..."
        [[ -n "$backup" && -f "$backup" ]] && { cp -p "$backup" "$config_file"; info "配置已回滚"; }
        error "修改失败，请检查配置"
    fi
    reload_webserver
    
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ 修改完成！${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "当前 User-Agent: $ua_name"
    echo "配置文件：$config_file"
    echo ""
    log "INFO" "UA 修改完成：domain=$domain, ua=$new_ua"
}

uninstall_proxy() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    卸载配置${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    read -p "请输入要删除的域名配置：" domain
    [[ -z "$domain" ]] && error "域名不能为空"
    
    local config_file symlink
    if [[ "$USE_SITES_STYLE" == "true" ]]; then
        config_file="$SITES_AVAILABLE/${domain}.conf"
        symlink="$SITES_ENABLED/${domain}.conf"
    else
        config_file="$CONF_D_DIR/${domain}.conf"
        symlink=""
    fi
    
    echo ""
    warn "即将删除以下配置："
    echo "  配置文件：$config_file"
    [[ -n "$symlink" ]] && echo "  符号链接：$symlink"
    echo ""
    
    read -p "确认删除？(y/n): " confirm
    [[ "${confirm,,}" != "y" ]] && error "已取消"
    
    [[ -f "$config_file" ]] && backup_config "$config_file"
    
    if [[ -n "$symlink" ]]; then
        [[ -L "$symlink" || -f "$symlink" ]] && { rm -f "$symlink"; info "已删除符号链接"; } || warn "符号链接不存在"
    fi
    [[ -f "$config_file" ]] && { rm -f "$config_file"; info "已删除配置文件"; } || warn "配置文件不存在"
    
    test_webserver_config && reload_webserver
    info "卸载完成！"
    log "INFO" "配置卸载：domain=$domain"
}

view_logs() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    查看日志${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    [[ ! -f "$LOG_FILE" ]] && { warn "日志文件不存在：$LOG_FILE"; return; }
    
    echo -e "${CYAN}最近 50 行日志：${NC}"
    echo ""
    tail -n 50 "$LOG_FILE"
    echo ""
    
    read -p "是否查看全部日志？(y/n): " view_all
    [[ "${view_all,,}" == "y" ]] && { less -R "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE"; }
}

# =============================================================================
# 主函数
# =============================================================================
main() {
    check_root
    check_dependencies
    check_webserver
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || warn "无法写入日志文件：$LOG_FILE"
    
    info "Emby 反向代理脚本已启动"
    info "环境类型：$ENV_TYPE"
    info "$WEB_NAME 基础路径：$WEBSERVER_BASE"
    log "INFO" "脚本启动，版本 3.4.0"
    
    while true; do
        show_main_menu
        read -p "请选择操作 (0-6): " choice
        case "$choice" in
            1) install_proxy ;;
            2) modify_ua ;;
            3) uninstall_proxy ;;
            4) list_configured_domains ;;
            5) view_logs ;;
            6) diagnose_webserver ;;
            0) echo ""; info "感谢使用，再见！"; log "INFO" "脚本退出"; exit 0 ;;
            *) warn "无效的选项，请输入 0-6"; continue ;;
        esac
        echo ""
        read -p "按 Enter 键继续..." || true
    done
}

# =============================================================================
# 脚本入口
# =============================================================================
trap 'log "INFO" "脚本被中断"; exit 130' INT TERM
main "$@"
