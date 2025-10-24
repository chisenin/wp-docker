#!/bin/bash

# WordPress Docker 全栈自动部署脚本（生产环境优化版）
# 功能：环境检测、系统参数收集、智能参数优化、自动数据库备份、磁盘空间管理

echo "=================================================="
echo "WordPress Docker 全栈自动部署脚本 - 生产环境优化版"
echo "=================================================="

# 全局变量
OS_TYPE=""
OS_VERSION=""
CPU_CORES=0
AVAILABLE_RAM=0
DISK_SPACE=0
DISK_USAGE=0
DEPLOY_DIR=""
BACKUP_DIR=""
BACKUP_RETENTION_DAYS=7

# 彩色输出函数
print_green() { echo -e "\033[0;32m$1\033[0m"; }
print_yellow() { echo -e "\033[1;33m$1\033[0m"; }
print_red() { echo -e "\033[0;31m$1\033[0m"; }
print_blue() { echo -e "\033[0;34m$1\033[0m"; }

# 错误处理函数
handle_error() {
    print_red "错误: $1"
    exit 1
}

# 检查宿主机环境
detect_host_environment() {
    print_blue "[阶段1] 检测宿主机环境..."
    
    # 检测操作系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        OS_VERSION=$(cat /etc/debian_version)
    elif [ -f /etc/centos-release ]; then
        OS_TYPE="centos"
        OS_VERSION=$(rpm -q --queryformat '%{VERSION}' centos-release)
    else
        handle_error "无法识别操作系统类型，请使用 CentOS、Debian、Ubuntu 或 Alpine"
    fi
    
    print_green "操作系统: $OS_TYPE $OS_VERSION"
    
    # 验证是否支持的操作系统
    case "$OS_TYPE" in
        centos|debian|ubuntu|alpine)
            print_green "✓ 操作系统受支持"
            ;;
        *)
            handle_error "不支持的操作系统: $OS_TYPE，请使用 CentOS、Debian、Ubuntu 或 Alpine"
            ;;
    esac
}

# 收集系统参数
collect_system_parameters() {
    print_blue "[阶段2] 收集系统参数..."
    
    # 收集 CPU 核心数
    CPU_CORES=$(nproc)
    print_green "CPU 核心数: $CPU_CORES"
    
    # 收集内存信息（MB）
    if [ "$OS_TYPE" == "alpine" ]; then
        AVAILABLE_RAM=$(free -m | grep Mem | awk '{print $2}')
    else
        AVAILABLE_RAM=$(free -m | grep Mem | awk '{print $2}')
    fi
    print_green "可用内存: ${AVAILABLE_RAM}MB"
    
    # 收集磁盘空间信息
    if [ "$OS_TYPE" == "alpine" ]; then
        DISK_SPACE=$(df -h / | tail -1 | awk '{print $4}')
        DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
    else
        DISK_SPACE=$(df -h / | tail -1 | awk '{print $4}')
        DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
    fi
    print_green "可用磁盘空间: $DISK_SPACE"
    print_green "磁盘使用率: ${DISK_USAGE}%"
    
    # 检查 Docker 安装状态
    if ! command -v docker >/dev/null 2>&1; then
        print_red "Docker 未安装，正在尝试安装..."
        install_docker
    else
        DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
        print_green "Docker 版本: $DOCKER_VERSION"
    fi
    
    # 检查 docker-compose 安装状态
    if ! command -v docker-compose >/dev/null 2>&1; then
        print_red "Docker Compose 未安装，正在尝试安装..."
        install_docker_compose
    else
        COMPOSE_VERSION=$(docker-compose --version | awk '{print $3}' | sed 's/,//')
        print_green "Docker Compose 版本: $COMPOSE_VERSION"
    fi
    
    # 检查磁盘空间是否充足
    if [ "$DISK_USAGE" -gt 80 ]; then
        print_yellow "警告: 磁盘使用率超过 80%，建议清理磁盘空间"
        BACKUP_RETENTION_DAYS=3
        print_yellow "自动将备份保留天数调整为: $BACKUP_RETENTION_DAYS 天"
    fi
    
    # 检查内存是否充足
    if [ "$AVAILABLE_RAM" -lt 2048 ]; then
        print_yellow "警告: 内存小于 2GB，可能影响性能"
    fi
}

