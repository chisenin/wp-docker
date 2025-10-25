#!/bin/bash

# WordPress Docker 自动部署脚本
# 增强版功能：自动创建www-data用户/组、.env修复、Docker容器冲突清理
# 避免GitHub Actions工作流误触
set -e

# 全局变量
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Create logs directory first to ensure log file can be written
mkdir -p "$DEPLOY_DIR/logs" 2>/dev/null

# 彩色输出函数
print_blue() {
    echo -e "\033[34m$1\033[0m"
}

OS_TYPE=""
OS_VERSION=""
CPU_CORES=0
AVAILABLE_RAM=0
AVAILABLE_DISK=0
PHP_MEMORY_LIMIT="512M"
BACKUP_RETENTION_DAYS=7
LOG_FILE="$DEPLOY_DIR/logs/deploy.log"
# 资源限制默认值
CPU_LIMIT="2"
MEMORY_LIMIT="2048m"

# 错误处理函数
handle_error() {
    echo "错误: $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 错误: $1" >> "$LOG_FILE"
    exit 1
}

# 记录日志
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
}

# 从.env文件加载环境变量
load_env_file() {
    if [ -f ".env" ]; then
        log_message "从.env文件加载环境变量..."
        # 安全加载.env文件，避免语法错误导致脚本失败
        while IFS= read -r line || [[ -n "$line" ]]; do
            # 跳过空行和注释行
            [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
            
            # 提取key和value（支持引号和不支持等号的情况）
            if [[ "$line" =~ ^([A-Za-z0-9_]+)\s*=\s*(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                
                # 移除引号（如果有）
                value="${value%\"}"
                value="${value#\"}"
                value="${value%\'}"
                value="${value#\'}"
                
                # 设置环境变量
                export "$key"="$value"
            fi
        done < .env
        
        # 确保资源限制变量有值
        if [ -z "$CPU_LIMIT" ]; then
            log_message "警告: CPU_LIMIT未设置，使用默认值"
            CPU_LIMIT="2"
        fi
        if [ -z "$MEMORY_LIMIT" ]; then
            log_message "警告: MEMORY_LIMIT未设置，使用默认值"
            MEMORY_LIMIT="2048m"
        fi
    else
        log_message "警告: .env文件不存在"
    fi
}

# 检测主机环境
detect_host_environment() {
    log_message "[阶段1] 检测主机环境..."
    
    # Logs directory already created at script start
    
    # 从.env文件加载环境变量
    load_env_file
    
    # 检测操作系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        OS_VERSION="$(cat /etc/debian_version)"
    elif [ -f /etc/centos-release ]; then
        OS_TYPE="centos"
        OS_VERSION="$(cat /etc/centos-release | sed 's/^.*release //;s/ .*$//')"
    elif [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"
        OS_VERSION="$(cat /etc/alpine-release)"
    else
        handle_error "不支持的操作系统类型"
    fi
    
    log_message "操作系统: $OS_TYPE $OS_VERSION"
}

# 环境准备：创建www-data用户/组、修改.env文件、清理docker冲突
environment_preparation() {
    log_message "[阶段2] 环境准备..."
    
    # 1. 检查并创建www-data用户/组
    log_message "检查并创建www-data用户/组.."
    if ! id -u www-data >/dev/null 2>&1; then
        log_message "创建www-data用户和组..."
        # 根据不同系统创建用户
        if [[ "$OS_TYPE" == "alpine" ]]; then
            addgroup -g 33 -S www-data || handle_error "创建www-data组失败"
            adduser -u 33 -D -S -G www-data www-data || handle_error "创建www-data用户失败"
        else
            groupadd -g 33 www-data 2>/dev/null || :
            useradd -u 33 -g www-data -s /sbin/nologin -M www-data 2>/dev/null || :
        fi
        log_message "✓ www-data用户/组创建成功"
    else
        log_message "✓ www-data用户已存在"
    fi
    
    # 2. 修复.env文件
    if [ -f "$DEPLOY_DIR/.env" ]; then
        log_message "修复.env文件中的特殊字符问题..."
        # 创建临时文件
        TEMP_FILE="$DEPLOY_DIR/.env.tmp"
        # 复制.env文件，确保所有值用双引号包裹
        while IFS= read -r line || [[ -n "$line" ]]; do
            # 跳过注释和空行
            if [[ "$line" == \#* ]] || [[ -z "$line" ]]; then
                echo "$line" >> "$TEMP_FILE"
                continue
            fi
            
            # 检查是否已经有等号
            if [[ "$line" == *=* ]]; then
                key="${line%%=*}"
                value="${line#*=}"
                
                # 如果值没有被引号包裹，添加双引号
                if [[ "$value" != \"* && "$value" != \'* ]]; then
                    echo "$key=\"$value\"" >> "$TEMP_FILE"
                else
                    echo "$line" >> "$TEMP_FILE"
                fi
            else
                echo "$line" >> "$TEMP_FILE"
            fi
        done < "$DEPLOY_DIR/.env"
        
        # 替换原文件
        mv "$TEMP_FILE" "$DEPLOY_DIR/.env"
        log_message "✓ .env file has been fixed"
    fi
    
    # 3. 清理Docker容器冲突
    log_message "检查并清理Docker容器冲突..."
    # 检查是否有重名容器在运行
    CONTAINERS=("wp_db" "wp_redis" "wp_php" "wp_nginx")
    for container in "${CONTAINERS[@]}"; do
        if docker ps -a | grep -q "$container"; then
            log_message "Detected conflicting container: $container, attempting to stop and remove..."
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
            log_message "✓ Container $container has been removed"
        fi
    done
    
    # 检查是否有重名网络
    if docker network ls | grep -q "wp_network"; then
        log_message "Detected conflicting network: wp_network, attempting to remove..."
        docker network rm wp_network 2>/dev/null || true
        log_message "✓ Network wp_network has been removed"
    fi
}

# 收集系统参数
collect_system_parameters() {
    log_message "[阶段3] 收集系统参数..."
    
    # 获取CPU核心数
    CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)
    log_message "CPU核心数: $CPU_CORES"
    
    # 获取可用内存(MB)
    AVAILABLE_RAM=$(free -m | grep Mem | awk '{print $2}')
    log_message "可用内存: ${AVAILABLE_RAM}MB"
    
    # 获取可用磁盘空间(GB)
    AVAILABLE_DISK=$(df -h / | tail -1 | awk '{print $4}' | sed 's/G//')
    log_message "可用磁盘空间: ${AVAILABLE_DISK}GB"
    
    # 检查Docker是否安装，不自动安装以避免权限问题
    if ! command -v docker >/dev/null 2>&1; then
        log_message "警告: Docker未找到。请确保Docker已安装并在PATH中"
        # 不自动安装，因为需要root权限
    else
        log_message "✓ Docker 已安装"
    fi
    
    # 检查Docker Compose (支持v1和v2语法)
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
        log_message "✓ Docker Compose v1 已安装"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
        log_message "✓ Docker Compose v2 已安装"
    else
        log_message "警告: Docker Compose未找到。请确保Docker Compose已安装"
        DOCKER_COMPOSE_CMD="docker compose"  # 默认使用v2语法
    fi
    
    # 检查磁盘空间(使用纯bash方式，避免依赖bc命令)
    # AVAILABLE_DISK已经是数字形式(例如"17")，无需再提取数字部分
    if (( $(echo "$AVAILABLE_DISK < 10" | awk '{print ($1 < 10) ? 1 : 0}') )); then
        handle_error "磁盘空间不足，需要至少10GB可用空间"
    fi
    
    # 检查内存
    if [[ "$AVAILABLE_RAM" -lt 2048 ]]; then
        log_message "警告: 可用内存低于2GB，可能影响性能"
    fi
}

# 确定部署目录
determine_deployment_directory() {
    log_message "[阶段4] 确定部署目录..."
    
    # 检查目录是否存在，不存在则创建
    if [ ! -d "$DEPLOY_DIR" ]; then
        mkdir -p "$DEPLOY_DIR" || handle_error "创建部署目录失败"
    fi
    
    # 切换到部署目录
    cd "$DEPLOY_DIR" || handle_error "切换到部署目录失败"
    
    # 创建必要的目录结构
    mkdir -p html configs backups scripts logs || handle_error "创建目录结构失败"
    
    log_message "部署目录: $DEPLOY_DIR"
}

# 生成密码
generate_password() {
    local length=${1:-16}
    # 使用urandom生成随机密码
    local password=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=[]{}|;:,.<>?~' | head -c "$length")
    echo "$password"
}

# 生成WordPress密钥
generate_wordpress_keys() {
    local keys=""
    
    # 生成所有需要的WordPress密钥
    local key_names=("WORDPRESS_AUTH_KEY" "WORDPRESS_SECURE_AUTH_KEY" "WORDPRESS_LOGGED_IN_KEY" "WORDPRESS_NONCE_KEY" "WORDPRESS_AUTH_SALT" "WORDPRESS_SECURE_AUTH_SALT" "WORDPRESS_LOGGED_IN_SALT" "WORDPRESS_NONCE_SALT")
    
    for key in "${key_names[@]}"; do
        # 为每个密钥生成64位随机字符，并确保特殊字符被正确转义
        local value=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+=-' | head -c 64)
        # 直接添加到keys字符串，不需要额外转义
        keys="${keys}${key}="'"'"$value"'"'"\n"
    done
    
    # 不使用echo -e，避免额外的转义问题
    printf "%s" "$keys"
}

# 优化参数
optimize_parameters() {
    log_message "[阶段5] 优化参数..."
    
    # 根据系统资源优化PHP内存限制
    if [ "$AVAILABLE_RAM" -lt 2048 ]; then
        PHP_MEMORY_LIMIT="256M"
    elif [ "$AVAILABLE_RAM" -gt 4096 ]; then
        PHP_MEMORY_LIMIT="1024M"
    fi
    
    log_message "PHP内存限制: $PHP_MEMORY_LIMIT"
    
    # 生成.env文件(删除并重新生成)
    if [ -f ".env" ]; then
        log_message "检测到.env文件已存在，删除并重新生成..."
        rm -f ".env"
    fi
    
    log_message "生成.env文件..."
    
    # 生成密码
    MYSQL_ROOT_PASSWORD="$(generate_password 20)"
    MYSQL_PASSWORD="$(generate_password 20)"
    REDIS_PASSWORD="$(generate_password 20)"
    
    # 生成WordPress密钥
    wp_keys="$(generate_wordpress_keys)"
    
    # 定义版本
    PHP_VERSION="8.1"
    NGINX_VERSION="1.24"
    MARIADB_VERSION="10.11"
    REDIS_VERSION="7.0"
    
    # 创建.env文件，使用安全的格式确保Python-dotenv可以正确解析
        # 首先将生成的WordPress密钥保存到临时变量
        local wp_security_keys="$wp_keys"
        
        # 使用普通的Here Document，不使用单引号，确保变量能正确展开
        cat > .env << EOF
# Docker Configuration
COMPOSE_PROJECT_NAME=wp_docker

# Database Configuration
MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"
MYSQL_DATABASE="wordpress"
MYSQL_USER="wordpress"
MYSQL_PASSWORD="$MYSQL_PASSWORD"

# WordPress Configuration
WORDPRESS_DB_HOST="mariadb"
WORDPRESS_DB_USER="wordpress"
WORDPRESS_DB_PASSWORD="$MYSQL_PASSWORD"
WORDPRESS_DB_NAME="wordpress"
WORDPRESS_TABLE_PREFIX="wp_"

# Redis Configuration
REDIS_HOST="redis"
REDIS_PASSWORD="$REDIS_PASSWORD"
REDIS_PORT=6379
REDIS_MAXMEMORY=256mb

# Resource Limits
MEMORY_LIMIT="$MEMORY_LIMIT"
CPU_LIMIT="$CPU_LIMIT"

# Optional Configuration
PHP_MEMORY_LIMIT=512M
UPLOAD_MAX_FILESIZE=64M
USE_CN_MIRROR=false

# Image Versions
PHP_VERSION="$PHP_VERSION"
NGINX_VERSION="$NGINX_VERSION"
MARIADB_VERSION="$MARIADB_VERSION"
REDIS_VERSION="$REDIS_VERSION"

# Backup Retention
BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_DAYS"

# WordPress Security Keys
$wp_security_keys
EOF
        
        # 确保文件权限正确
        chmod 600 .env
    
    log_message "✓ .env文件生成完成"
    # 从新生成的.env文件加载环境变量
    source .env
}

# 权限设置
set_permissions() {
    log_message "[阶段6] 设置权限..."
    
    # 设置目录权限
    log_message "设置部署目录权限..."
    chown -R www-data:www-data "$DEPLOY_DIR/html" 2>/dev/null || :
    chmod -R 755 "$DEPLOY_DIR/html" 2>/dev/null || :
    
    # 设置备份目录权限
    chmod 700 "$DEPLOY_DIR/backups" 2>/dev/null || :
    
    # 设置脚本权限
    chmod +x "$DEPLOY_DIR/scripts"/* 2>/dev/null || :
    
    log_message "✓ 权限设置完成"
}

# 容器清理
cleanup_old_containers() {
    log_message "[阶段7] 清理容器.."
    
    # 停止并移除旧的Docker容器
    log_message "检查旧的Docker容器..."
    
    # 检查并停止相关服务
    if docker-compose ps | grep -q "Up"; then
        log_message "停止现有服务..."
        docker-compose down --remove-orphans || log_message "警告: 停止服务时出现问题"
    fi
    
    # 清理悬空镜像
    if [ "$(docker images -f "dangling=true" -q)" != "" ]; then
        log_message "清理悬空镜像..."
        docker rmi $(docker images -f "dangling=true" -q) 2>/dev/null || :
    fi
    
    log_message "✓ 容器清理完成"
}

# 镜像构建
build_images() {
    log_message "[阶段8] 构建镜像..."
    
    # 检查docker-compose.yml文件是否存在
    if [ ! -f "docker-compose.yml" ]; then
        log_message "生成docker-compose.yml文件..."
        
        cat > docker-compose.yml << EOF
version: '3.8'

services:
  mariadb:
    image: mariadb:$MARIADB_VERSION
    container_name: wp_db
    restart: unless-stopped
    networks:
      - wp_network
    volumes:
      - ./backups/mysql:/var/lib/mysql
      - ./configs/mariadb:/etc/mysql/conf.d
    environment:
      - MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
      - MYSQL_DATABASE=$MYSQL_DATABASE
      - MYSQL_USER=$MYSQL_USER
      - MYSQL_PASSWORD=$MYSQL_PASSWORD
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-u", "root", "-p$MYSQL_ROOT_PASSWORD"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "${CPU_LIMIT:-2}"
          memory: "${MEMORY_LIMIT:-2048m}"

  redis:
    image: redis:$REDIS_VERSION
    container_name: wp_redis
    restart: unless-stopped
    networks:
      - wp_network
    command: redis-server --requirepass $REDIS_PASSWORD
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: "128m"

  php:
    build:
      context: ../build/Dockerfiles/php
      args:
        PHP_VERSION: $PHP_VERSION
    container_name: wp_php
    restart: unless-stopped
    networks:
      - wp_network
    volumes:
      - ./html:/var/www/html
      - ./configs/php.ini:/usr/local/etc/php/conf.d/custom.ini
    environment:
      - MYSQL_HOST=$WORDPRESS_DB_HOST
      - MYSQL_DATABASE=$WORDPRESS_DB_NAME
      - MYSQL_USER=$WORDPRESS_DB_USER
      - MYSQL_PASSWORD=$WORDPRESS_DB_PASSWORD
      - REDIS_HOST=$REDIS_HOST
      - REDIS_PASSWORD=$REDIS_PASSWORD
    healthcheck:
      test: ["CMD", "php-fpm", "-t"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "${CPU_LIMIT:-2}"
          memory: "${MEMORY_LIMIT:-2048m}"

  nginx:
    build:
      context: ../build/Dockerfiles/nginx
      args:
        NGINX_VERSION: $NGINX_VERSION
    container_name: wp_nginx
    restart: unless-stopped
    networks:
      - wp_network
    volumes:
      - ./html:/var/www/html
      - ./configs/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./configs/conf.d:/etc/nginx/conf.d:ro
      - ./logs/nginx:/var/log/nginx
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      - php
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "${NGINX_CPU_LIMIT:-1}"
          memory: "${NGINX_MEMORY_LIMIT:-256m}"

networks:
  wp_network:
    driver: bridge

volumes:
  mysql_data:
  wordpress_data:
EOF
    fi
    
    # 构建镜像
    log_message "构建Docker镜像..."
    docker-compose build
    
    log_message "✓ 镜像构建完成"
}

# 生成配置文件
generate_configs() {
    log_message "[阶段9] 生成配置文件..."
    
    # 生成Nginx配置
    if [ ! -f "configs/nginx.conf" ]; then
        log_message "生成Nginx配置文件..."
        
        # 根据CPU核心数优化worker_processes
        local worker_processes="auto"
        if [[ "$OS_TYPE" == "alpine" ]]; then
            worker_processes="$(nproc)"
        fi
        
        # 创建nginx配置目录
        mkdir -p configs/conf.d
        
        # 主配置文件
        cat > configs/nginx.conf << EOF
user  nginx;
worker_processes  $worker_processes;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
}
EOF
        
        # 站点配置文件
        cat > configs/conf.d/default.conf << EOF
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 64k;
        fastcgi_buffers 4 64k;
        fastcgi_busy_buffers_size 128k;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
EOF
        
        log_message "✓ Nginx 配置文件生成完成"
    else
        log_message "警告: Nginx 配置文件已存在，跳过生成"
    fi
    
    # 生成 PHP 配置文件
    if [ ! -f "configs/php.ini" ]; then
        log_message "生成 PHP 配置文件..."
        
        # 根据内存大小调整 opcache 配置
        local opcache_memory="128"
        if [ "$AVAILABLE_RAM" -lt 2048 ]; then
            opcache_memory="64"
        elif [ "$AVAILABLE_RAM" -gt 4096 ]; then
            opcache_memory="256"
        fi
        
        cat > configs/php.ini << EOF
[PHP]
memory_limit = $PHP_MEMORY_LIMIT
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
max_input_time = 300
default_socket_timeout = 300

date.timezone = Asia/Shanghai
display_errors = Off
display_startup_errors = Off
log_errors = On
error_log = /var/log/php/error.log

[opcache]
opcache.enable = 1
opcache.memory_consumption = $opcache_memory
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 4000
opcache.revalidate_freq = 60
opcache.fast_shutdown = 1
EOF
        
        log_message "✓ PHP 配置文件生成完成"
    else
        log_message "警告: PHP 配置文件已存在，跳过生成"
    fi
}

# 服务启动
start_services() {
    log_message "[阶段10] 启动服务..."
    
    # 下载 WordPress(如果需要)
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
            log_message "下载 WordPress 最新版本.."
            
            # 下载并解压 WordPress
            local temp_file="/tmp/wordpress-latest.tar.gz"
            
            if command -v wget >/dev/null; then
                wget -q -O "$temp_file" https://wordpress.org/latest.tar.gz
            else
                curl -s -o "$temp_file" https://wordpress.org/latest.tar.gz
            fi
            
            if [ -f "$temp_file" ]; then
                # 解压到 html 目录
                tar -xzf "$temp_file" -C .
                mv wordpress/* html/
                rm -rf wordpress "$temp_file"
                
                # 设置权限
                log_message "设置文件权限..."
                chown -R www-data:www-data html
                
                log_message "✓ WordPress 下载并解压完成"
            else
                log_message "警告: WordPress 下载失败，请手动下载并解压到 html 目录"
            fi
        else
            log_message "✓ html 目录已存在内容，跳过 WordPress 下载"
        fi
    else
        log_message "✓ WordPress 配置文件已存在，跳过下载"
    fi
    
    # 启动服务
    log_message "启动 Docker 服务..."
    docker-compose up -d
    
    # 等待服务启动
    log_message "等待服务初始化..."
    sleep 10
    
    # 检查服务状态
    log_message "检查服务状态.."
    docker-compose ps
    
    # 验证部署是否成功
    if [ "$(docker-compose ps -q | wc -l)" -eq "4" ]; then
        log_message "✓ WordPress Docker 版部署成功"
    else
        log_message "✓ WordPress Docker 版部署失败，请检查日志"
        docker-compose logs --tail=50
    fi
}

# 备份配置
setup_backup_config() {
    log_message "[阶段11] 设置备份配置..."
    
    # 创建备份脚本
    cat > "$DEPLOY_DIR/scripts/backup_db.sh" << 'EOF'
#!/bin/bash

# 获取脚本所在目录的父目录
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$DEPLOY_DIR/backups"

# 从 .env 文件加载环境变量
if [ -f "$DEPLOY_DIR/.env" ]; then
    # 只导出需要的数据库相关环境变量
    export $(grep -E '^MYSQL_|^BACKUP_RETENTION_DAYS' "$DEPLOY_DIR/.env" | xargs)
fi

# 设置默认值
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-default_password}
MYSQL_DATABASE=${MYSQL_DATABASE:-wordpress}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}

# 创建备份文件
BACKUP_FILE="$BACKUP_DIR/db-$(date +%Y%m%d_%H%M%S).sql.gz"

echo "开始备份数据库: $MYSQL_DATABASE"

# 执行备份
docker exec -t wp_db mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" | gzip > "$BACKUP_FILE"

if [ $? -eq 0 ]; then
    echo "✓ 数据库备份成功: $BACKUP_FILE"
    
    # 删除旧备份
    echo "清理 $BACKUP_RETENTION_DAYS 天前的备份.."
    find "$BACKUP_DIR" -name "db-*.sql.gz" -mtime +"$BACKUP_RETENTION_DAYS" -delete
    echo "✓ 旧备份清理完成"
else
    echo "✓ 数据库备份失败"
fi
EOF
    
    # 设置执行权限
    chmod +x "$DEPLOY_DIR/scripts/backup_db.sh"
    
    # 创建 cron 任务
    CRON_JOB="0 3 * * * $DEPLOY_DIR/scripts/backup_db.sh >> $DEPLOY_DIR/logs/backup.log 2>&1"
    
    # 检查是否已存在相同的 cron 任务
    if ! crontab -l 2>/dev/null | grep -q "backup_db.sh"; then
        # 添加到 cron
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        log_message "✓ 数据库备份 cron 任务已创建(每天凌晨 3 点执行)"
    else
        log_message "警告: 数据库备份 cron 任务已存在"
    fi
    
    # 立即执行一次备份测试
    log_message "执行备份测试..."
    "$DEPLOY_DIR/scripts/backup_db.sh"
}

# 显示部署信息
display_deployment_info() {
    log_message "=================================================="
    log_message "部署完成!"
    log_message "=================================================="
    
    # 获取主机 IP
    local HOST_IP=$(hostname -I | awk '{print $1}')
    
    log_message "访问地址: http://$HOST_IP"
    log_message ""
    log_message "部署详情:"
    log_message "  - 操作系统: $OS_TYPE $OS_VERSION"
    log_message "  - CPU 核心: $CPU_CORES 核(限制使用: $((CPU_CORES / 2)) 核)"
    log_message "  - 可用内存: ${AVAILABLE_RAM}MB(限制使用: $((AVAILABLE_RAM / 2))MB)"
    log_message "  - 部署目录: $DEPLOY_DIR"
    log_message "  - 备份目录: $DEPLOY_DIR/backups"
    log_message "  - 备份保留: $BACKUP_RETENTION_DAYS 天"
    log_message ""
    log_message "数据库信息"
    log_message "  - 数据库名: wordpress"
    log_message "  - 用户名: wordpress"
    log_message "  - 密码: 请查看 .env 文件中的 MYSQL_PASSWORD"
    log_message "  - 主机: mariadb"
    log_message ""
    log_message "自动化功能"
    log_message "  - ✓ 每天数据库自动备份(凌晨 3 点)"
    log_message "  - ✓ 权限自动设置"
    log_message "  - ✓ 环境自动修复"
    log_message "  - ✓ 容器冲突自动清理"
    log_message ""
    log_message "后续步骤:"
    log_message "1. 打开浏览器访问上述地址"
    log_message "2. 完成 WordPress 安装向导"
    log_message "3. 建议安装 Redis Object Cache 插件启用缓存"
    log_message ""
    log_message "重要: 请备份 .env 文件，包含所有敏感信息"
    log_message "=================================================="
}

# 主函数
main() {
    log_message "馃殌 开始 WordPress Docker 自动部署..."
    
    # 执行各阶段
    detect_host_environment       # 检测主机环境
    environment_preparation       # 环境准备
    collect_system_parameters     # 收集系统参数
    determine_deployment_directory # 确定部署目录
    optimize_parameters           # 优化参数
    set_permissions               # 权限设置
    cleanup_old_containers        # 容器清理
    generate_configs              # 生成配置文件
    build_images                  # 镜像构建
    start_services                # 服务启动
    setup_backup_config           # 备份配置
    display_deployment_info       # 显示部署信息
    
    log_message "馃帀 WordPress Docker 全栈部署完成!"
}

# 执行主函数
main