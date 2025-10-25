### 错误分析

从您提供的错误日志来看，`auto_deploy.sh` 脚本在执行时出现了大量错误，提示类似 `command not found`，并且包含了乱码（如 `\357\273\277###`、`馃殌` 等）。这些错误表明脚本文件的编码或格式存在问题，导致 Bash 无法正确解析。以下是具体问题和原因：

1. **文件编码问题**：
   - 日志中的 `\357\273\277` 是 UTF-8 BOM（Byte Order Mark，字节顺序标记，`EF BB BF`），表明脚本文件可能以 UTF-8-BOM 编码保存，而 Bash 脚本需要纯 UTF-8 或 ASCII 编码。
   - 中文字符（如 `馃殌`、`馃帀`）出现在错误输出中，可能是因为脚本在保存或传输过程中引入了不兼容的字符编码，或者复制粘贴时引入了不可见字符。

2. **脚本内容被错误解析**：
   - 错误如 `auto_deploy.sh: line 1: $'\357\273\277###': command not found` 表明 Bash 将注释或文档说明（如 `### 修正说明`）误认为是命令，可能是因为 BOM 或换行符问题导致脚本开头被破坏。
   - 后续错误（如 `docker-compose.yml: command not found`、`cpus: command not found`）表明脚本的每一行都被错误解析，可能是文件格式损坏或包含不可执行的字符。

3. **换行符问题**：
   - 如果脚本是在 Windows 环境下编辑的，可能包含 Windows 换行符（CRLF，`\r\n`），而 Linux/Unix 环境期望 Unix 换行符（LF，`\n`）。这会导致 Bash 解析失败，出现 `command not found` 错误。

4. **文件传输或复制问题**：
   - 脚本可能在从某个来源（如 GitHub 或其他编辑器）复制到服务器时，引入了额外的字符、BOM 或格式问题。
   - 日志中的中文乱码（如 `警告:`、`修复后的`）可能是复制粘贴时从文档或其他来源带入了不兼容的字符。

### 解决方案

为了解决这些问题，我们需要：
1. 移除 UTF-8 BOM 和不兼容字符，确保脚本使用纯 UTF-8 编码。
2. 转换为 Unix 换行符（LF）。
3. 确保脚本内容完整且可执行。
4. 提供一个干净的、修正后的 `auto_deploy.sh` 文件，避免复制粘贴引入问题。

以下是修正后的 `auto_deploy.sh` 脚本，已移除所有可能导致编码问题的注释，并确保使用纯 UTF-8 编码和 Unix 换行符。脚本内容基于您提供的原始脚本，并包含之前修复的 MariaDB CPU 限制错误和 Nginx 资源警告问题。

### 修正后的 `auto_deploy.sh`

