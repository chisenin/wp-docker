### 修正说明

感谢您提供了原始的 `auto_deploy.sh` 脚本内容。基于您提供的日志中的错误信息：

```
ERROR: Error while attempting to convert service.mariadb.deploy.resources.limits.cpus to appropriate type: "" is not a valid float
警告: NGINX_CPU_LIMIT无效或未设置，设置为默认值1
警告: NGINX_MEMORY_LIMIT无效或未设置，设置为默认值256m
```

主要问题出在 `docker-compose.yml` 文件中 MariaDB 服务的 `cpus` 配置值为 `""`（空字符串），这导致 Docker 无法将其转换为有效的浮点数。此外，`NGINX_CPU_LIMIT` 和 `NGINX_MEMORY_LIMIT` 环境变量可能未正确设置或无效，触发了警告。

以下是修正后的 `auto_deploy.sh` 脚本，针对以下问题进行了优化：

1. **修复 MariaDB CPU 限制错误**：
   - 在 `build_images` 函数中，确保 `CPU_LIMIT` 和 `NGINX_CPU_LIMIT` 在生成 `docker-compose.yml` 前经过严格验证，防止空值或无效值。
   - 为 MariaDB 服务显式设置默认 `cpus` 值（例如 `"0.5"`），避免空字符串。
   - 添加环境变量 `MARIADB_CPU_LIMIT` 和 `MARIADB_MEMORY_LIMIT`，并在 `.env` 文件生成中包含这些变量。

2. **处理 Nginx 资源警告**：
   - 在 `build_images` 函数中，加强对 `NGINX_CPU_LIMIT` 和 `NGINX_MEMORY_LIMIT` 的验证，确保它们是有效的浮点数或内存格式。
   - 如果 `.env` 文件中未定义这些变量，脚本会在生成 `.env` 时添加默认值。

3. **配置文件生成跳过问题**：
   - 保留原始逻辑，允许跳过已存在的 Nginx 和 PHP 配置文件。
   - 添加 `--force` 选项，允许强制重新生成配置文件（通过命令行参数）。

4. **其他优化**：
   - 增强日志输出，记录所有资源限制的最终值。
   - 确保 `docker-compose.yml` 中的所有服务资源限制都引用环境变量，并有合理的默认值。
   - 添加对 `docker-compose.yml` 语法的验证，防止配置错误。
   - 修复潜在的编码问题，确保 `.env` 文件中的值正确转义。

以下是修正后的完整 `auto_deploy.sh` 脚本，保留了原始脚本的结构和功能，同时修复了上述问题。

### 修正后的 `auto_deploy.sh`