# 根据操作系统安装 Docker
install_docker() {
    case "$OS_TYPE" in
        debian|ubuntu)
            apt-get update && apt-get install -y apt-transport-https ca-certificates curl gnupg
            curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS_TYPE $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
            apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
            ;;
        centos)
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io
            systemctl start docker && systemctl enable docker
            ;;
        alpine)
            apk add --no-cache docker
            rc-update add docker boot
            service docker start
            ;;
    esac
}

# 安装 Docker Compose
install_docker_compose() {
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
}

# 确定部署目录
determine_deployment_directory() {
    print_blue "[阶段3] 确定部署目录..."
    
    # 优先检查 /opt/wp-docker
    if [ -d "/opt/wp-docker" ]; then
        DEPLOY_DIR="/opt/wp-docker"
        print_green "使用现有目录: $DEPLOY_DIR"
    # 其次检查 /var/wp-docker
    elif [ -d "/var/wp-docker" ]; then
        DEPLOY_DIR="/var/wp-docker"
        print_green "使用现有目录: $DEPLOY_DIR"
    # 都不存在则创建 /opt/wp-docker
    else
        print_green "创建部署目录: /opt/wp-docker"
        mkdir -p /opt/wp-docker || handle_error "无法创建部署目录"
        DEPLOY_DIR="/opt/wp-docker"
    fi
    
    # 创建必要的目录结构
    BACKUP_DIR="$DEPLOY_DIR/backups"
    SCRIPTS_DIR="$DEPLOY_DIR/scripts"
    LOGS_DIR="$DEPLOY_DIR/logs"
    
    mkdir -p "$BACKUP_DIR" || handle_error "无法创建备份目录"
    mkdir -p "$SCRIPTS_DIR" || handle_error "无法创建脚本目录"
    mkdir -p "$LOGS_DIR" || handle_error "无法创建日志目录"
    
    print_green "备份目录: $BACKUP_DIR"
    print_green "脚本目录: $SCRIPTS_DIR"
    print_green "日志目录: $LOGS_DIR"
    
    # 切换到部署目录
    cd "$DEPLOY_DIR" || handle_error "无法切换到部署目录"
    print_green "当前工作目录: $(pwd)"
}

# 生成随机密码
generate_password() {
    local length=${1:-24}
    tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c "$length" || echo "default_password_change_me"
}

# 生成 WordPress 安全密钥（格式化为Python-dotenv兼容）
generate_wordpress_keys() {
    print_blue "生成 WordPress 安全密钥..."
    local keys_url="https://api.wordpress.org/secret-key/1.1/salt/"
    # 获取密钥并移除单引号，替换空格为连字符，确保Python-dotenv兼容
    local keys=$(curl -s "$keys_url" || wget -qO- "$keys_url" || echo "# 安全密钥生成失败，请手动替换")
    # 移除单引号并处理格式，确保Python-dotenv兼容
    keys=$(echo "$keys" | sed "s/'//g" | sed "s/ /-/g")
    echo "$keys"
}

