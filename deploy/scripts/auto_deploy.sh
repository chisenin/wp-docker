#!/bin/bash
# ==================================================
# WordPress Docker 全栈自动部署脚本 - 生产环境优化版
# 修订版：增加 .env CRLF 自动修复与 CPU 参数验证
# ==================================================

set -e
# set -x  # 调试模式

# ---------- 通用颜色输出 ----------
print_blue() { echo -e "\033[34m$1\033[0m"; }
print_green() { echo -e "\033[32m$1\033[0m"; }
print_yellow() { echo -e "\033[33m$1\033[0m"; }
print_red() { echo -e "\033[31m$1\033[0m"; }

# ---------- 随机密码 ----------
generate_password() {
    length=${1:-32}
    tr -dc 'A-Za-z0-9!@#$%^&*()' < /dev/urandom | head -c "$length" 2>/dev/null || \
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*()' | head -c "$length"
}

# ---------- WordPress 密钥 ----------
generate_wordpress_keys() {
    local keys=()
    local key_names=("AUTH_KEY" "SECURE_AUTH_KEY" "LOGGED_IN_KEY" "NONCE_KEY" "AUTH_SALT" "SECURE_AUTH_SALT" "LOGGED_IN_SALT" "NONCE_SALT")
    local api_success=false
    print_blue "尝试从 WordPress API 获取安全密钥..." >&2

    if command -v curl >/dev/null; then
        keys=($(curl -s --connect-timeout 10 https://api.wordpress.org/secret-key/1.1/salt/ | grep "define" | sed "s/define('\(.*\)',\s*'\(.*\)');/\1=\2/" || true))
        [ ${#keys[@]} -eq 8 ] && api_success=true
    elif command -v wget >/dev/null; then
        keys=($(wget -q --timeout=10 -O - https://api.wordpress.org/secret-key/1.1/salt/ | grep "define" | sed "s/define('\(.*\)',\s*'\(.*\)');/\1=\2/" || true))
        [ ${#keys[@]} -eq 8 ] && api_success=true
    fi

    if [ "$api_success" = true ]; then
        print_green "成功从 WordPress API 获取密钥" >&2
    else
        print_yellow "警告: API 获取失败，生成随机密钥..." >&2
        for key in "${key_names[@]}"; do
            keys+=("$key=$(generate_password 64)")
        done
    fi

    for key in "${keys[@]}"; do
        [[ "$key" =~ ^[A-Z_]+=.+$ ]] && echo "$key" || { print_red "错误: 无效密钥格式 $key"; exit 1; }
    done
}

# ---------- 检查宿主机环境 ----------
prepare_host_environment() {
    print_blue "检查并准备宿主机环境..."
    if [ -f /proc/sys/vm/overcommit_memory ] && [ "$(cat /proc/sys/vm/overcommit_memory)" -ne 1 ]; then
        print_yellow "调整 vm.overcommit_memory..."
        sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || { print_red "无法修改 vm.overcommit_memory"; exit 1; }
    fi
    command -v docker >/dev/null || { print_red "Docker 未安装"; exit 1; }
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        print_red "未检测到 Docker Compose"; exit 1
    fi
    DOCKER_CMD="docker"
    print_green "宿主机环境检查完成。"
}

# ---------- 检测系统 ----------
detect_host_environment() {
    print_blue "[步骤1] 检测主机环境.."
    OS=$(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null || echo "unknown")
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    AVAILABLE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    AVAILABLE_DISK=$(df -h / | awk 'NR==2{print $4}' | sed 's/G//')
    print_green "操作系统: $OS"
    print_green "CPU 核心数: $CPU_CORES"
    print_green "可用内存: ${AVAILABLE_RAM}MB"
    print_green "可用磁盘空间: ${AVAILABLE_DISK}GB"
}

# ---------- 系统参数收集 ----------
collect_system_parameters() {
    print_blue "[步骤2] 收集系统参数..."
    for tool in curl wget tar dos2unix sed; do
        command -v $tool >/dev/null || apt-get install -y $tool >/dev/null 2>&1 || true
    done
    print_green "Docker 版本: $($DOCKER_CMD --version)"
    print_green "Docker Compose 版本: $($DOCKER_COMPOSE_CMD version)"
}

# ---------- 部署目录 ----------
determine_deployment_directory() {
    print_blue "[步骤3] 确定部署目录..."
    DEPLOY_DIR="/opt"
    BACKUP_DIR="/opt/backups"
    mkdir -p "$DEPLOY_DIR" "$BACKUP_DIR"
    cd "$DEPLOY_DIR" || { print_red "无法进入部署目录"; exit 1; }
}

# ---------- 参数优化 ----------
optimize_parameters() {
    print_blue "[步骤4] 优化系统参数..."
    MEMORY_PER_SERVICE=$((AVAILABLE_RAM * 2 / 7))
    CPU_LIMIT=$((CPU_CORES / 2))
    [ "$CPU_LIMIT" -lt 1 ] && CPU_LIMIT=1
    PHP_MEMORY_LIMIT="384M"
    print_green "CPU 限制: ${CPU_LIMIT}"
    print_green "内存限制: ${MEMORY_PER_SERVICE}MB"

    cat > .env << EOF
# WordPress Docker 环境配置文件
DOCKERHUB_USERNAME=library
PHP_VERSION=8.3.26
NGINX_VERSION=1.27.2
MARIADB_VERSION=11.3.2
REDIS_VERSION=7.4.0
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=$(generate_password)
WORDPRESS_DB_HOST=mariadb:3306
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=$(generate_password)
WORDPRESS_DB_NAME=wordpress
WORDPRESS_REDIS_HOST=redis
WORDPRESS_REDIS_PORT=6379
CPU_LIMIT=${CPU_LIMIT}
MEMORY_PER_SERVICE=${MEMORY_PER_SERVICE}
PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT}
UPLOAD_MAX_FILESIZE=64M
PHP_INI_PATH=./deploy/configs/php.ini
$(generate_wordpress_keys)
EOF

    # --- 修正 CRLF 行尾 ---
    if grep -q $'\r' .env; then
        print_yellow "检测到 CRLF 行尾，正在转换..."
        sed -i 's/\r$//' .env
        print_green ".env 行尾修复完成"
    fi
    chmod 600 .env
}

# ---------- 部署 WordPress ----------
deploy_wordpress_stack() {
    print_blue "[步骤5] 部署 WordPress Docker 栈.."

    # 再次检查 .env 行尾（GitHub Actions 打包可能改回 CRLF）
    if grep -q $'\r' .env; then
        print_yellow "警告: .env 文件含有 CRLF 行尾，正在修正..."
        sed -i 's/\r$//' .env
        print_green ".env 已修正为 LF 行尾"
    fi

    export $(grep -E '^[A-Z_][A-Z0-9_]*=' .env | xargs) 2>/dev/null

    # 调试输出 CPU 变量
    print_blue "验证 CPU_LIMIT 展开情况..."
    echo "CPU_LIMIT (from env): ${CPU_LIMIT}"
    print_blue "Compose 展开结果（cpus 字段）:"
    $DOCKER_COMPOSE_CMD config | grep -A2 "cpus" || true

    print_blue "构建 Docker 镜像..."
    $DOCKER_COMPOSE_CMD build

    print_blue "启动容器..."
    if ! $DOCKER_COMPOSE_CMD up -d; then
        print_red "容器启动失败，打印日志："
        $DOCKER_COMPOSE_CMD logs --tail=50
        exit 1
    fi

    print_green "WordPress Docker 栈启动成功！"
}

# ---------- 其他辅助函数 ----------
setup_auto_backup() {
    mkdir -p /opt/scripts
    cat > /opt/scripts/backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/backups"
TIMESTAMP=$(date +%F_%H-%M-%S)
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/wordpress_backup_$TIMESTAMP.tar.gz" -C /opt html mysql
echo -e "\033[32m备份完成: wordpress_backup_$TIMESTAMP.tar.gz\033[0m"
EOF
    chmod +x /opt/scripts/backup.sh
}

setup_disk_space_management() {
    cat > /opt/scripts/cleanup.sh << 'EOF'
#!/bin/bash
find /opt/backups -type f -name "*.tar.gz" -mtime +7 -delete
echo -e "\033[32m清理7天前的备份文件完成\033[0m"
EOF
    chmod +x /opt/scripts/cleanup.sh
}

display_deployment_info() {
    print_blue "部署信息："
    print_green "访问地址: http://localhost"
    print_green "部署目录: /opt"
    print_green "备份目录: /opt/backups"
}

# ---------- 主执行 ----------
main() {
    print_blue "=================================================="
    print_blue "WordPress Docker 全栈自动部署脚本 - 生产环境优化版"
    print_blue "=================================================="

    prepare_host_environment
    detect_host_environment
    collect_system_parameters
    determine_deployment_directory
    optimize_parameters
    deploy_wordpress_stack
    setup_auto_backup
    setup_disk_space_management
    display_deployment_info

    print_green "WordPress Docker 自动部署完成 ✅"
}

main
