#!/bin/bash
# =============================================================================
# Script Name: emby-openresty.sh (通用优化版)
# Description: Emby OpenResty 反向代理一键配置脚本（通用反向代理）
# Version: 3.2.0
# Author: Siu
# Date: 2026-03-11
# License: MIT
#
# Features:
#   - 适配 OpenResty (1Panel 面板)
#   - 支持手动选择源服务器协议 (HTTP/HTTPS)
#   - 支持任意端口配置 (1-65535)
#   - HTTP/HTTPS 双模式支持
#   - UA 欺骗功能（伪装客户端）
#   - WebSocket 支持
#   - 安全头部配置
#   - 端口占用检测
#   - 配置备份与回滚
#   - 自动检测 1Panel OpenResty 路径
#   - 详细日志记录
#   - 输入验证与错误处理
#   - 跨平台 sed 兼容（GNU/BSD）
# =============================================================================

# 严格模式
set -euo pipefail

# =============================================================================
# 全局配置
# =============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/emby-openresty.log"

# 检测 1Panel OpenResty 路径
detect_openresty_paths() {
    # 常见的 1Panel OpenResty 路径
    local possible_paths=(
        "/opt/1Panel/apps/openresty/openresty"
        "/www/server/panel/vhost/openresty"
        "/usr/local/openresty"
        "/etc/openresty"
    )

    for path in "${possible_paths[@]}"; do
        if [[ -d "$path/conf.d" ]] || [[ -d "$path/nginx/conf.d" ]]; then
            echo "$path"
            return 0
        fi
    done

    # 尝试通过命令查找
    if command -v openresty &>/dev/null; then
        local openresty_path="$(openresty -V 2>&1 | grep 'prefix=' | head -1 | sed 's/.*prefix=\([^ ]*\).*/\1/')"
        if [[ -n "$openresty_path" ]]; then
            echo "$openresty_path"
            return 0
        fi
    fi

    echo "/usr/local/openresty"
}

readonly OPENRESTY_BASE="$(detect_openresty_paths)"
readonly CONF_DIR="$OPENRESTY_BASE/nginx/conf"
readonly SITES_AVAILABLE="$CONF_DIR/vhosts"
readonly SITES_ENABLED="$CONF_DIR/vhosts-enabled"
readonly OPENRESTY_CONF="$CONF_DIR/nginx.conf"
readonly NGINX_PID="/run/openresty.pid"

# 颜色输出
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# UA 选项映射
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
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE" 2>/dev/null || true
}

info()  { echo -e "${GREEN}[INFO]${NC} $*"; log "INFO" "$*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; log "WARN" "$*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; log "ERROR" "$*"; exit 1; }
debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $*" || true; log "DEBUG" "$*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本 (sudo ./$SCRIPT_NAME)"
    fi
    log "INFO" "Root 权限验证通过"
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$ID"
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

check_dependencies() {
    local deps=("grep" "sed" "awk")
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # 检查 OpenResty 或 Nginx
    if ! command -v openresty &>/dev/null && ! command -v nginx &>/dev/null; then
        error "OpenResty/Nginx 未安装，请先安装 OpenResty"
    fi

    [[ ${#missing[@]} -gt 0 ]] && error "缺少必要命令: ${missing[*]}"
    log "INFO" "依赖检查通过"
}

check_openresty() {
    # 检测使用的二进制文件
    if command -v openresty &>/dev/null; then
        local openresty_ver="$(openresty -v 2>&1 | head -1)"
        info "检测到 OpenResty: $openresty_ver"
        NGINX_BIN="openresty"
    else
        local nginx_ver="$(nginx -v 2>&1 | head -1)"
        info "检测到 Nginx: $nginx_ver"
        NGINX_BIN="nginx"
    fi

    # 确保配置目录存在
    mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED" 2>/dev/null || true

    # 检查是否是 1Panel 环境
    if [[ -d "/opt/1Panel" ]]; then
        info "检测到 1Panel 环境"
        if [[ ! -d "$SITES_AVAILABLE" ]]; then
            warn "1Panel OpenResty 配置目录未找到，使用默认路径"
        fi
    fi

    info "OpenResty 检查通过"
    log "INFO" "OpenResty 验证通过: $OPENRESTY_BASE"
}

validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*(:[0-9]{1,5})?$ ]]
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

validate_path() {
    local path="$1"
    local real_path

    # 尝试解析路径
    real_path="$(realpath "$path" 2>/dev/null)" || {
        warn "无法解析路径: $path"
        return 1
    }

    # 基本安全检查：路径必须是绝对路径且不以 /tmp 开头
    [[ "$real_path" =~ ^/ ]] && [[ ! "$real_path" =~ ^/tmp ]]

    # 可选：检查证书文件是否存在
    if [[ -d "$real_path" ]]; then
        [[ -f "$real_path/fullchain.pem" ]] && [[ -f "$real_path/privkey.pem" ]]
    else
        warn "路径不是目录: $real_path"
        return 1
    fi
}

check_port_available() {
    local port="$1"
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            return 1
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            return 1
        fi
    fi
    if command -v timeout &>/dev/null; then
        if timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}

backup_config() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        mkdir -p "$OPENRESTY_BASE/.backup" 2>/dev/null || true
        local backup_name="$(basename "$config_file").$(date +%Y%m%d%H%M%S).bak"
        cp -p "$config_file" "$OPENRESTY_BASE/.backup/$backup_name" 2>/dev/null || true
        info "配置已备份: $OPENRESTY_BASE/.backup/$backup_name"
        log "INFO" "备份创建: $backup_name"
        echo "$OPENRESTY_BASE/.backup/$backup_name"
    fi
}