```bash
#!/bin/bash

set -e

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE_CONFIG=${FORCE_CONFIG:-false}

mkdir -p "$DEPLOY_DIR/logs" 2>/dev/null

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
CPU_LIMIT="2"
MEMORY_LIMIT="2048m"
MARIADB_CPU_LIMIT="0.5"
MARIADB_MEMORY_LIMIT="512m"
NGINX_CPU_LIMIT="1"
NGINX_MEMORY_LIMIT="256m"

handle_error() {
    echo "Error: $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: $1" >> "$LOG_FILE"
    exit 1
}

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
}

load_env_file() {
    if [ -f ".env" ]; then
        log_message "Loading environment variables from .env file..."
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
            if [[ "$line" =~ ^([A-Za-z0-9_]+)\s*=\s*(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                value="${value%\"}"
                value="${value#\"}"
                value="${value%\'}"
                value="${value#\'}"
                export "$key"="$value"
            fi
        done < .env
        CPU_LIMIT="${CPU_LIMIT:-2}"
        MEMORY_LIMIT="${MEMORY_LIMIT:-2048m}"
        MARIADB_CPU_LIMIT="${MARIADB_CPU_LIMIT:-0.5}"
        MARIADB_MEMORY_LIMIT="${MARIADB_MEMORY_LIMIT:-512m}"
        NGINX_CPU_LIMIT="${NGINX_CPU_LIMIT:-1}"
        NGINX_MEMORY_LIMIT="${NGINX_MEMORY_LIMIT:-256m}"
    else
        log_message "Warning: .env file does not exist"
    fi
}

detect_host_environment() {
    log_message "[Stage 1] Detecting host environment..."
    load_env_file
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
        handle_error "Unsupported operating system type"
    fi
    log_message "Operating system: $OS_TYPE $OS_VERSION"
}

environment_preparation() {
    log_message "[Stage 2] Preparing environment..."
    log_message "Checking and creating www-data user/group..."
    if ! id -u www-data >/dev/null 2>&1; then
        log_message "Creating www-data user and group..."
        if [[ "$OS_TYPE" == "alpine" ]]; then
            addgroup -g 33 -S www-data || handle_error "Failed to create www-data group"
            adduser -u 33 -D -S -G www-data www-data || handle_error "Failed to create www-data user"
        else
            groupadd -g 33 www-data 2>/dev/null || :
            useradd -u 33 -g www-data -s /sbin/nologin -M www-data 2>/dev/null || :
        fi
        log_message "Success: www-data user/group created"
    else
        log_message "Success: www-data user already exists"
    fi
    if [ -f "$DEPLOY_DIR/.env" ]; then
        log_message "Fixing .env file for special characters..."
        TEMP_FILE="$DEPLOY_DIR/.env.tmp"
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == \#* ]] || [[ -z "$line" ]]; then
                echo "$line" >> "$TEMP_FILE"
                continue
            fi
            if [[ "$line" == *=* ]]; then
                key="${line%%=*}"
                value="${line#*=}"
                if [[ "$value" != \"* && "$value" != \'* ]]; then
                    echo "$key=\"$value\"" >> "$TEMP_FILE"
                else
                    echo "$line" >> "$TEMP_FILE"
                fi
            else
                echo "$line" >> "$TEMP_FILE"
            fi
        done < "$DEPLOY_DIR/.env"
        mv "$TEMP_FILE" "$DEPLOY_DIR/.env"
        log_message "Success: .env file has been fixed"
    fi
    log_message "Checking and cleaning up Docker container conflicts..."
    CONTAINERS=("wp_db" "wp_redis" "wp_php" "wp_nginx")
    for container in "${CONTAINERS[@]}"; do
        if docker ps -a | grep -q "$container"; then
            log_message "Detected conflicting container: $container, attempting to stop and remove..."
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
            log_message "Success: Container $container has been removed"
        fi
    done
    if docker network ls | grep -q "wp_network"; then
        log_message "Detected conflicting network: wp_network, attempting to remove..."
        docker network rm wp_network 2>/dev/null || true
        log_message "Success: Network wp_network has been removed"
    fi
}

collect_system_parameters() {
    log_message "[Stage 3] Collecting system parameters..."
    CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)
    log_message "CPU cores: $CPU_CORES"
    AVAILABLE_RAM=$(free -m | grep Mem | awk '{print $2}')
    log_message "Available memory: ${AVAILABLE_RAM}MB"
    AVAILABLE_DISK=$(df -h / | tail -1 | awk '{print $4}' | sed 's/G//')
    log_message "Available disk space: ${AVAILABLE_DISK}GB"
    if ! command -v docker >/dev/null 2>&1; then
        log_message "Warning: Docker not found. Please ensure Docker is installed and in PATH"
    else
        log_message "Success: Docker is installed"
    fi
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
        log_message "Success: Docker Compose v1 is installed"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
        log_message "Success: Docker Compose v2 is installed"
    else
        log_message "Warning: Docker Compose not found. Please ensure Docker Compose is installed"
        DOCKER_COMPOSE_CMD="docker compose"
    fi
    if (( $(echo "$AVAILABLE_DISK < 10" | awk '{print ($1 < 10) ? 1 : 0}') )); then
        handle_error "Insufficient disk space, at least 10GB required"
    fi
    if [[ "$AVAILABLE_RAM" -lt 2048 ]]; then
        log_message "Warning: Available memory is below 2GB, may impact performance"
    fi
}

determine_deployment_directory() {
    log_message "[Stage 4] Determining deployment directory..."
    if [ ! -d "$DEPLOY_DIR" ]; then
        mkdir -p "$DEPLOY_DIR" || handle_error "Failed to create deployment directory"
    fi
    cd "$DEPLOY_DIR" || handle_error "Failed to switch to deployment directory"
    mkdir -p html configs backups scripts logs || handle_error "Failed to create directory structure"
    log_message "Deployment directory: $DEPLOY_DIR"
}

generate_password() {
    local length=${1:-16}
    local password=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=[]{}|;:,.<>?~' | head -c "$length")
    echo "$password"
}

generate_wordpress_keys() {
    local keys=""
    local key_names=("WORDPRESS_AUTH_KEY" "WORDPRESS_SECURE_AUTH_KEY" "WORDPRESS_LOGGED_IN_KEY" "WORDPRESS_NONCE_KEY" "WORDPRESS_AUTH_SALT" "WORDPRESS_SECURE_AUTH_SALT" "WORDPRESS_LOGGED_IN_SALT" "WORDPRESS_NONCE_SALT")
    for key in "${key_names[@]}"; do
        local value=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+=-' | head -c 64)
        keys="${keys}${key}=\"${value}\"\n"
    done
    printf "%s" "$keys"
}

optimize_parameters() {
    log_message "[Stage 5] Optimizing parameters..."
    if [ "$AVAILABLE_RAM" -lt 2048 ]; then
        PHP_MEMORY_LIMIT="256M"
    elif [ "$AVAILABLE_RAM" -gt 4096 ]; then
        PHP_MEMORY_LIMIT="1024M"
    fi
    log_message "PHP memory limit: $PHP_MEMORY_LIMIT"
    PHP_VERSION="8.3"
    NGINX_VERSION="1.27"
    MARIADB_VERSION="11.3"
    REDIS_VERSION="7.4"
    CPU_LIMIT="${CPU_LIMIT:-2}"
    MEMORY_LIMIT="${MEMORY_LIMIT:-2048m}"
    MARIADB_CPU_LIMIT="${MARIADB_CPU_LIMIT:-0.5}"
    MARIADB_MEMORY_LIMIT="${MARIADB_MEMORY_LIMIT:-512m}"
    NGINX_CPU_LIMIT="${NGINX_CPU_LIMIT:-1}"
    NGINX_MEMORY_LIMIT="${NGINX_MEMORY_LIMIT:-256m}"
    MYSQL_ROOT_PASSWORD="$(generate_password 20)"
    MYSQL_PASSWORD="$(generate_password 20)"
    REDIS_PASSWORD="$(generate_password 20)"
    if [ -f ".env" ]; then
        log_message "Detected existing .env file, deleting and regenerating..."
        rm -f ".env"
    fi
    log_message "Generating .env file..."
    cat > .env << EOF
# WordPress Docker Environment Configuration
# Please modify according to your actual environment

COMPOSE_PROJECT_NAME=wp_docker
MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"
MYSQL_DATABASE="wordpress"
MYSQL_USER="wordpress"
MYSQL_PASSWORD="$MYSQL_PASSWORD"
WORDPRESS_DB_HOST="mariadb"
WORDPRESS_DB_USER="wordpress"
WORDPRESS_DB_PASSWORD="$MYSQL_PASSWORD"
WORDPRESS_DB_NAME="wordpress"
WORDPRESS_TABLE_PREFIX="wp_"
REDIS_HOST="redis"
REDIS_PASSWORD="$REDIS_PASSWORD"
REDIS_PORT=6379
REDIS_MAXMEMORY=256mb
MEMORY_LIMIT="$MEMORY_LIMIT"
CPU_LIMIT="$CPU_LIMIT"
MARIADB_CPU_LIMIT="$MARIADB_CPU_LIMIT"
MARIADB_MEMORY_LIMIT="$MARIADB_MEMORY_LIMIT"
NGINX_CPU_LIMIT="$NGINX_CPU_LIMIT"
NGINX_MEMORY_LIMIT="$NGINX_MEMORY_LIMIT"
PHP_MEMORY_LIMIT="$PHP_MEMORY_LIMIT"
UPLOAD_MAX_FILESIZE=64M
USE_CN_MIRROR=false
PHP_VERSION="$PHP_VERSION"
NGINX_VERSION="$NGINX_VERSION"
MARIADB_VERSION="$MARIADB_VERSION"
REDIS_VERSION="$REDIS_VERSION"
BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_DAYS"
$(generate_wordpress_keys)
EOF
    chmod 600 .env
    log_message "Success: .env file generated"
    source .env
}

set_permissions() {
    log_message "[Stage 6] Setting permissions..."
    log_message "Setting deployment directory permissions..."
    chown -R www-data:www-data "$DEPLOY_DIR/html" 2>/dev/null || :
    chmod -R 755 "$DEPLOY_DIR/html" 2>/dev/null || :
    chmod 700 "$DEPLOY_DIR/backups" 2>/dev/null || :
    chmod +x "$DEPLOY_DIR/scripts"/* 2>/dev/null || :
    log_message "Success: Permissions set"
}

cleanup_old_containers() {
    log_message "[Stage 7] Cleaning containers..."
    log_message "Checking old Docker containers..."
    if docker-compose ps | grep -q "Up"; then
        log_message "Stopping existing services..."
        docker-compose down --remove-orphans || log_message "Warning: Issue stopping services"
    fi
    if [ "$(docker images -f "dangling=true" -q)" != "" ]; then
        log_message "Cleaning dangling images..."
        docker rmi $(docker images -f "dangling=true" -q) 2>/dev/null || :
    fi
    log_message "Success: Container cleanup completed"
}

build_images() {
    log_message "[Stage 8] Building images..."
    if [ -z "$CPU_LIMIT" ] || ! [[ "$CPU_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_message "Warning: CPU_LIMIT invalid or not set, using default value 2"
        CPU_LIMIT="2"
    fi
    if [ -z "$MEMORY_LIMIT" ] || ! [[ "$MEMORY_LIMIT" =~ ^[0-9]+[m|g]$ ]]; then
        log_message "Warning: MEMORY_LIMIT invalid or not set, using default value 2048m"
        MEMORY_LIMIT="2048m"
    fi
    if [ -z "$MARIADB_CPU_LIMIT" ] || ! [[ "$MARIADB_CPU_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_message "Warning: MARIADB_CPU_LIMIT invalid or not set, using default value 0.5"
        MARIADB_CPU_LIMIT="0.5"
    fi
    if [ -z "$MARIADB_MEMORY_LIMIT" ] || ! [[ "$MARIADB_MEMORY_LIMIT" =~ ^[0-9]+[m|g]$ ]]; then
        log_message "Warning: MARIADB_MEMORY_LIMIT invalid or not set, using default value 512m"
        MARIADB_MEMORY_LIMIT="512m"
    fi
    if [ -z "$NGINX_CPU_LIMIT" ] || ! [[ "$NGINX_CPU_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_message "Warning: NGINX_CPU_LIMIT invalid or not set, using default value 1"
        NGINX_CPU_LIMIT="1"
    fi
    if [ -z "$NGINX_MEMORY_LIMIT" ] || ! [[ "$NGINX_MEMORY_LIMIT" =~ ^[0-9]+[m|g]$ ]]; then
        log_message "Warning: NGINX_MEMORY_LIMIT invalid or not set, using default value 256m"
        NGINX_MEMORY_LIMIT="256m"
    fi
    export CPU_LIMIT MEMORY_LIMIT MARIADB_CPU_LIMIT MARIADB_MEMORY_LIMIT NGINX_CPU_LIMIT NGINX_MEMORY_LIMIT
    if [ ! -f "docker-compose.yml" ] || [ "$FORCE_CONFIG" = true ]; then
        log_message "Generating docker-compose.yml file..."
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
          cpus: "$MARIADB_CPU_LIMIT"
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
    if ! $DOCKER_COMPOSE_CMD config >/dev/null 2>&1; then
        handle_error "docker-compose.yml configuration syntax error"
    fi
    log_message "Current resource limits: CPU=$CPU_LIMIT, Memory=$MEMORY_LIMIT, MARIADB_CPU=$MARIADB_CPU_LIMIT, MARIADB_MEMORY=$MARIADB_MEMORY_LIMIT, NGINX_CPU=$NGINX_CPU_LIMIT, NGINX_MEMORY=$NGINX_MEMORY_LIMIT"
    log_message "Building Docker images..."
    $DOCKER_COMPOSE_CMD build || handle_error "Failed to build Docker images"
    log_message "Success: Image building completed"
}

generate_configs() {
    log_message "[Stage 9] Generating configuration files..."
    if [ ! -f "configs/nginx.conf" ] || [ "$FORCE_CONFIG" = true ]; then
        log_message "Generating Nginx configuration files..."
        local worker_processes="auto"
        if [[ "$OS_TYPE" == "alpine" ]]; then
            worker_processes="$(nproc)"
        fi
        mkdir -p configs/conf.d
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

    keepalive_timeout  65;

    include /etc/nginx/conf.d/*.conf;
}
EOF
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
        log_message "Success: Nginx configuration files generated"
    else
        log_message "Warning: Nginx configuration files already exist, skipping generation"
    fi
    if [ ! -f "configs/php.ini" ] || [ "$FORCE_CONFIG" = true ]; then
        log_message "Generating PHP configuration file..."
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
        log_message "Success: PHP configuration file generated"
    else
        log_message "Warning: PHP configuration file already exists, skipping generation"
    fi
}

start_services() {
    log_message "[Stage 10] Starting services..."
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
            log_message "Downloading latest WordPress version..."
            local temp_file="/tmp/wordpress-latest.tar.gz"
            if command -v wget >/dev/null; then
                wget -q -O "$temp_file" https://wordpress.org/latest.tar.gz
            else
                curl -s -o "$temp_file" https://wordpress.org/latest.tar.gz
            fi
            if [ -f "$temp_file" ]; then
                tar -xzf "$temp_file" -C .
                mv wordpress/* html/
                rm -rf wordpress "$temp_file"
                log_message "Setting file permissions..."
                chown -R www-data:www-data html
                log_message "Success: WordPress downloaded and extracted"
            else
                log_message "Warning: WordPress download failed, please manually download and extract to html directory"
            fi
        else
            log_message "Success: html directory already contains content, skipping WordPress download"
        fi
    else
        log_message "Success: WordPress configuration file already exists, skipping download"
    fi
    log_message "Starting Docker services..."
    $DOCKER_COMPOSE_CMD up -d || handle_error "Failed to start Docker services"
    log_message "Waiting for service initialization..."
    sleep 10
    log_message "Checking service status..."
    $DOCKER_COMPOSE_CMD ps
    if [ "$(docker-compose ps -q | wc -l)" -eq "4" ]; then
        log_message "Success: WordPress Docker deployment successful"
    else
        log_message "Warning: WordPress Docker deployment failed, please check logs"
        $DOCKER_COMPOSE_CMD logs --tail=50
    fi
}

setup_backup_config() {
    log_message "[Stage 11] Setting up backup configuration..."
    cat > "$DEPLOY_DIR/scripts/backup_db.sh" << 'EOF'
#!/bin/bash
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$DEPLOY_DIR/backups"
if [ -f "$DEPLOY_DIR/.env" ]; then
    export $(grep -E '^MYSQL_|^BACKUP_RETENTION_DAYS' "$DEPLOY_DIR/.env" | xargs)
fi
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-default_password}
MYSQL_DATABASE=${MYSQL_DATABASE:-wordpress}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}
BACKUP_FILE="$BACKUP_DIR/db-$(date +%Y%m%d_%H%M%S).sql.gz"
echo "Starting database backup: $MYSQL_DATABASE"
docker exec -t wp_db mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" | gzip > "$BACKUP_FILE"
if [ $? -eq 0 ]; then
    echo "Success: Database backup completed: $BACKUP_FILE"
    echo "Cleaning backups older than $BACKUP_RETENTION_DAYS days..."
    find "$BACKUP_DIR" -name "db-*.sql.gz" -mtime +"$BACKUP_RETENTION_DAYS" -delete
    echo "Success: Old backups cleaned"
else
    echo "Warning: Database backup failed"
fi
EOF
    chmod +x "$DEPLOY_DIR/scripts/backup_db.sh"
    CRON_JOB="0 3 * * * $DEPLOY_DIR/scripts/backup_db.sh >> $DEPLOY_DIR/logs/backup.log 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "backup_db.sh"; then
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        log_message "Success: Database backup cron job created (runs daily at 3 AM)"
    else
        log_message "Warning: Database backup cron job already exists"
    fi
    log_message "Running backup test..."
    "$DEPLOY_DIR/scripts/backup_db.sh"
}

display_deployment_info() {
    log_message "=================================================="
    log_message "Deployment completed!"
    log_message "=================================================="
    local HOST_IP=$(hostname -I | awk '{print $1}')
    log_message "Access URL: http://$HOST_IP"
    log_message ""
    log_message "Deployment details:"
    log_message "  - Operating system: $OS_TYPE $OS_VERSION"
    log_message "  - CPU cores: $CPU_CORES (limited to: $((CPU_CORES / 2)) cores)"
    log_message "  - Available memory: ${AVAILABLE_RAM}MB (limited to: $((AVAILABLE_RAM / 2))MB)"
    log_message "  - Deployment directory: $DEPLOY_DIR"
    log_message "  - Backup directory: $DEPLOY_DIR/backups"
    log_message "  - Backup retention: $BACKUP_RETENTION_DAYS days"
    log_message ""
    log_message "Database information:"
    log_message "  - Database name: wordpress"
    log_message "  - Username: wordpress"
    log_message "  - Password: Check .env file for MYSQL_PASSWORD"
    log_message "  - Host: mariadb"
    log_message ""
    log_message "Automation features:"
    log_message "  - Success: Daily database backup (3 AM)"
    log_message "  - Success: Automatic permission setting"
    log_message "  - Success: Environment auto-repair"
    log_message "  - Success: Container conflict cleanup"
    log_message ""
    log_message "Next steps:"
    log_message "1. Open browser and visit the above URL"
    log_message "2. Complete the WordPress installation wizard"
    log_message "3. Recommended: Install Redis Object Cache plugin to enable caching"
    log_message ""
    log_message "Important: Back up the .env file, it contains sensitive information"
    log_message "=================================================="
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE_CONFIG=true
                shift
                ;;
            *)
                log_message "Warning: Unknown option: $1"
                shift
                ;;
        esac
    done
    log_message "Starting WordPress Docker deployment..."
    detect_host_environment
    environment_preparation
    collect_system_parameters
    determine_deployment_directory
    optimize_parameters
    set_permissions
    cleanup_old_containers
    generate_configs
    build_images
    start_services
    setup_backup_config
    display_deployment_info
    log_message "Success: WordPress Docker full-stack deployment completed!"
}

main "$@"
```