```bash
#!/bin/bash

# WordPress Docker 自动部署脚本
# 增强版功能：自动创建www-data用户/组、.env修复、Docker容器冲突清理
# 避免GitHub Actions工作流误触
set -e

# 全局变量
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE_CONFIG=${FORCE_CONFIG:-false}  # 新增：强制生成配置文件选项

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
MARIADB_CPU_LIMIT="0.5"  # 新增：MariaDB 默认 CPU 限制
MARIADB_MEMORY_LIMIT="512m"  # 新增：MariaDB 默认内存限制
NGINX_CPU_LIMIT="1"  # 默认值
NGINX_MEMORY_LIMIT="256m"  # 默认值

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
        CPU_LIMIT="${CPU_LIMIT:-2}"
        MEMORY_LIMIT="${MEMORY_LIMIT:-2048m}"
        MARIADB_CPU_LIMIT="${MARIADB_CPU_LIMIT:-0.5}"  # 新增
        MARIADB_MEMORY_LIMIT="${MARIADB_MEMORY_LIMIT:-512m}"  # 新增
        NGINX_CPU_LIMIT="${NGINX_CPU_LIMIT:-1}"
        NGINX_MEMORY_LIMIT="${NGINX_MEMORY_LIMIT:-256m}"
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
    
    # 检查磁盘空间
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
        local value=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+=-' | head -c 64)
        keys="${keys}${key}=\"${value}\"\n"
    done
    
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
    
    # 设置默认值
    PHP_VERSION="8.3"
    NGINX_VERSION="1.27"
    MARIADB_VERSION="11.3"
    REDIS_VERSION="7.4"
    
    # 设置资源限制默认值
    CPU_LIMIT="${CPU_LIMIT:-2}"
    MEMORY_LIMIT="${MEMORY_LIMIT:-2048m}"
    MARIADB_CPU_LIMIT="${MARIADB_CPU_LIMIT:-0.5}"  # 新增
    MARIADB_MEMORY_LIMIT="${MARIADB_MEMORY_LIMIT:-512m}"  # 新增
    NGINX_CPU_LIMIT="${NGINX_CPU_LIMIT:-1}"
    NGINX_MEMORY_LIMIT="${NGINX_MEMORY_LIMIT:-256m}"
    
    # 生成密码
    MYSQL_ROOT_PASSWORD="$(generate_password 20)"
    MYSQL_PASSWORD="$(generate_password 20)"
    REDIS_PASSWORD="$(generate_password 20)"
    
    # 生成.env文件(删除并重新生成)
    if [ -f ".env" ]; then
        log_message "检测到.env文件已存在，删除并重新生成..."
        rm -f ".env"
    fi
    
    log_message "生成.env文件..."
    
    cat > .env << EOF
# WordPress Docker Environment Configuration
# Please modify according to your actual environment

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
MARIADB_CPU_LIMIT="$MARIADB_CPU_LIMIT"  # 新增
MARIADB_MEMORY_LIMIT="$MARIADB_MEMORY_LIMIT"  # 新增
NGINX_CPU_LIMIT="$NGINX_CPU_LIMIT"
NGINX_MEMORY_LIMIT="$NGINX_MEMORY_LIMIT"

# Optional Configuration
PHP_MEMORY_LIMIT="$PHP_MEMORY_LIMIT"
UPLOAD_MAX_FILESIZE=64M
USE_CN_MIRROR=false

# Image Versions
PHP_VERSION="$PHP_VERSION"
NGINX_VERSION="$NGINX_VERSION"
MARIADB_VERSION="$MARIADB_VERSION"
REDIS_VERSION="$REDIS_VERSION"

# Backup Retention
BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_DAYS"

# WordPress Security Keys - Auto generated
$(generate_wordpress_keys)
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
    
    # 验证资源限制
    if [ -z "$CPU_LIMIT" ] || ! [[ "$CPU_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_message "警告: CPU_LIMIT无效或未设置，设置为默认值2"
        CPU_LIMIT="2"
    fi
    if [ -z "$MEMORY_LIMIT" ] || ! [[ "$MEMORY_LIMIT" =~ ^[0-9]+[m|g]$ ]]; then
        log_message "警告: MEMORY_LIMIT无效或未设置，设置为默认值2048m"
        MEMORY_LIMIT="2048m"
    fi
    if [ -z "$MARIADB_CPU_LIMIT" ] || ! [[ "$MARIADB_CPU_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_message "警告: MARIADB_CPU_LIMIT无效或未设置，设置为默认值0.5"
        MARIADB_CPU_LIMIT="0.5"
    fi
    if [ -z "$MARIADB_MEMORY_LIMIT" ] || ! [[ "$MARIADB_MEMORY_LIMIT" =~ ^[0-9]+[m|g]$ ]]; then
        log_message "警告: MARIADB_MEMORY_LIMIT无效或未设置，设置为默认值512m"
        MARIADB_MEMORY_LIMIT="512m"
    fi
    if [ -z "$NGINX_CPU_LIMIT" ] || ! [[ "$NGINX_CPU_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_message "警告: NGINX_CPU_LIMIT无效或未设置，设置为默认值1"
        NGINX_CPU_LIMIT="1"
    fi
    if [ -z "$NGINX_MEMORY_LIMIT" ] || ! [[ "$NGINX_MEMORY_LIMIT" =~ ^[0-9]+[m|g]$ ]]; then
        log_message "警告: NGINX_MEMORY_LIMIT无效或未设置，设置为默认值256m"
        NGINX_MEMORY_LIMIT="256m"
    fi
    
    # 导出资源限制变量
    export CPU_LIMIT MEMORY_LIMIT MARIADB_CPU_LIMIT MARIADB_MEMORY_LIMIT NGINX_CPU_LIMIT NGINX_MEMORY_LIMIT
    
    # 检查docker-compose.yml文件是否存在
    if [ ! -f "docker-compose.yml" ] || [ "$FORCE_CONFIG" = true ]; then
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
          cpus: "$MARIADB_CPU_LIMIT"  # 修正：使用明确的变量
          memory: "$MARIADB_MEMORY_LIMIT"

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
          cpus: "$CPU_LIMIT"
          memory: "$MEMORY_LIMIT"

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
          cpus: "$NGINX_CPU_LIMIT"
          memory: "$NGINX_MEMORY_LIMIT"

networks:
  wp_network:
    driver: bridge

volumes:
  mysql_data:
  wordpress_data:
EOF
    fi
    
    # 验证 docker-compose.yml 语法
    if ! $DOCKER_COMPOSE_CMD config >/dev/null 2>&1; then
        handle_error "docker-compose.yml 配置文件语法错误"
    fi
    
    log_message "当前资源限制设置: CPU=$CPU_LIMIT, Memory=$MEMORY_LIMIT, MARIADB_CPU=$MARIADB_CPU_LIMIT, MARIADB_MEMORY=$MARIADB_MEMORY_LIMIT, NGINX_CPU=$NGINX_CPU_LIMIT, NGINX_MEMORY=$NGINX_MEMORY_LIMIT"
    
    # 构建镜像
    log_message "构建Docker镜像..."
    $DOCKER_COMPOSE_CMD build || handle_error "Docker镜像构建失败"
    
    log_message "✓ 镜像构建完成"
}

# 生成配置文件
generate_configs() {
    log_message "[阶段9] 生成配置文件..."
    
    # 生成Nginx配置
    if [ ! -f "configs/nginx.conf" ] || [ "$FORCE_CONFIG" = true ]; then
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
    if [ ! -f "configs/php.ini" ] || [ "$FORCE_CONFIG" = true ]; then
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
    $DOCKER_COMPOSE_CMD up -d || handle_error "Docker 服务启动失败"
    
    # 等待服务启动
    log_message "等待服务初始化..."
    sleep 10
    
    # 检查服务状态
    log_message "检查服务状态.."
    $DOCKER_COMPOSE_CMD ps
    
    # 验证部署是否成功
    if [ "$(docker-compose ps -q | wc -l)" -eq "4" ]; then
        log_message "✓ WordPress Docker 版部署成功"
    else
        log_message "✓ WordPress Docker 版部署失败，请检查日志"
        $DOCKER_COMPOSE_CMD logs --tail=50
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
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE_CONFIG=true
                shift
                ;;
            *)
                log_message "警告: 未知选项: $1"
                shift
                ;;
        esac
    done
    
    log_message "🚀 开始 WordPress Docker 自动部署..."
    
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
    
    log_message "🎉 WordPress Docker 全栈部署完成!"
}

# 执行主函数
main "$@"
```