# 根据系统参数优化配置
optimize_parameters() {
    print_blue "[阶段4] 根据系统参数优化配置..."
    
    # 创建必要的目录结构
    mkdir -p configs/nginx/conf.d
    mkdir -p configs/mariadb
    mkdir -p configs/redis
    mkdir -p html
    mkdir -p logs/nginx
    mkdir -p logs/php
    
    # 计算资源限制
    local CPU_LIMIT=$((CPU_CORES / 2))
    local MEM_LIMIT=$((AVAILABLE_RAM / 2))
    
    # 根据内存大小调整 PHP 内存限制
    local PHP_MEMORY_LIMIT="512M"
    if [ "$AVAILABLE_RAM" -lt 2048 ]; then
        PHP_MEMORY_LIMIT="256M"
    elif [ "$AVAILABLE_RAM" -lt 4096 ]; then
        PHP_MEMORY_LIMIT="384M"
    else
        PHP_MEMORY_LIMIT="512M"
    fi
    
    print_green "CPU 限制: $CPU_LIMIT 核"
    print_green "内存限制: ${MEM_LIMIT}MB"
    print_green "PHP 内存限制: $PHP_MEMORY_LIMIT"
    
    # 生成 .env 文件（如果不存在）
    if [ ! -f ".env" ]; then
        print_blue "生成环境配置文件 (.env)..."
        
        # 生成随机密码
        local root_password=$(generate_password)
        local db_user_password=$(generate_password)
        local wp_keys=$(generate_wordpress_keys)
        
        # 定义版本变量（与根目录docker-compose.yml保持一致）
        local php_version="8.3.26"
        local nginx_version="1.27.2"
        local mariadb_version="11.3.2"
        local redis_version="7.4.0"
        
        # 写入 .env 文件
        cat > .env << EOF
# WordPress Docker环境变量配置
# 生成时间: $(date)

# Docker相关配置
DOCKERHUB_USERNAME=library  # Docker Hub用户名
PHP_VERSION=$php_version  # PHP版本
NGINX_VERSION=$nginx_version  # Nginx版本
MARIADB_VERSION=$mariadb_version  # MariaDB版本
REDIS_VERSION=$redis_version  # Redis版本

# 数据库配置
MYSQL_ROOT_PASSWORD=$root_password  # MySQL root用户密码
MYSQL_DATABASE=wordpress  # WordPress数据库名称
MYSQL_USER=wordpress  # WordPress数据库用户
MYSQL_PASSWORD=$db_user_password  # WordPress数据库用户密码

# WordPress配置
WORDPRESS_DB_HOST=mariadb:3306  # 数据库主机
WORDPRESS_DB_USER=${MYSQL_USER}  # WordPress数据库用户
WORDPRESS_DB_PASSWORD=${MYSQL_PASSWORD}  # WordPress数据库密码
WORDPRESS_DB_NAME=${MYSQL_DATABASE}  # WordPress数据库名称
WORDPRESS_REDIS_HOST=redis  # Redis主机
WORDPRESS_REDIS_PORT=6379  # Redis端口
WORDPRESS_TABLE_PREFIX=wp_  # WordPress数据库表前缀

# Redis配置
REDIS_HOST=redis  # Redis主机
REDIS_PORT=6379  # Redis端口
REDIS_PASSWORD=$(generate_password 16)  # Redis认证密码
REDIS_MAXMEMORY=256mb  # Redis最大内存限制

# 资源限制（自动优化）
CPU_LIMIT=$CPU_LIMIT
MEM_LIMIT=${MEM_LIMIT}MB
PHP_MEMORY_LIMIT=$PHP_MEMORY_LIMIT
UPLOAD_MAX_FILESIZE=64M  # 最大上传文件大小

# WordPress安全密钥
$wp_keys
EOF
        
        print_green "✓ .env 文件生成完成"
        print_yellow "注意: 敏感信息已保存在 .env 文件中，请妥善保管"
    else
        print_yellow "警告: .env 文件已存在，跳过生成"
        # 读取现有配置或设置默认值
        source .env 2>/dev/null || :
        CPU_LIMIT=${CPU_LIMIT:-$((CPU_CORES / 2))}
        MEM_LIMIT=${MEM_LIMIT:-${AVAILABLE_RAM/2}MB}
        PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT:-$PHP_MEMORY_LIMIT}
    fi
    
    # 生成 docker-compose.yml 文件（如果不存在）
    if [ ! -f "docker-compose.yml" ]; then
        print_blue "生成 Docker Compose 配置文件..."
        
        cat > docker-compose.yml << EOF
version: '3.8'

