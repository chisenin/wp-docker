#!/bin/bash
# ==================================================
# WordPress Docker 全栈自动部署脚本 - 生产环境优化版
# 修正版 v2025.10.28
# 主要改动：
# - 所有 .env 密钥与密码均使用引号包裹
# - 自动修复 CRLF 行尾
# - 增强 Docker Compose 环境变量验证
# ==================================================

set -e
# set -x  # 调试模式

# ---------- 彩色输出 ----------
print_blue()   { echo -e "\033[34m$1\033[0m"; }
print_green()  { echo -e "\033[32m$1\033[0m"; }
print_yellow() { echo -e "\033[33m$1\033[0m"; }
print_red()    { echo -e "\033[31m$1\033[0m"; }

# ---------- 生成随机密码 ----------
generate_password() {
    length=${1:-32}
    tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom | head -c "$length" 2>/dev/null || \
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c "$length"
}

# ---------- 生成 WordPress 密钥 ----------
generate_wordpress_keys() {
    local key_names=("AUTH_KEY" "SECURE_AUTH_KEY" "LOGGED_IN_KEY" "NONCE_KEY" "AUTH_SALT" "SECURE_AUTH_SALT" "LOGGED_IN_SALT" "NONCE_SALT")
    print_blue "生成 WordPress 安全密钥（本地随机生成）..."
    for key in "${key_names[@]}"; do
        val=$(generate_password 64)
        echo "${key}=\"${val}\""
    done
}

# ---------- 宿主机环境检测 ----------
prepare_host_environment() {
    print_blue "检查宿主机环境..."
    if ! command -v docker >/dev/null; then
        print_red "Docker 未安装"; exit 1
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        print_red "未检测到 Docker Compose"; exit 1
    fi

    DOCKER_CMD="docker"
    print_green "宿主机环境正常"
}

# ---------- 主机系统参数 ----------
detect_host_environment() {
    print_blue "[步骤1] 检测主机环境..."
    OS=$(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null || echo "unknown")
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    AVAILABLE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    print_green "操作系统: $OS"
    print_green "CPU 核心数: $CPU_CORES"
    print_green "可用内存: ${AVAILABLE_RAM}MB"
}

# ---------- 工具检测 ----------
collect_system_parameters() {
    print_blue "[步骤2] 检查系统工具..."
    for tool in curl wget tar dos2unix sed; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y "$tool" -qq
        fi
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
    cd "$DEPLOY_DIR" || { print_red "无法进入 $DEPLOY_DIR"; exit 1; }
    print_green "部署目录: $DEPLOY_DIR"
}

# ---------- 优化参数与生成 .env ----------
optimize_parameters() {
    print_blue "[步骤4] 优化系统参数..."
    MEMORY_PER_SERVICE=$((AVAILABLE_RAM * 2 / 7))
    CPU_LIMIT=$((CPU_CORES / 2))
    [ "$CPU_LIMIT" -lt 1 ] && CPU_LIMIT=1
    PHP_MEMORY_LIMIT="384M"

    print_green "CPU 限制: ${CPU_LIMIT}"
    print_green "每服务内存: ${MEMORY_PER_SERVICE}MB"

    print_blue "生成 .env 文件..."
    cat > .env << EOF
# WordPress Docker 环境配置文件
# 生成时间: $(date)

DOCKERHUB_USERNAME="library"
PHP_VERSION="8.3.26"
NGINX_VERSION="1.27.2"
MARIADB_VERSION="11.3.2"
REDIS_VERSION="7.4.0"

MYSQL_ROOT_PASSWORD="$(generate_password)"
MYSQL_DATABASE="wordpress"
MYSQL_USER="wordpress"
MYSQL_PASSWORD="$(generate_password)"

WORDPRESS_DB_HOST="mariadb:3306"
WORDPRESS_DB_USER="wordpress"
WORDPRESS_DB_PASSWORD="$(generate_password)"
WORDPRESS_DB_NAME="wordpress"
WORDPRESS_REDIS_HOST="redis"
WORDPRESS_REDIS_PORT="6379"
WORDPRESS_TABLE_PREFIX="wp_"

REDIS_HOST="redis"
REDIS_PORT="6379"
REDIS_PASSWORD="$(generate_password 16)"
REDIS_MAXMEMORY="256mb"

CPU_LIMIT="${CPU_LIMIT}"
MEMORY_PER_SERVICE="${MEMORY_PER_SERVICE}"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT}"
UPLOAD_MAX_FILESIZE="64M"
PHP_INI_PATH="./deploy/configs/php.ini"
EOF

    # 追加 WordPress 密钥（带引号）
    generate_wordpress_keys >> .env

    # 转换行尾（防止 CRLF）
    if grep -q $'\r' .env; then
        print_yellow "检测到 CRLF 行尾，正在转换..."
        sed -i 's/\r$//' .env
    fi

    chmod 600 .env
    print_green ".env 文件创建成功"
}

# ---------- 部署 WordPress ----------
deploy_wordpress_stack() {
    print_blue "[步骤5] 部署 WordPress Docker 栈..."

    # 再次确保 .env 为 LF
    if grep -q $'\r' .env; then
        print_yellow ".env 含 CRLF 行尾，正在修正..."
        sed -i 's/\r$//' .env
    fi

    export $(grep -E '^[A-Z_][A-Z0-9_]*=' .env | xargs) 2>/dev/null || true

    print_blue "验证 CPU_LIMIT 展开情况..."
    echo "CPU_LIMIT (from env): ${CPU_LIMIT}"

    print_blue "Compose 展开结果（cpus 字段）:"
    $DOCKER_COMPOSE_CMD config | grep -A2 "cpus" || true

    print_blue "构建 Docker 镜像..."
    $DOCKER_COMPOSE_CMD build || { print_red "构建失败"; exit 1; }

    print_blue "启动容器..."
    if ! $DOCKER_COMPOSE_CMD up -d; then
        print_red "容器启动失败，打印日志："
        $DOCKER_COMPOSE_CMD logs --tail=30
        exit 1
    fi

    print_green "WordPress Docker 栈部署成功 ✅"
}

# ---------- 自动备份 ----------
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
    print_green "自动备份脚本已生成"
}

# ---------- 清理旧备份 ----------
setup_disk_space_management() {
    cat > /opt/scripts/cleanup.sh << 'EOF'
#!/bin/bash
find /opt/backups -type f -name "*.tar.gz" -mtime +7 -delete
echo -e "\033[32m清理7天前的备份文件完成\033[0m"
EOF
    chmod +x /opt/scripts/cleanup.sh
    print_green "磁盘清理脚本已生成"
}

# ---------- 显示部署信息 ----------
display_deployment_info() {
    print_blue "部署信息："
    print_green "访问地址: http://localhost"
    print_green "部署目录: /opt"
    print_green "备份目录: /opt/backups"
    print_yellow "确保防火墙开放 80/443 端口"
}

# ---------- 主程序 ----------
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

    print_green "部署完成 ✅"
}

main