rollback_config() {
    local config_file="$1"
    local latest_backup="$(ls -t "$OPENRESTY_BASE/.backup"/$(basename "$config_file").*.bak 2>/dev/null | head -1)"
    if [[ -n "$latest_backup" ]] && [[ -f "$latest_backup" ]]; then
        warn "检测到配置错误，正在回滚..."
        cp -p "$latest_backup" "$config_file"
        info "配置已回滚到: $latest_backup"
        log "INFO" "配置回滚: $latest_backup -> $config_file"
        return 0
    fi
    return 1
}

test_nginx_config() {
    info "测试 OpenResty 配置..."
    if $NGINX_BIN -t 2>&1; then
        log "INFO" "OpenResty 配置测试通过"
        return 0
    else
        log "ERROR" "OpenResty 配置测试失败"
        return 1
    fi
}

reload_nginx() {
    info "重载 OpenResty 服务..."

    # 尝试 systemctl
    if systemctl reload openresty 2>/dev/null || systemctl reload nginx 2>/dev/null; then
        info "OpenResty 重载成功 (systemctl)"
        log "INFO" "OpenResty 服务已重载"
        return 0
    fi

    # 尝试 service
    if service openresty reload 2>/dev/null || service nginx reload 2>/dev/null; then
        info "OpenResty 重载成功 (service)"
        log "INFO" "OpenResty 服务已重载"
        return 0
    fi

    # 尝试直接命令
    if $NGINX_BIN -s reload 2>/dev/null; then
        info "OpenResty 重载成功 (direct)"
        log "INFO" "OpenResty 服务已重载"
        return 0
    fi

    # 重启作为最后的手段
    warn "reload 失败，尝试 restart..."
    if systemctl restart openresty 2>/dev/null || systemctl restart nginx 2>/dev/null; then
        info "OpenResty 重启成功 (systemctl)"
        return 0
    fi

    error "OpenResty 服务操作失败"
}

