#!/bin/bash

# WordPress Docker 鑷姩閮ㄧ讲鑴氭湰
# 鏀硅繘鐗堝姛鑳斤細鑷姩鍒涘缓www-data鐢ㄦ埛/缁勩€?env淇銆丏ocker瀹瑰櫒鍐茬獊娓呯悊
# 瑙﹀彂GitHub Actions宸ヤ綔娴佹祴璇?
set -e

# 鍏ㄥ眬鍙橀噺
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Create logs directory first to ensure log file can be written
mkdir -p "$DEPLOY_DIR/logs" 2>/dev/null

# 棰滆壊杈撳嚭鍑芥暟锛堜慨澶嶈娉曢敊璇級
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

# 閿欒澶勭悊鍑芥暟
handle_error() {
    echo "閿欒: $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 閿欒: $1" >> "$LOG_FILE"
    exit 1
}

# 璁板綍鏃ュ織
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
}

# 检测主机环境
detect_host_environment() {
    log_message "[阶段1] 检测主机环境..."
    
    # Logs directory already created at script start
    
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

# 鐜鍑嗗锛氬垱寤簑ww-data鐢ㄦ埛/缁勩€佷慨澶?env鏂囦欢銆佹竻鐞咲ocker鍐茬獊
environment_preparation() {
    log_message "[闃舵2] 鐜鍑嗗..."
    
    # 1. 妫€娴嬪苟鍒涘缓www-data鐢ㄦ埛/缁?    log_message "妫€鏌ュ苟鍒涘缓www-data鐢ㄦ埛/缁?.."
    if ! id -u www-data >/dev/null 2>&1; then
        log_message "鍒涘缓www-data鐢ㄦ埛鍜岀粍..."
        # 鏍规嵁涓嶅悓绯荤粺鍒涘缓鐢ㄦ埛
        if [[ "$OS_TYPE" == "alpine" ]]; then
            addgroup -g 33 -S www-data || handle_error "鍒涘缓www-data缁勫け璐?
            adduser -u 33 -D -S -G www-data www-data || handle_error "鍒涘缓www-data鐢ㄦ埛澶辫触"
        else
            groupadd -g 33 www-data 2>/dev/null || :
            useradd -u 33 -g www-data -s /sbin/nologin -M www-data 2>/dev/null || :
        fi
        log_message "鉁?www-data鐢ㄦ埛/缁勫垱寤烘垚鍔?
    else
        log_message "鉁?www-data鐢ㄦ埛宸插瓨鍦?
    fi
    
    # 2. 淇.env鏂囦欢
    if [ -f "$DEPLOY_DIR/.env" ]; then
        log_message "淇.env鏂囦欢涓殑鐗规畩瀛楃闂..."
        # 鍒涘缓涓存椂鏂囦欢
        TEMP_FILE="$DEPLOY_DIR/.env.tmp"
        # 澶嶅埗.env鏂囦欢锛岀‘淇濇墍鏈夊€奸兘鐢ㄥ弻寮曞彿鍖呰９
        while IFS= read -r line || [[ -n "$line" ]]; do
            # 璺宠繃娉ㄩ噴鍜岀┖琛?            if [[ "$line" == \#* ]] || [[ -z "$line" ]]; then
                echo "$line" >> "$TEMP_FILE"
                continue
            fi
            
            # 妫€鏌ユ槸鍚﹀凡缁忔湁寮曞彿
            if [[ "$line" == *=* ]]; then
                key="${line%%=*}"
                value="${line#*=}"
                
                # 濡傛灉鍊兼病鏈夎寮曞彿鍖呰９锛屾坊鍔犲弻寮曞彿
                if [[ "$value" != \"* && "$value" != \'* ]]; then
                    echo "$key=\"$value\"" >> "$TEMP_FILE"
                else
                    echo "$line" >> "$TEMP_FILE"
                fi
            else
                echo "$line" >> "$TEMP_FILE"
            fi
        done < "$DEPLOY_DIR/.env"
        
        # 鏇挎崲鍘熸枃浠?        mv "$TEMP_FILE" "$DEPLOY_DIR/.env"
        log_message "鉁?.env file has been fixed"
    fi
    
    # 3. 娓呯悊Docker瀹瑰櫒鍐茬獊
    log_message "妫€鏌ュ苟娓呯悊Docker瀹瑰櫒鍐茬獊..."
    # 妫€鏌ユ槸鍚︽湁閲嶅悕瀹瑰櫒鍦ㄨ繍琛?    CONTAINERS=("wp_db" "wp_redis" "wp_php" "wp_nginx")
    for container in "${CONTAINERS[@]}"; do
        if docker ps -a | grep -q "$container"; then
            log_message "Detected conflicting container: $container, attempting to stop and remove..."
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
            log_message "鉁?Container $container has been removed"
        fi
    done
    
    # 妫€鏌ユ槸鍚︽湁閲嶅悕缃戠粶
    if docker network ls | grep -q "wp_network"; then
        log_message "Detected conflicting network: wp_network, attempting to remove..."
        docker network rm wp_network 2>/dev/null || true
        log_message "鉁?Network wp_network has been removed"
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
    
    # 妫€鏌ュ唴瀛?    if [[ "$AVAILABLE_RAM" -lt 2048 ]]; then
        log_message "璀﹀憡: 鍙敤鍐呭瓨浣庝簬2GB锛屽彲鑳藉奖鍝嶆€ц兘"
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

# 鐢熸垚瀵嗙爜
generate_password() {
    local length=${1:-16}
    # 浣跨敤urandom鐢熸垚闅忔満瀵嗙爜
    local password=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=[]{}|;:,.<>?~' | head -c "$length")
    echo "$password"
}

# 鐢熸垚WordPress瀵嗛挜
generate_wordpress_keys() {
    local keys=""
    
    # 鐢熸垚鎵€鏈夐渶瑕佺殑WordPress瀵嗛挜
    local key_names=("AUTH_KEY" "SECURE_AUTH_KEY" "LOGGED_IN_KEY" "NONCE_KEY" "AUTH_SALT" "SECURE_AUTH_SALT" "LOGGED_IN_SALT" "NONCE_SALT")
    
    for key in "${key_names[@]}"; do
        # 涓烘瘡涓瘑閽ョ敓鎴?4浣嶉殢鏈哄瓧绗?        local value="$(generate_password 64)"
        # 纭繚鍊奸兘鐢ㄥ弻寮曞彿鍖呰９
        keys="${keys}${key}=\"${value}\"\n"
    done
    
    echo "$keys"
}

# 浼樺寲鍙傛暟
optimize_parameters() {
    log_message "[闃舵5] 浼樺寲鍙傛暟..."
    
    # 鏍规嵁绯荤粺璧勬簮浼樺寲PHP鍐呭瓨闄愬埗
    if [ "$AVAILABLE_RAM" -lt 2048 ]; then
        PHP_MEMORY_LIMIT="256M"
    elif [ "$AVAILABLE_RAM" -gt 4096 ]; then
        PHP_MEMORY_LIMIT="1024M"
    fi
    
    log_message "PHP鍐呭瓨闄愬埗: $PHP_MEMORY_LIMIT"
    
    # 鐢熸垚.env鏂囦欢锛堝鏋滀笉瀛樺湪锛?    if [ ! -f ".env" ]; then
        log_message "鐢熸垚.env鏂囦欢..."
        
        # 鐢熸垚瀵嗙爜
        MYSQL_ROOT_PASSWORD="$(generate_password 20)"
        MYSQL_PASSWORD="$(generate_password 20)"
        REDIS_PASSWORD="$(generate_password 20)"
        
        # 鐢熸垚WordPress瀵嗛挜
        wp_keys="$(generate_wordpress_keys)"
        
        # 瀹氫箟鐗堟湰
        PHP_VERSION="8.1"
        NGINX_VERSION="1.24"
        MARIADB_VERSION="10.11"
        REDIS_VERSION="7.0"
        
        # 鍒涘缓.env鏂囦欢
        cat > .env << EOF
# Docker閰嶇疆
COMPOSE_PROJECT_NAME=wp_docker

# 鏁版嵁搴撻厤缃?MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"
MYSQL_DATABASE="wordpress"
MYSQL_USER="wordpress"
MYSQL_PASSWORD="$MYSQL_PASSWORD"

# WordPress閰嶇疆
WORDPRESS_DB_HOST="mariadb"
WORDPRESS_DB_USER="wordpress"
WORDPRESS_DB_PASSWORD="$MYSQL_PASSWORD"
WORDPRESS_DB_NAME="wordpress"
WORDPRESS_TABLE_PREFIX="wp_"

# Redis閰嶇疆
REDIS_HOST="redis"
REDIS_PASSWORD="$REDIS_PASSWORD"

# 璧勬簮闄愬埗
MEMORY_LIMIT="$((AVAILABLE_RAM / 2))m"
CPU_LIMIT="$((CPU_CORES / 2))"

# 闀滃儚鐗堟湰
PHP_VERSION="$PHP_VERSION"
NGINX_VERSION="$NGINX_VERSION"
MARIADB_VERSION="$MARIADB_VERSION"
REDIS_VERSION="$REDIS_VERSION"

# 澶囦唤淇濈暀澶╂暟
BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_DAYS"

# WordPress瀹夊叏瀵嗛挜
$wp_keys
EOF
        
        log_message "鉁?.env鏂囦欢鐢熸垚瀹屾垚"
    else
        log_message "璀﹀憡: .env鏂囦欢宸插瓨鍦紝浣跨敤鐜版湁閰嶇疆"
        # 浠?env鏂囦欢鍔犺浇鐜鍙橀噺
        source .env
    fi
}

# 鏉冮檺璁剧疆
set_permissions() {
    log_message "[闃舵6] 璁剧疆鏉冮檺..."
    
    # 璁剧疆鐩綍鏉冮檺
    log_message "璁剧疆閮ㄧ讲鐩綍鏉冮檺..."
    chown -R www-data:www-data "$DEPLOY_DIR/html" 2>/dev/null || :
    chmod -R 755 "$DEPLOY_DIR/html" 2>/dev/null || :
    
    # 璁剧疆澶囦唤鐩綍鏉冮檺
    chmod 700 "$DEPLOY_DIR/backups" 2>/dev/null || :
    
    # 璁剧疆鑴氭湰鏉冮檺
    chmod +x "$DEPLOY_DIR/scripts"/* 2>/dev/null || :
    
    log_message "鉁?鏉冮檺璁剧疆瀹屾垚"
}

# 鏃у鍣ㄦ竻鐞?cleanup_old_containers() {
    log_message "[闃舵7] 娓呯悊鏃у鍣?.."
    
    # 鍋滄骞剁Щ闄ゆ棫鐨凞ocker瀹瑰櫒
    log_message "妫€鏌ユ棫鐨凞ocker瀹瑰櫒..."
    
    # 妫€鏌ュ苟鍋滄鐩稿叧鏈嶅姟
    if docker-compose ps | grep -q "Up"; then
        log_message "鍋滄鐜版湁鏈嶅姟..."
        docker-compose down --remove-orphans || log_message "璀﹀憡: 鍋滄鏈嶅姟鏃跺嚭鐜伴棶棰?
    fi
    
    # 娓呯悊鎮┖闀滃儚
    if [ "$(docker images -f "dangling=true" -q)" != "" ]; then
        log_message "娓呯悊鎮┖闀滃儚..."
        docker rmi $(docker images -f "dangling=true" -q) 2>/dev/null || :
    fi
    
    log_message "鉁?鏃у鍣ㄦ竻鐞嗗畬鎴?
}

# 闀滃儚鏋勫缓
build_images() {
    log_message "[闃舵8] 鏋勫缓闀滃儚..."
    
    # 妫€鏌ocker-compose.yml鏂囦欢鏄惁瀛樺湪
    if [ ! -f "docker-compose.yml" ]; then
        log_message "鐢熸垚docker-compose.yml鏂囦欢..."
        
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
          cpus: "${CPU_LIMIT}"
          memory: "${MEMORY_LIMIT}"

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
          cpus: "${CPU_LIMIT}"
          memory: "${MEMORY_LIMIT}"

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
          cpus: "1"
          memory: "256m"

networks:
  wp_network:
    driver: bridge

volumes:
  mysql_data:
  wordpress_data:
EOF
    fi
    
    # 鏋勫缓闀滃儚
    log_message "鏋勫缓Docker闀滃儚..."
    docker-compose build
    
    log_message "鉁?闀滃儚鏋勫缓瀹屾垚"
}

# 鐢熸垚閰嶇疆鏂囦欢
generate_configs() {
    log_message "[闃舵9] 鐢熸垚閰嶇疆鏂囦欢..."
    
    # 鐢熸垚Nginx閰嶇疆
    if [ ! -f "configs/nginx.conf" ]; then
        log_message "鐢熸垚Nginx閰嶇疆鏂囦欢..."
        
        # 鏍规嵁CPU鏍稿績鏁颁紭鍖杦orker_processes
        local worker_processes="auto"
        if [[ "$OS_TYPE" == "alpine" ]]; then
            worker_processes="$(nproc)"
        fi
        
        # 鍒涘缓nginx閰嶇疆鐩綍
        mkdir -p configs/conf.d
        
        # 涓婚厤缃枃浠?        cat > configs/nginx.conf << EOF
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
        
        # 绔欑偣閰嶇疆鏂囦欢
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
        
        log_message "鉁?Nginx 閰嶇疆鏂囦欢鐢熸垚瀹屾垚"
    else
        log_message "璀﹀憡: Nginx 閰嶇疆鏂囦欢宸插瓨鍦紝璺宠繃鐢熸垚"
    fi
    
    # 鐢熸垚 PHP 閰嶇疆鏂囦欢
    if [ ! -f "configs/php.ini" ]; then
        log_message "鐢熸垚 PHP 閰嶇疆鏂囦欢..."
        
        # 鏍规嵁鍐呭瓨澶у皬璋冩暣 opcache 閰嶇疆
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
        
        log_message "鉁?PHP 閰嶇疆鏂囦欢鐢熸垚瀹屾垚"
    else
        log_message "璀﹀憡: PHP 閰嶇疆鏂囦欢宸插瓨鍦紝璺宠繃鐢熸垚"
    fi
}

# 鏈嶅姟鍚姩
start_services() {
    log_message "[闃舵10] 鍚姩鏈嶅姟..."
    
    # 涓嬭浇 WordPress锛堝鏋滈渶瑕侊級
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
            log_message "涓嬭浇 WordPress 鏈€鏂扮増鏈?.."
            
            # 涓嬭浇骞惰В鍘?WordPress
            local temp_file="/tmp/wordpress-latest.tar.gz"
            
            if command -v wget >/dev/null; then
                wget -q -O "$temp_file" https://wordpress.org/latest.tar.gz
            else
                curl -s -o "$temp_file" https://wordpress.org/latest.tar.gz
            fi
            
            if [ -f "$temp_file" ]; then
                # 瑙ｅ帇鍒?html 鐩綍
                tar -xzf "$temp_file" -C .
                mv wordpress/* html/
                rm -rf wordpress "$temp_file"
                
                # 璁剧疆鏉冮檺
                log_message "璁剧疆鏂囦欢鏉冮檺..."
                chown -R www-data:www-data html
                
                log_message "鉁?WordPress 涓嬭浇骞惰В鍘嬪畬鎴?
            else
                log_message "璀﹀憡: WordPress 涓嬭浇澶辫触锛岃鎵嬪姩涓嬭浇骞惰В鍘嬪埌 html 鐩綍"
            fi
        else
            log_message "鉁?html 鐩綍宸插瓨鍦ㄥ唴瀹癸紝璺宠繃 WordPress 涓嬭浇"
        fi
    else
        log_message "鉁?WordPress 閰嶇疆鏂囦欢宸插瓨鍦紝璺宠繃涓嬭浇"
    fi
    
    # 鍚姩鏈嶅姟
    log_message "鍚姩 Docker 鏈嶅姟..."
    docker-compose up -d
    
    # 绛夊緟鏈嶅姟鍚姩
    log_message "绛夊緟鏈嶅姟鍒濆鍖?.."
    sleep 10
    
    # 妫€鏌ユ湇鍔＄姸鎬?    log_message "妫€鏌ユ湇鍔＄姸鎬?.."
    docker-compose ps
    
    # 楠岃瘉閮ㄧ讲鏄惁鎴愬姛
    if [ "$(docker-compose ps -q | wc -l)" -eq "4" ]; then
        log_message "鉁?WordPress Docker 鏍堥儴缃叉垚鍔?
    else
        log_message "鉁?WordPress Docker 鏍堥儴缃插け璐ワ紝璇锋鏌ユ棩蹇?
        docker-compose logs --tail=50
    fi
}

# 澶囦唤閰嶇疆
setup_backup_config() {
    log_message "[闃舵11] 璁剧疆澶囦唤閰嶇疆..."
    
    # 鍒涘缓澶囦唤鑴氭湰
    cat > "$DEPLOY_DIR/scripts/backup_db.sh" << 'EOF'
#!/bin/bash

# 鑾峰彇鑴氭湰鎵€鍦ㄧ洰褰曠殑鐖剁洰褰?DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$DEPLOY_DIR/backups"

# 浠?.env 鏂囦欢鍔犺浇鐜鍙橀噺
if [ -f "$DEPLOY_DIR/.env" ]; then
    # 鍙鍑洪渶瑕佺殑鏁版嵁搴撶浉鍏崇幆澧冨彉閲?    export $(grep -E '^MYSQL_|^BACKUP_RETENTION_DAYS' "$DEPLOY_DIR/.env" | xargs)
fi

# 璁剧疆榛樿鍊?MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-default_password}
MYSQL_DATABASE=${MYSQL_DATABASE:-wordpress}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}

# 鍒涘缓澶囦唤鏂囦欢
BACKUP_FILE="$BACKUP_DIR/db-$(date +%Y%m%d_%H%M%S).sql.gz"

echo "寮€濮嬪浠芥暟鎹簱: $MYSQL_DATABASE"

# 鎵ц澶囦唤
docker exec -t wp_db mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" | gzip > "$BACKUP_FILE"

if [ $? -eq 0 ]; then
    echo "鉁?鏁版嵁搴撳浠芥垚鍔? $BACKUP_FILE"
    
    # 鍒犻櫎鏃у浠?    echo "娓呯悊 $BACKUP_RETENTION_DAYS 澶╁墠鐨勫浠?.."
    find "$BACKUP_DIR" -name "db-*.sql.gz" -mtime +"$BACKUP_RETENTION_DAYS" -delete
    echo "鉁?鏃у浠芥竻鐞嗗畬鎴?
else
    echo "鉁?鏁版嵁搴撳浠藉け璐?
fi
EOF
    
    # 璁剧疆鎵ц鏉冮檺
    chmod +x "$DEPLOY_DIR/scripts/backup_db.sh"
    
    # 鍒涘缓 cron 浠诲姟
    CRON_JOB="0 3 * * * $DEPLOY_DIR/scripts/backup_db.sh >> $DEPLOY_DIR/logs/backup.log 2>&1"
    
    # 妫€鏌ユ槸鍚﹀凡瀛樺湪鐩稿悓鐨?cron 浠诲姟
    if ! crontab -l 2>/dev/null | grep -q "backup_db.sh"; then
        # 娣诲姞鍒?cron
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        log_message "鉁?鏁版嵁搴撳浠?cron 浠诲姟宸插垱寤猴紙姣忓ぉ鍑屾櫒 3 鐐规墽琛岋級"
    else
        log_message "璀﹀憡: 鏁版嵁搴撳浠?cron 浠诲姟宸插瓨鍦?
    fi
    
    # 绔嬪嵆鎵ц涓€娆″浠芥祴璇?    log_message "鎵ц澶囦唤娴嬭瘯..."
    "$DEPLOY_DIR/scripts/backup_db.sh"
}

# 鏄剧ず閮ㄧ讲淇℃伅
display_deployment_info() {
    log_message "=================================================="
    log_message "閮ㄧ讲瀹屾垚锛?
    log_message "=================================================="
    
    # 鑾峰彇涓绘満 IP
    local HOST_IP=$(hostname -I | awk '{print $1}')
    
    log_message "璁块棶鍦板潃: http://$HOST_IP"
    log_message ""
    log_message "閮ㄧ讲璇︽儏:"
    log_message "  - 鎿嶄綔绯荤粺: $OS_TYPE $OS_VERSION"
    log_message "  - CPU 鏍稿績: $CPU_CORES 鏍革紙闄愬埗浣跨敤: $((CPU_CORES / 2)) 鏍革級"
    log_message "  - 鍙敤鍐呭瓨: ${AVAILABLE_RAM}MB锛堥檺鍒朵娇鐢? $((AVAILABLE_RAM / 2))MB锛?
    log_message "  - 閮ㄧ讲鐩綍: $DEPLOY_DIR"
    log_message "  - 澶囦唤鐩綍: $DEPLOY_DIR/backups"
    log_message "  - 澶囦唤淇濈暀: $BACKUP_RETENTION_DAYS 澶?
    log_message ""
    log_message "鏁版嵁搴撲俊鎭?"
    log_message "  - 鏁版嵁搴撳悕: wordpress"
    log_message "  - 鐢ㄦ埛鍚? wordpress"
    log_message "  - 瀵嗙爜: 璇锋煡鐪?.env 鏂囦欢涓殑 MYSQL_PASSWORD"
    log_message "  - 涓绘満: mariadb"
    log_message ""
    log_message "鑷姩鍖栧姛鑳?"
    log_message "  - 鉁?姣忔棩鏁版嵁搴撹嚜鍔ㄥ浠斤紙鍑屾櫒 3 鐐癸級"
    log_message "  - 鉁?鏉冮檺鑷姩璁剧疆"
    log_message "  - 鉁?鐜鑷姩淇"
    log_message "  - 鉁?瀹瑰櫒鍐茬獊鑷姩娓呯悊"
    log_message ""
    log_message "鍚庣画姝ラ:"
    log_message "1. 鎵撳紑娴忚鍣ㄨ闂笂杩板湴鍧€"
    log_message "2. 瀹屾垚 WordPress 瀹夎鍚戝"
    log_message "3. 鎺ㄨ崘瀹夎 Redis Object Cache 鎻掍欢鍚敤缂撳瓨"
    log_message ""
    log_message "閲嶈: 璇峰浠?.env 鏂囦欢锛屽寘鍚墍鏈夋晱鎰熶俊鎭?
    log_message "=================================================="
}

# 涓诲嚱鏁?main() {
    log_message "馃殌 寮€濮?WordPress Docker 鑷姩閮ㄧ讲..."
    
    # 鎵ц鍚勯樁娈?    detect_host_environment       # 妫€娴嬪涓绘満鐜
    environment_preparation       # 鐜鍑嗗
    collect_system_parameters     # 鏀堕泦绯荤粺鍙傛暟
    determine_deployment_directory # 纭畾閮ㄧ讲鐩綍
    optimize_parameters           # 浼樺寲鍙傛暟
    set_permissions              # 鏉冮檺璁剧疆
    cleanup_old_containers       # 鏃у鍣ㄦ竻鐞?    generate_configs             # 鐢熸垚閰嶇疆鏂囦欢
    build_images                 # 闀滃儚鏋勫缓
    start_services               # 鏈嶅姟鍚姩
    setup_backup_config          # 澶囦唤閰嶇疆
    display_deployment_info      # 鏄剧ず閮ㄧ讲淇℃伅
    
    log_message "馃帀 WordPress Docker 鍏ㄦ爤閮ㄧ讲瀹屾垚锛?
}

# 鎵ц涓诲嚱鏁?main