services:
  # --- MariaDB 数据库服务 ---
  mariadb:
    # 使用我们构建的MariaDB镜像，支持自动版本更新
    image: \${DOCKERHUB_USERNAME:-library}/wordpress-mariadb:\${MARIADB_VERSION:-11.3.2}
    container_name: wp_db
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      - db_data:/var/lib/mysql
      - $BACKUP_DIR:/backup
      - ./configs/mariadb/my.cnf:/etc/my.cnf:ro
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE:-wordpress}
      MYSQL_USER: \${MYSQL_USER:-wordpress}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    expose:
      - "3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-u", "root", "-p\${MYSQL_ROOT_PASSWORD}"]
      interval: 30s
      timeout: 10s
      retries: 3

  # --- Redis 缓存服务 ---
  redis:
    # 使用我们构建的Redis镜像，支持自动版本更新
    image: \${DOCKERHUB_USERNAME:-library}/wordpress-redis:\${REDIS_VERSION:-7.4.0}
    container_name: wp_redis
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      - redis_data:/data
      - ./configs/redis/redis.conf:/etc/redis/redis.conf:ro
    environment:
      REDIS_PASSWORD: \${REDIS_PASSWORD:-}
      REDIS_MAXMEMORY: \${REDIS_MAXMEMORY:-256mb}
    expose:
      - "6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3

  # --- PHP-FPM 服务 ---
  php:
    # 使用我们构建的PHP镜像，支持自动版本更新
    image: \${DOCKERHUB_USERNAME:-library}/wordpress-php:\${PHP_VERSION:-8.3.26}
    container_name: wp_fpm
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      # 注意：宿主机 html 目录挂载到容器内 /var/www/html
      - ./html:/var/www/html
      # 使用配置目录中的PHP配置
      - ./configs/php.ini:/usr/local/etc/php/php.ini:ro
      - ./logs:/var/log/php
    expose:
      - "9000"
    depends_on:
      mariadb:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      WORDPRESS_DB_HOST: mariadb:3306
      WORDPRESS_DB_USER: \${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: \${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: \${MYSQL_DATABASE}
      WORDPRESS_REDIS_HOST: redis
      WORDPRESS_REDIS_PORT: 6379
      PHP_OPCACHE_ENABLE: 1
      PHP_MEMORY_LIMIT: \${PHP_MEMORY_LIMIT:-512M}
    healthcheck:
      test: ["CMD", "php-fpm", "-t"]
      interval: 60s
      timeout: 10s
      retries: 3

  # --- Nginx 服务 ---
  nginx:
    # 使用我们构建的Nginx镜像，支持自动版本更新
    image: \${DOCKERHUB_USERNAME:-library}/wordpress-nginx:\${NGINX_VERSION:-1.27.2}
    container_name: wp_nginx
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      # 挂载自定义配置文件
      - ./configs/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./configs/nginx/conf.d:/etc/nginx/conf.d:ro
      - ./html:/var/www/html
      - ./logs/nginx:/var/log/nginx
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      php:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 60s
      timeout: 10s
      retries: 3

networks:
  app-network:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.18.0.0/16

volumes:
  db_data:
    driver: local
  redis_data:
    driver: local
EOF
        
        print_green "✓ docker-compose.yml 文件生成完成"
    else
        print_yellow "警告: docker-compose.yml 文件已存在，跳过生成"
    fi
    
    # 生成 Nginx 配置文件
    if [ ! -f "configs/nginx/nginx.conf" ]; then
        print_blue "生成 Nginx 配置文件..."
        
        # 根据 CPU 核心数优化 worker_processes
        local worker_processes="auto"
        if [ "$CPU_CORES" -le 2 ]; then
            worker_processes=$CPU_CORES
        fi
        
        # 生成主配置文件
        cat > configs/nginx/nginx.conf << EOF
user nginx;
worker_processes $worker_processes;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections $((1024 * CPU_CORES));
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    gzip on;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    include /etc/nginx/conf.d/*.conf;
}
EOF
        
        # 生成站点配置文件
        cat > configs/nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
    index index.php index.html index.htm;
    
    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    
    location ~ \.php$ {
        fastcgi_pass wp_fpm:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
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
        
        print_green "✓ Nginx 配置文件生成完成"
    else
        print_yellow "警告: Nginx 配置文件已存在，跳过生成"
    fi
    
    # 生成 PHP 配置文件
    if [ ! -f "configs/php.ini" ]; then
        print_blue "生成 PHP 配置文件..."
        
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
        
        print_green "✓ PHP 配置文件生成完成"
    else
        print_yellow "警告: PHP 配置文件已存在，跳过生成"
    fi
}

# 部署 WordPress Docker 栈
deploy_wordpress_stack() {
    print_blue "[阶段5] 部署 WordPress Docker 栈..."
    
    # 下载 WordPress（如果需要）
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
            print_blue "下载 WordPress 最新版本..."
            
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
                print_green "设置文件权限..."
                docker run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R www-data:www-data /var/www/html
                
                print_green "✓ WordPress 下载并解压完成"
            else
                print_yellow "警告: WordPress 下载失败，请手动下载并解压到 html 目录"
            fi
        else
            print_green "✓ html 目录已存在内容，跳过 WordPress 下载"
        fi
    else
        print_green "✓ WordPress 配置文件已存在，跳过下载"
    fi
    
    # 构建镜像（优先）
    print_blue "构建Docker镜像..."
    docker-compose build
    
    # 可选：如果需要从Docker Hub拉取，可以在这里添加条件拉取逻辑
    # 但默认情况下使用本地构建的镜像
    
    # 启动服务
    print_blue "启动 Docker 服务..."
    docker-compose up -d
    
    # 等待服务启动
    print_blue "等待服务初始化..."
    sleep 10
    
    # 检查服务状态
    print_blue "检查服务状态..."
    docker-compose ps
    
    # 验证部署是否成功
    if [ "$(docker-compose ps -q | wc -l)" -eq "4" ]; then
        print_green "✓ WordPress Docker 栈部署成功"
    else
        print_red "✗ WordPress Docker 栈部署失败，请检查日志"
        docker-compose logs --tail=50
    fi
}

# 设置自动数据库备份
setup_auto_backup() {
    print_blue "[阶段6] 设置自动数据库备份..."
    
    # 创建备份脚本
    cat > "$DEPLOY_DIR/scripts/backup_db.sh" << 'EOF'
#!/bin/bash

# 获取脚本所在目录的父目录
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$DEPLOY_DIR/backups"

# 从 .env 文件加载环境变量
if [ -f "$DEPLOY_DIR/.env" ]; then
    export $(grep -v '^#' "$DEPLOY_DIR/.env" | xargs)
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
    echo "清理 $BACKUP_RETENTION_DAYS 天前的备份..."
    find "$BACKUP_DIR" -name "db-*.sql.gz" -mtime +"$BACKUP_RETENTION_DAYS" -delete
    echo "✓ 旧备份清理完成"
else
    echo "✗ 数据库备份失败"
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
        print_green "✓ 数据库备份 cron 任务已创建（每天凌晨 3 点执行）"
    else
        print_yellow "警告: 数据库备份 cron 任务已存在"
    fi
    
    # 立即执行一次备份测试
    print_blue "执行备份测试..."
    "$DEPLOY_DIR/scripts/backup_db.sh"
}

# 配置磁盘空间管理
setup_disk_space_management() {
    print_blue "[阶段7] 配置磁盘空间管理..."
    
    # 创建磁盘监控脚本
    cat > "$DEPLOY_DIR/scripts/disk_monitor.sh" << 'EOF'
#!/bin/bash

# 获取脚本所在目录的父目录
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="$DEPLOY_DIR/logs/disk_monitor.log"

# 设置警告阈值
THRESHOLD=80

# 获取磁盘使用率
DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')

# 记录当前状态
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 磁盘使用率: ${DISK_USAGE}%" >> "$LOG_FILE"

# 检查是否超过阈值
if [ "$DISK_USAGE" -gt "$THRESHOLD" ]; then
    WARNING_MSG="警告: 磁盘使用率已达 ${DISK_USAGE}%，超过阈值 ${THRESHOLD}%"
    echo "$WARNING_MSG" >> "$LOG_FILE"
    
    # 尝试清理 Docker 系统
    echo "自动清理 Docker 系统..." >> "$LOG_FILE"
    docker system prune -f >> "$LOG_FILE" 2>&1
    
    # 尝试发送邮件（如果配置了 mail 命令）
    if command -v mail >/dev/null; then
        echo "$WARNING_MSG" | mail -s "磁盘空间警告" root
    fi
fi
EOF
    
    # 创建 Docker 清理脚本
    cat > "$DEPLOY_DIR/scripts/docker_cleanup.sh" << 'EOF'
#!/bin/bash

# 获取脚本所在目录的父目录
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="$DEPLOY_DIR/logs/docker_cleanup.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始清理 Docker 系统..." >> "$LOG_FILE"

# 清理未使用的镜像
echo "清理未使用的镜像..." >> "$LOG_FILE"
docker image prune -f >> "$LOG_FILE" 2>&1

# 清理未使用的卷
echo "清理未使用的卷..." >> "$LOG_FILE"
docker volume prune -f >> "$LOG_FILE" 2>&1

# 清理未使用的网络
echo "清理未使用的网络..." >> "$LOG_FILE"
docker network prune -f >> "$LOG_FILE" 2>&1

# 清理构建缓存
echo "清理构建缓存..." >> "$LOG_FILE"
docker builder prune -f >> "$LOG_FILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Docker 系统清理完成" >> "$LOG_FILE"
EOF
    
    # 设置执行权限
    chmod +x "$DEPLOY_DIR/scripts/disk_monitor.sh"
    chmod +x "$DEPLOY_DIR/scripts/docker_cleanup.sh"
    
    # 创建磁盘监控 cron 任务（每小时执行一次）
    MONITOR_CRON="0 * * * * $DEPLOY_DIR/scripts/disk_monitor.sh"
    if ! crontab -l 2>/dev/null | grep -q "disk_monitor.sh"; then
        (crontab -l 2>/dev/null; echo "$MONITOR_CRON") | crontab -
        print_green "✓ 磁盘监控 cron 任务已创建（每小时执行一次）"
    else
        print_yellow "警告: 磁盘监控 cron 任务已存在"
    fi
    
    # 创建 Docker 清理 cron 任务（每周日凌晨 2 点执行）
    CLEANUP_CRON="0 2 * * 0 $DEPLOY_DIR/scripts/docker_cleanup.sh"
    if ! crontab -l 2>/dev/null | grep -q "docker_cleanup.sh"; then
        (crontab -l 2>/dev/null; echo "$CLEANUP_CRON") | crontab -
        print_green "✓ Docker 清理 cron 任务已创建（每周日凌晨 2 点执行）"
    else
        print_yellow "警告: Docker 清理 cron 任务已存在"
    fi
    
    # 立即执行一次磁盘监控测试
    print_blue "执行磁盘监控测试..."
    "$DEPLOY_DIR/scripts/disk_monitor.sh"
}

# 显示部署信息
display_deployment_info() {
    print_blue "=================================================="
    print_green "部署完成！"
    print_blue "=================================================="
    
    # 获取主机 IP
    local HOST_IP=$(hostname -I | awk '{print $1}')
    
    print_green "访问地址: http://$HOST_IP"
    print_green ""
    print_green "部署详情:"
    print_green "  - 操作系统: $OS_TYPE $OS_VERSION"
    print_green "  - CPU 核心: $CPU_CORES 核（限制使用: $((CPU_CORES / 2)) 核）"
    print_green "  - 可用内存: ${AVAILABLE_RAM}MB（限制使用: $((AVAILABLE_RAM / 2))MB）"
    print_green "  - 部署目录: $DEPLOY_DIR"
    print_green "  - 备份目录: $BACKUP_DIR"
    print_green "  - 备份保留: $BACKUP_RETENTION_DAYS 天"
    print_green ""
    print_green "数据库信息:"
    print_green "  - 数据库名: wordpress"
    print_green "  - 用户名: wordpress"
    print_green "  - 密码: 请查看 .env 文件中的 MYSQL_PASSWORD"
    print_green "  - 主机: mariadb"
    print_green ""
    print_green "自动化功能:"
    print_green "  - ✅ 每日数据库自动备份（凌晨 3 点）"
    print_green "  - ✅ 每小时磁盘空间监控（阈值: 80%）"
    print_green "  - ✅ 每周 Docker 系统清理（周日凌晨 2 点）"
    print_green ""
    print_green "后续步骤:"
    print_green "1. 打开浏览器访问上述地址"
    print_green "2. 完成 WordPress 安装向导"
    print_green "3. 推荐安装 Redis Object Cache 插件启用缓存"
    print_green ""
    print_yellow "重要: 请备份 .env 文件，包含所有敏感信息"
    print_blue "=================================================="
}

# 主函数
main() {
    # 创建脚本目录
    mkdir -p "$DEPLOY_DIR/scripts" 2>/dev/null || :
    
    # 执行各阶段
    detect_host_environment        # 检测宿主机环境
    collect_system_parameters      # 收集系统参数
    determine_deployment_directory # 确定部署目录
    optimize_parameters            # 优化参数
    deploy_wordpress_stack         # 部署 WordPress Docker 栈
    setup_auto_backup              # 设置自动数据库备份
    setup_disk_space_management    # 配置磁盘空间管理
    display_deployment_info        # 显示部署信息
    
    print_green "🎉 WordPress Docker 全栈部署完成！"
}

# 执行主函数
main