### 修复步骤

1. **保存脚本**：
   - 将上述内容保存为 `/opt/auto_deploy.sh`。
   - **确保使用纯文本编辑器**（如 `vim`、`nano`）保存，避免引入 BOM 或其他不可见字符：
     ```bash
     nano /opt/auto_deploy.sh
     ```
     粘贴内容，保存并退出（`Ctrl+O`, `Enter`, `Ctrl+X`）。
   - 设置执行权限：
     ```bash
     chmod +x /opt/auto_deploy.sh
     ```

2. **检查文件编码**：
   - 验证文件没有 BOM：
     ```bash
     file /opt/auto_deploy.sh
     ```
     期望输出：` Bourne-Again shell script, ASCII text executable` 或类似。
     如果显示 `with BOM`，移除 BOM：
     ```bash
     sed -i '1s/^\xEF\xBB\xBF//' /opt/auto_deploy.sh
     ```

3. **转换为 Unix 换行符**：
   - 如果脚本包含 Windows 换行符（CRLF），转换为 Unix 换行符（LF）：
     ```bash
     dos2unix /opt/auto_deploy.sh
     ```
     如果 `dos2unix` 未安装，安装：
     ```bash
     apt-get update && apt-get install -y dos2unix
     ```

4. **运行脚本**：
   ```bash
   cd /opt
   ./auto_deploy.sh
   ```
   - 使用 `--force` 强制重新生成配置文件：
     ```bash
     ./auto_deploy.sh --force
     ```