# 跨平台 sed 多行插入（兼容 GNU 和 BSD sed）
insert_after() {
    local pattern="$1"
    local content="$2"
    local file="$3"

    # 检测 sed 类型
    if sed --version 2>&1 | grep -q "GNU"; then
        # GNU sed - 支持 \n
        sed -i "/${pattern}/a\\${content}" "$file"
    else
        # BSD sed (macOS) - 需要换行符
        local escaped_content
        escaped_content=$(echo "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
        sed -i '' "/${pattern}/a\\
$escaped_content
" "$file"
    fi
}

# =============================================================================
# 菜单函数
# =============================================================================

show_main_menu() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    Emby OpenResty 反向代理配置脚本 v3.2${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "  ${GREEN}1${NC} - 安装/配置反向代理"
    echo "  ${GREEN}2${NC} - 修改 User-Agent"
    echo "  ${GREEN}3${NC} - 卸载配置"
    echo "  ${GREEN}4${NC} - 查看已配置域名"
    echo "  ${GREEN}5${NC} - 查看日志"
    echo "  ${GREEN}6${NC} - OpenResty 状态诊断"
    echo "  ${RED}0${NC} - 退出"
    echo ""
}

list_configured_domains() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    已配置的 Emby 反向代理域名${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    local count=0
    if [[ -d "$SITES_ENABLED" ]]; then
        for config in "$SITES_ENABLED"/*; do
            [[ -e "$config" ]] || continue
            local domain="$(basename "$config" .conf)"
            local config_file="$SITES_AVAILABLE/${domain}.conf"
            if [[ -f "$config_file" ]] && grep -q "# Emby Proxy Config" "$config_file" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} $domain"
                ((count++))
            fi
        done
    fi
    [[ $count -eq 0 ]] && echo -e "  ${YELLOW}暂无已配置的 Emby 反向代理${NC}" || { echo ""; echo -e "  共 ${GREEN}$count${NC} 个配置"; }
    echo ""
}

diagnose_openresty() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    OpenResty 状态诊断${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    info "OpenResty 基础路径: $OPENRESTY_BASE"
    info "配置目录: $CONF_DIR"
    info "虚拟主机目录: $SITES_AVAILABLE"
    echo ""

    info "二进制文件:"
    command -v openresty && openresty -v 2>&1 || command -v nginx && nginx -v 2>&1 || echo "  未找到"
    echo ""

    info "OpenResty 进程状态:"
    ps aux | grep -E "[o]penresty|[n]ginx" | head -5 || echo "  无运行进程"
    echo ""

    info "监听端口:"
    ss -tlnp 2>/dev/null | grep -E ":(80|443|8080|8443)" || netstat -tlnp 2>/dev/null | grep -E ":(80|443|8080|8443)" || echo "  无"
    echo ""

    info "配置测试:"
    $NGINX_BIN -t 2>&1 || echo "  测试失败"
    echo ""

    info "错误日志 (最近 10 行):"
    local error_log="${OPENRESTY_BASE}/nginx/logs/error.log"
    if [[ -f "$error_log" ]]; then
        tail -n 10 "$error_log"
    else
        echo "  日志文件不存在"
    fi
    echo ""

    info "系统服务状态:"
    if systemctl status openresty 2>/dev/null | head -5; then
        :
    elif systemctl status nginx 2>/dev/null | head -5; then
        :
    else
        echo "  无服务管理器"
    fi
    echo ""
}

# =============================================================================
# 配置生成函数
# =============================================================================

generate_openresty_config() {
    local domain="$1" use_https="$2" listen_port="$3" cert_path="$4"
    local source_host="$5" source_port="$6" source_protocol="$7"
    local block_ip="$8" block_root="$9" custom_ua="${10}"

    cat <<EOF
# Emby Proxy Config - Generated by emby-openresty.sh v3.2
# Domain: $domain
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

EOF

    if [[ "$use_https" == "true" ]]; then
        cat <<EOF
server {
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
server {
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

    # 根据源协议设置 SSL 配置
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
        proxy_set_header User-Agent "${custom_ua}";

EOF

    cat <<'EOF'
    }
}
EOF

    # HTTP 到 HTTPS 重定向（仅当启用 HTTPS 且端口为 443 时）
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
    echo -e "${CYAN}    安装/配置 Emby 反向代理${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    local domain
    while true; do
        read -p "请输入你的域名 (例如: emby.example.com): " domain
        [[ -z "$domain" ]] && { warn "域名不能为空"; continue; }
        validate_domain "$domain" || { warn "无效的域名格式，请重新输入"; continue; }
        break
    done

    local config_file="$SITES_AVAILABLE/${domain}.conf"
    if [[ -f "$config_file" ]]; then
        warn "域名 $domain 的配置已存在"
        read -p "是否覆盖现有配置? (y/n): " overwrite
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
                read -p "是否继续? (y/n): " cc; [[ "${cc,,}" != "y" ]] && continue
            }
            break
        done
        while true; do
            read -p "请输入 SSL 证书路径 (例如: /etc/letsencrypt/live/example.com): " cert_path
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
                read -p "是否继续? (y/n): " cc; [[ "${cc,,}" != "y" ]] && continue
            }
            break
        done
    fi

    # 源地址输入
    local source_host
    while true; do
        read -p "请输入 Emby 源服务器地址 (例如: emby-origin.example.com): " source_host
        [[ -z "$source_host" ]] && { warn "源地址不能为空"; continue; }
        validate_domain "$source_host" || { warn "无效的源地址格式"; continue; }
        break
    done

    # 源端口
    local source_port
    while true; do
        read -p "请输入 Emby 源服务器端口 (1-65535): " source_port
        [[ -z "$source_port" ]] && { warn "端口不能为空"; continue; }
        validate_port "$source_port" || { warn "端口必须在 1-65535 之间"; continue; }
        break
    done

    # 源协议选择（重要：手动选择）
    local source_protocol=""
    echo ""
    echo -e "${CYAN}请选择源服务器协议：${NC}"
    echo "  ${GREEN}1${NC} - HTTP"
    echo "  ${GREEN}2${NC} - HTTPS"
    echo ""
    while true; do
        read -p "请选择协议 (1-2): " protocol_choice
        case "$protocol_choice" in
            1)
                source_protocol="http"
                info "已选择 HTTP 协议"
                break
                ;;
            2)
                source_protocol="https"
                info "已选择 HTTPS 协议"
                break
                ;;
            *)
                warn "无效的选项，请输入 1 或 2"
                ;;
        esac
    done

    # 安全选项
    local block_ip="false" block_root="false"
    read -p "是否禁止 IP 直接访问? (y/n): " bip; [[ "${bip,,}" == "y" ]] && block_ip="true"
    read -p "是否禁止根路径访问 / (返回 502)? (y/n): " br; [[ "${br,,}" == "y" ]] && block_root="true"

    echo ""
    echo -e "${CYAN}常见 Emby 设备 User-Agent 选项：${NC}"
    echo "  ${GREEN}1${NC} - vivo-V2454DA | AfuseKt-2.9.8.6-10617"
    echo "  ${GREEN}2${NC} - PD2454 | Hills-1.4.8"
    echo "  ${GREEN}3${NC} - iPhone | SenPlayer-5.10.0"
    echo "  ${GREEN}4${NC} - iPhone | Lenna-1.0.10"
    echo "  ${GREEN}5${NC} - Apple TV | SenPlayer-5.9.0"
    echo "  ${GREEN}6${NC} - Apple TV | Infuse-Direct-8.3.7"
    echo "  ${RED}0${NC} - 不启用 UA 欺骗"
    echo ""

    local ua_option custom_ua=""
    while true; do
        read -p "请选择 UA 欺骗选项 (0-6): " ua_option
        [[ "$ua_option" =~ ^[0-6]$ ]] && break
        warn "无效的选项，请输入 0-6"
    done
    [[ "$ua_option" != "0" ]] && { custom_ua="${UA_OPTIONS[$ua_option]}"; info "已选择: ${UA_DEVICES[$ua_option]} | $custom_ua"; }

    echo ""
    info "配置信息确认："
    echo "  ${CYAN}域名${NC}: $domain"
    echo "  ${CYAN}协议${NC}: $([ "$use_https" == "true" ] && echo "HTTPS" || echo "HTTP")，端口: $listen_port"
    [[ "$use_https" == "true" ]] && echo "  ${CYAN}证书路径${NC}: $cert_path"
    echo "  ${CYAN}源地址${NC}: $source_host:$source_port"
    echo -e "  ${CYAN}源协议${NC}: ${GREEN}${source_protocol^^}${NC}"
    echo "  ${CYAN}禁止 IP 访问${NC}: $block_ip"
    echo "  ${CYAN}禁止根路径${NC}: $block_root"
    [[ -n "$custom_ua" ]] && echo "  ${CYAN}UA 欺骗${NC}: 已启用 ($custom_ua)"
    echo ""

    read -p "确认配置? (y/n): " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消配置"; return; }

    info "正在生成 OpenResty 配置文件..."
    mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED"
    generate_openresty_config "$domain" "$use_https" "$listen_port" "$cert_path" "$source_host" "$source_port" "$source_protocol" "$block_ip" "$block_root" "$custom_ua" > "$config_file"
    info "配置文件已生成: $config_file"

    # 创建符号链接
    local symlink="$SITES_ENABLED/${domain}.conf"
    [[ -L "$symlink" || -f "$symlink" ]] && rm -f "$symlink"
    ln -sf "$config_file" "$symlink"
    info "符号链接已创建: $symlink"

    test_nginx_config || error "OpenResty 配置测试失败，配置未应用"
    reload_nginx

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ 配置完成！${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "访问地址:"
    if [[ "$use_https" == "true" ]]; then
        [[ "$listen_port" == "443" ]] && echo "  ${GREEN}https://$domain${NC}" || echo "  ${GREEN}https://$domain:$listen_port${NC}"
    else
        [[ "$listen_port" == "80" ]] && echo "  ${GREEN}http://$domain${NC}" || echo "  ${GREEN}http://$domain:$listen_port${NC}"
    fi
    echo ""
    echo "配置文件: $config_file"
    echo "日志文件: $LOG_FILE"
    echo ""
    log "INFO" "配置完成: domain=$domain, https=$use_https, port=$listen_port, source=$source_protocol://$source_host:$source_port"
}

modify_ua() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    修改 User-Agent${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    read -p "请输入要修改的域名: " domain
    [[ -z "$domain" ]] && error "域名不能为空"
    local config_file="$SITES_AVAILABLE/${domain}.conf"
    [[ ! -f "$config_file" ]] && error "配置文件不存在: $config_file"

    local backup="$(backup_config "$config_file")"

    echo ""
    echo -e "${CYAN}User-Agent 选项：${NC}"
    echo "  ${GREEN}1${NC} - vivo-V2454DA | AfuseKt-2.9.8.6-10617"
    echo "  ${GREEN}2${NC} - PD2454 | Hills-1.4.8"
    echo "  ${GREEN}3${NC} - iPhone | SenPlayer-5.10.0"
    echo "  ${GREEN}4${NC} - iPhone | Lenna-1.0.10"
    echo "  ${GREEN}5${NC} - Apple TV | SenPlayer-5.9.0"
    echo "  ${GREEN}6${NC} - Apple TV | Infuse-Direct-8.3.7"
    echo "  ${RED}0${NC} - 移除 UA 欺骗"
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
    read -p "确认修改? (y/n): " confirm
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
            # 使用跨平台兼容的插入方法
            local ua_content="        # UA Spoofing
        proxy_set_header User-Agent \"$new_ua\";"

            # 查找 location / 块中的 proxy_buffering off; 并在其后插入
            if grep -q "location / {" "$config_file"; then
                # 方法1：使用 awk 插入（最可靠）
                awk -v ua="$ua_content" '
                    /location \/ {/ { in_location=1 }
                    in_location && /proxy_buffering off;/ {
                        print
                        print ua
                        next
                    }
                    { print }
                ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
            else
                error "未找到有效的 location / 配置块"
            fi
        fi
    fi

    if ! test_nginx_config; then
        warn "配置测试失败，正在回滚..."
        [[ -n "$backup" && -f "$backup" ]] && { cp -p "$backup" "$config_file"; info "配置已回滚"; }
        error "修改失败，请检查配置"
    fi
    reload_nginx

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ 修改完成！${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "当前 User-Agent: $ua_name"
    echo "配置文件: $config_file"
    echo ""
    log "INFO" "UA 修改完成: domain=$domain, ua=$new_ua"
}

uninstall_proxy() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    卸载配置${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    read -p "请输入要删除的域名配置: " domain
    [[ -z "$domain" ]] && error "域名不能为空"

    local sites_available="$SITES_AVAILABLE/${domain}.conf"
    local sites_enabled="$SITES_ENABLED/${domain}.conf"

    echo ""
    warn "即将删除以下配置："
    echo "  配置文件: $sites_available"
    echo "  符号链接: $sites_enabled"
    echo ""

    read -p "确认删除? (y/n): " confirm
    [[ "${confirm,,}" != "y" ]] && error "已取消"

    [[ -f "$sites_available" ]] && backup_config "$sites_available"

    [[ -L "$sites_enabled" || -f "$sites_enabled" ]] && { rm -f "$sites_enabled"; info "已删除符号链接"; } || warn "符号链接不存在"
    [[ -f "$sites_available" ]] && { rm -f "$sites_available"; info "已删除配置文件"; } || warn "配置文件不存在"

    test_nginx_config && reload_nginx
    info "卸载完成！"
    log "INFO" "配置卸载: domain=$domain"
}

view_logs() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}    查看日志${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    [[ ! -f "$LOG_FILE" ]] && { warn "日志文件不存在: $LOG_FILE"; return; }

    echo -e "${CYAN}最近 50 行日志：${NC}"
    echo ""
    tail -n 50 "$LOG_FILE"
    echo ""

    read -p "是否查看全部日志? (y/n): " view_all
    [[ "${view_all,,}" == "y" ]] && { less -R "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE"; }
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    check_root
    check_dependencies
    check_openresty
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || warn "无法写入日志文件: $LOG_FILE"

    info "Emby OpenResty 反向代理脚本已启动"
    info "检测到 OpenResty 基础路径: $OPENRESTY_BASE"
    log "INFO" "脚本启动，版本 3.2.0"

    while true; do
        show_main_menu
        read -p "请选择操作 (0-6): " choice
        case "$choice" in
            1) install_proxy ;;
            2) modify_ua ;;
            3) uninstall_proxy ;;
            4) list_configured_domains ;;
            5) view_logs ;;
            6) diagnose_openresty ;;
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
