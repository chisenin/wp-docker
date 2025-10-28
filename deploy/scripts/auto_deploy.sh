#!/bin/bash
# ==================================================
# WordPress Docker 全栈自动部署脚本 - 生产环境优化版
# 修正版 v2025.10.29
# 改进：
# - WordPress 密钥使用 Base64 存储，防止 Python-dotenv 解析失败
# - 自动 Base64 解码后注入环境变量
# - 强化 CPU_LIMIT 验证输出
# ==================================================

set -e

print_blue()   { echo -e "\033[34m$1\033[0m"; }
print_green()  { echo -e "\033[32m$1\033[0m"; }
print_yellow() { echo -e "\033[33m$1\033[0m"; }
print_red()    { echo -e "\033[31m$1\033[0m"; }

# ---------- 随机密码 ----------
generate_password() {
    length=${1:-32}
    tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom | head -c "$length" 2>/dev/null || \
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c "$length"
}

# ---------- Base64 编码密钥 ----------
generate_wordpress_keys_b64() {
    local key_names=("AUTH_KEY" "SECURE_AUTH_KEY" "LOGGED_IN_KEY" "NONCE_KEY" \
                     "AUTH_SALT" "SECURE_AUTH_SALT" "LOGGED_IN_SALT" "NONCE_SALT")
    print_blue "生成 WordPress 安全密钥（Base64 编码）..."
    for key in "${key_names[@]}"; do
        val=$(generate_password 64 | base64 | tr -d '\n')
        echo "${key}=${val}"
    done
}

prepare_host_environment() {
    command -v docker >/dev/null || { print_red "未安装 Docker"; exit 1; }
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        print_red "未检测到 Docker Compose"; exit 1
    fi
    DOCKER_CMD="docker"
}

detect_host_environment() {
    print_blue "[步骤1] 检测主机环境..."
    OS=$(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null || echo "unknown")
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    AVAILABLE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    print_green "操作系统: $OS"
    print_green "CPU 核心数: $CPU_CORES"
    print_green "可用内存: ${AVAILABLE_RAM}MB"
}

collect_system_parameters() {
    print_blue "[步骤2] 检查系统工具..."
    for tool in curl wget tar dos2unix sed base64; do
        command -v "$tool" >/dev/null || apt-get install -y "$tool" -qq
    done
    print_green "Docker 版本: $($DOCKER_CMD --version)"
    print_green "Compose 版本: $($DOCKER_COMPOSE_CMD version)"
}

determine_deployment_directory() {
    DEPLOY_DIR="/opt"
    BACKUP_DIR="/opt/backups"
    mkdir -p "$DEPLOY_DIR" "$BACKUP_DIR"
    cd "$DEPLOY_DIR" || { print_red "无法进入 $DEPLOY_DIR"; exit 1; }
}

optimize_parameters() {
    print_blue "[步骤4] 生成 .env 文件..."
    MEMORY_PER_SERVICE=$((AVAILABLE_RAM * 2 / 7))
    CPU_LIMIT=$((CPU_CORES / 2))
    [ "$CPU_LIMIT" -lt 1 ] && CPU_LIMIT=1
    PHP_MEMORY_LIMIT="384M"

    cat > .env << EOF
# WordPress Docker 环境配置文件
DOCKERHUB_USERNAME=library
PHP_VERSION=8.3.26
NGINX_VERSION=1.27.2
MARIADB_VERSION=11.3.2
REDIS_VERSION=7.4.0
MYSQL_ROOT_PASSWORD=$(generate_password)
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=$(generate_password)
WORDPRESS_DB_HOST=mariadb:3306
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=$(generate_password)
WORDPRESS_DB_NAME=wordpress
WORDPRESS_REDIS_HOST=redis
WORDPRESS_REDIS_PORT=6379
WORDPRESS_TABLE_PREFIX=wp_
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=$(generate_password 16)
REDIS_MAXMEMORY=256mb
CPU_LIMIT=${CPU_LIMIT}
MEMORY_PER_SERVICE=${MEMORY_PER_SERVICE}
PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT}
UPLOAD_MAX_FILESIZE=64M
PHP_INI_PATH=./deploy/configs/php.ini
EOF

    generate_wordpress_keys_b64 >> .env

    if grep -q $'\r' .env; then
        sed -i 's/\r$//' .env
    fi

    chmod 600 .env
    print_green ".env 文件已生成（Base64 安全格式）"
}

# ---------- 部署 ----------
deploy_wordpress_stack() {
    print_blue "[步骤5] 部署 WordPress Docker 栈..."

    if grep -q $'\r' .env; then
        sed -i 's/\r$//' .env
    fi

    export $(grep -E '^[A-Z_][A-Z0-9_]*=' .env | xargs) 2>/dev/null

    # Base64 解码 WordPress 密钥
    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        decoded=$(echo "${!key}" | base64 --decode 2>/dev/null || echo "${!key}")
        export "$key"="$decoded"
    done

    print_blue "验证 CPU_LIMIT 展开情况..."
    echo "CPU_LIMIT (from env): ${CPU_LIMIT}"

    print_blue "Compose 展开结果（cpus 字段）:"
    $DOCKER_COMPOSE_CMD config | grep -A2 "cpus" || true

    print_blue "构建 Docker 镜像..."
    $DOCKER_COMPOSE_CMD build || { print_red "构建失败"; exit 1; }

    print_blue "启动容器..."
    if ! $DOCKER_COMPOSE_CMD up -d; then
        print_red "容器启动失败"
        $DOCKER_COMPOSE_CMD logs --tail=30
        exit 1
    fi
    print_green "WordPress Docker 栈部署成功 ✅"
}

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

display_deployment_info() {
    print_blue "部署信息："
    print_green "访问地址: http://localhost"
    print_green "部署目录: /opt"
    print_green "备份目录: /opt/backups"
}

main() {
    print_blue "=================================================="
    print_blue "WordPress Docker 全栈自动部署脚本 - Base64 修正版"
    print_blue "=================================================="

    prepare_host_environment
    detect_host_environment
    collect_system_parameters
    determine_deployment_directory
    optimize_parameters
    deploy_wordpress_stack
    setup_auto_backup
    display_deployment_info
    print_green "部署完成 ✅"
}

main