5. **验证**：
   - 检查日志文件：`/opt/logs/deploy.log`。
   - 确认 `docker-compose.yml` 生成且包含有效 `cpus` 值：
     ```bash
     cat /opt/docker-compose.yml | grep cpus
     ```
     期望输出类似：
     ```
     cpus: "0.5"  # mariadb
     cpus: "2"    # php
     cpus: "1"    # nginx
     ```
   - 检查服务状态：
     ```bash
     docker-compose ps
     ```

6. **调试**：
   - 如果仍有错误，查看 Docker Compose 日志：
     ```bash
     docker-compose logs --tail=50
     ```
   - 验证 `docker-compose.yml` 语法：
     ```bash
     docker-compose config
     ```

### 预防措施

- **避免复制粘贴问题**：直接在服务器上使用 `nano` 或 `vim` 编辑脚本，避免从网页或其他编辑器复制引入不可见字符。
- **备份**：在运行脚本前备份现有配置文件（`.env`、`docker-compose.yml`、 `configs/*`）。
- **依赖检查**：确保 Docker 和 Docker Compose 已安装：
  ```bash
  docker --version
  docker-compose --version || docker compose version
  ```
  如果未安装，安装 Docker 和 Docker Compose：
  ```bash
  apt-get update && apt-get install -y docker.io docker-compose
  ```

### 如果问题仍未解决

如果执行仍失败，请提供以下信息：
- 当前 `/opt/auto_deploy.sh` 的开头几行：`head -n 20 /opt/auto_deploy.sh`
- 文件编码信息：`file /opt/auto_deploy.sh`
- 完整错误日志：`./auto_deploy.sh > deploy_error.log 2>&1 && cat deploy_error.log`
- 是否存在 `../build/Dockerfiles/php` 和 `../build/Dockerfiles/nginx`（脚本中 PHP 和 Nginx 服务使用自定义构建）。

这些信息将帮助我进一步诊断问题！