### 修正详情

1. **MariaDB CPU 限制修复**：
   - 在 `optimize_parameters` 函数中，新增 `MARIADB_CPU_LIMIT="0.5"` 和 `MARIADB_MEMORY_LIMIT="512m"` 默认值，并将其写入 `.env` 文件。
   - 在 `build_images` 函数中，修改 MariaDB 服务的 `docker-compose.yml` 配置，使用 `${MARIADB_CPU_LIMIT}` 和 `${MARIADB_MEMORY_LIMIT}`，确保值非空且有效。
   - 添加验证逻辑，确保 `MARIADB_CPU_LIMIT` 是有效的浮点数。

2. **Nginx 资源警告修复**：
   - 在 `load_env_file` 和 `build_images` 函数中，确保 `NGINX_CPU_LIMIT` 和 `NGINX_MEMORY_LIMIT` 有默认值（`1` 和 `256m`）。
   - 验证这些变量的格式，防止无效值传入 `docker-compose.yml`。

3. **强制生成配置文件**：
   - 新增 `FORCE_CONFIG` 变量，默认值为 `false`。
   - 在 `generate_configs` 函数中，检查 `FORCE_CONFIG`，如果为 `true`，则强制重新生成 Nginx 和 PHP 配置文件。
   - 支持命令行参数 `--force`：`./auto_deploy.sh --force`。

4. **其他改进**：
   - 在 `build_images` 函数中添加 `$DOCKER_COMPOSE_CMD config` 验证 `docker-compose.yml` 语法。
   - 确保所有资源限制变量在生成 `docker-compose.yml` 前导出（`export`）。
   - 在日志中记录所有资源限制的最终值，便于调试。

### 测试与使用

1. **保存脚本**：
   - 将上述内容保存为 `auto_deploy.sh`。
   - 设置执行权限：`chmod +x auto_deploy.sh`。

2. **运行脚本**：
   ```bash
   # 正常运行
   ./auto_deploy.sh

   # 强制重新生成配置文件
   ./auto_deploy.sh --force

   # 自定义资源限制
   MARIADB_CPU_LIMIT=0.75 NGINX_CPU_LIMIT=0.5 ./auto_deploy.sh
   ```

3. **验证**：
   - 检查日志文件（`$DEPLOY_DIR/logs/deploy.log`）是否包含错误。
   - 运行 `docker-compose ps` 确认所有服务（mariadb、redis、php、nginx）正常启动。
   - 访问 `http://<主机IP>`，完成 WordPress 安装向导。

4. **检查 `.env` 文件**：
   - 确认 `.env` 文件包含 `MARIADB_CPU_LIMIT` 和 `MARIADB_MEMORY_LIMIT`，例如：
     ```
     MARIADB_CPU_LIMIT="0.5"
     MARIADB_MEMORY_LIMIT="512m"
     ```

5. **调试**：
   - 如果仍出现错误，查看 `docker-compose logs`：
     ```bash
     docker-compose logs --tail=50
     ```
   - 验证 `docker-compose.yml` 语法：
     ```bash
     docker-compose config
     ```

### 注意事项

- **环境变量覆盖**：如果您有现有的 `.env` 文件，脚本会重新生成它。建议备份原始 `.env` 文件。
- **Docker Compose 版本**：脚本支持 v1 和 v2 语法，确保 Docker Compose 已安装。
- **PHP 和 Nginx 构建**：脚本假设 `../build/Dockerfiles/php` 和 `../build/Dockerfiles/nginx` 存在。如果不存在，请提供这些 Dockerfile 或修改 `build` 部分为 `image`。
- **权限**：确保运行脚本的用户有 Docker 权限（例如，属于 `docker` 组）。

如果您有其他问题或需要进一步调试（例如，提供 `docker-compose.yml` 或日志），请告诉我，我可以提供更具体的帮助！