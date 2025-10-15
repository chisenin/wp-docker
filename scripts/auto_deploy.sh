#!/bin/bash
#!/bin/bash
set -e

# 自动部署脚本：创建目录、生成 .env 和 docker-compose.yml、下载 WordPress、一键启动
# 用法：./auto_deploy.sh [DOCKERHUB_USERNAME] [PROJECT_DIR]
# 默认：DOCKERHUB_USERNAME=library, PROJECT_DIR=~/wordpress-project

# 配置项
DEFAULT_DOCKERHUB_USERNAME="library"
DEFAULT_PROJECT_DIR="$HOME/wordpress-project"
WP_DOWNLOAD_URL="https://wordpress.org/latest.tar.gz"
MYSQL_DATABASE="wordpress"

# 获取最新版本信息（从GitHub API）
get_latest_versions() {
    echo "获取最新版本信息..."
    
    # 如果无法访问GitHub API，使用默认值
    local default_php_version="8.3-fpm-alpine3.22"
    local default_nginx_version="1.27-alpine"
    
    # 尝试从GitHub获取最新版本
    # 注意：实际使用时需要替换为正确的API端点
    local php_version_response=$(curl -s --retry 3 "https://raw.githubusercontent.com/chisenin/wp-docker/main/Dockerfiles/php/php_version.txt" || echo "$default_php_version")
    local nginx_version_response=$(curl -s --retry 3 "https://raw.githubusercontent.com/chisenin/wp-docker/main/Dockerfiles/nginx/nginx_version.txt" || echo "$default_nginx_version")
    
    # 清理版本信息
    PHP_VERSION=$(echo "$php_version_response" | tr -d '[:space:]')
    NGINX_VERSION=$(echo "$nginx_version_response" | tr -d '[:space:]')
    
    # 如果获取失败，使用默认值
    [ -z "$PHP_VERSION" ] && PHP_VERSION="$default_php_version"
    [ -z "$NGINX_VERSION" ] && NGINX_VERSION="$default_nginx_version"
    
    echo "使用 PHP 版本: $PHP_VERSION"
    echo "使用 Nginx 版本: $NGINX_VERSION"
}

# 生成随机字符串函数（不含特殊字符的强密码）
generate_secure_password() {
    local length=${1:-20}
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 $((length * 3/4)) | tr -dc 'A-Za-z0-9' | head -c $length
    else
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c $length
    fi
}

# 生成 WordPress 安全密钥
generate_wp_salts() {
    local salts
    salts=$(curl -s --retry 3 https://api.wordpress.org/secret-key/1.1/salt/ || true)
    if [ -z "$salts" ]; then
        echo "警告：无法连接到WordPress API，使用本地生成的随机安全密钥"
        local keys=("AUTH_KEY" "SECURE_AUTH_KEY" "LOGGED_IN_KEY" "NONCE_KEY" "AUTH_SALT" "SECURE_AUTH_SALT" "LOGGED_IN_SALT" "NONCE_SALT")
        salts=""
        for key in "${keys[@]}"; do
            local value=$(generate_secure_password 64)
            salts="${salts}WORDPRESS_${key}='$value'\n"
        done
    else
        # 转换WordPress API返回的格式为.env格式
        salts=$(echo "$salts" | sed -E 's/define\(\s*\'(\w+)\'\s*,\s*\'([^']+)\'\s*\);/WORDPRESS_\1=\'\2\'/g')
    fi
    echo -e "$salts"
}

# 生成Nginx配置文件
generate_nginx_config() {
    echo "生成Nginx配置文件..."
    
    # Nginx主配置
    cat > configs/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    
    sendfile on;
    #tcp_nopush on;
    
    keepalive_timeout 65;
    
    #gzip on;
    
    include /etc/nginx/conf.d/*.conf;
}
EOF
    
    # WordPress站点配置
    cat > configs/nginx/conf.d/wordpress.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.php index.html index.htm;
    
    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    
    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_pass wp:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
    
    location ~* \.(jpg|jpeg|png|gif|css|js|ico)$ {
        expires max;
        log_not_found off;
    }
    
    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }
    
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    
    location ~ /\. {
        deny all;
    }
}
EOF
}

# 生成PHP配置文件
generate_php_config() {
    echo "生成PHP配置文件..."
    
    # PHP-FPM配置（覆盖某些默认值）
    cat > configs/php/php.ini << 'EOF';
[PHP]
max_execution_time = 300
memory_limit = 256M
post_max_size = 64M
upload_max_filesize = 64M
default_socket_timeout = 60

[Date]
date.timezone = Asia/Shanghai

[Session]
session.save_handler = files
session.save_path = /var/lib/php/sessions
session.gc_probability = 1
session.gc_divisor = 1000
session.gc_maxlifetime = 1440

[opcache]
zend_extension=opcache.so
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
EOF
}

# 主函数
main() {
    local dockerhub_username="${1:-$DEFAULT_DOCKERHUB_USERNAME}"
    local project_dir="${2:-$DEFAULT_PROJECT_DIR}"
    
    echo "开始自动部署 WordPress 项目..."
    echo "使用 DockerHub 用户名: $dockerhub_username"
    echo "部署目录: $project_dir"
    
    # 检查依赖
    command -v docker >/dev/null 2>&1 || { echo "错误：Docker 未安装"; exit 1; }
    command -v docker-compose >/dev/null 2>&1 || {
        echo "警告：未找到 docker-compose 命令，尝试使用 docker compose..."
        if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
            echo "错误：Docker Compose 未安装"
            exit 1
        fi
        DOCKER_COMPOSE="docker compose"
    } || {
        DOCKER_COMPOSE="docker-compose"
    }
    
    command -v wget >/dev/null 2>&1 || {
        echo "警告：未找到 wget 命令，尝试使用 curl..."
        if ! command -v curl >/dev/null 2>&1; then
            echo "错误：wget 或 curl 未安装，无法下载 WordPress"
            exit 1
        fi
        DOWNLOAD_TOOL="curl -o"
        DOWNLOAD_FLAGS="-sL"
    } || {
        DOWNLOAD_TOOL="wget"
        DOWNLOAD_FLAGS="-O"
    }
    
    # 获取最新版本
    get_latest_versions
    
    # 创建项目目录
    echo "创建项目目录结构..."
    mkdir -p "$project_dir/html" "$project_dir/configs/nginx/conf.d" "$project_dir/configs/php"
    cd "$project_dir"
    
    # 生成随机值
    echo "生成安全凭据..."
    local mysql_root_password="$(generate_secure_password 24)"
    local mysql_user="wp_$(generate_secure_password 8 | tr '[:upper:]' '[:lower:]')"
    local mysql_password="$(generate_secure_password 24)"
    local wp_salts="$(generate_wp_salts)"
    
    # 生成 .env 文件
    echo "生成 .env 文件..."
    cat > .env << EOF
DOCKERHUB_USERNAME=$dockerhub_username
PHP_VERSION=$PHP_VERSION
NGINX_VERSION=$NGINX_VERSION
MYSQL_ROOT_PASSWORD=$mysql_root_password
MYSQL_DATABASE=$MYSQL_DATABASE
MYSQL_USER=$mysql_user
MYSQL_PASSWORD=$mysql_password

$wp_salts
EOF
    chmod 600 .env
    
    # 生成 docker-compose.yml
    echo "生成 docker-compose.yml 文件..."
    cat > docker-compose.yml << 'EOF'
services:
  db:
    image: mariadb:10.11.14
    container_name: wp_db
    restart: unless-stopped
    networks: [app-network]
    volumes: [db_data:/var/lib/mysql]
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    expose: ["3306"]

  redis:
    image: redis:8.2.2-alpine3.22
    container_name: wp_redis
    restart: unless-stopped
    networks: [app-network]
    command: redis-server --appendonly yes
    volumes: [redis_data:/data]
    expose: ["6379"]

  wp:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-php:${PHP_VERSION:-8.3-fpm-alpine3.22}
    container_name: wp_fpm
    restart: unless-stopped
    networks: [app-network]
    volumes:
      - ./html:/var/www/html
      - ./configs/php/php.ini:/usr/local/etc/php/conf.d/custom.ini:ro
    expose: ["9000"]
    depends_on: [db, redis]
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_USER: ${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
      WORDPRESS_REDIS_HOST: redis
      WORDPRESS_REDIS_PORT: 6379

  nginx:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-nginx:${NGINX_VERSION:-1.27-alpine}
    container_name: wp_nginx
    restart: unless-stopped
    networks: [app-network]
    volumes:
      - ./configs/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./configs/nginx/conf.d:/etc/nginx/conf.d:ro
      - ./html:/var/www/html
    ports: ["80:80"]
    depends_on: [wp]

networks:
  app-network:
    driver: bridge

volumes:
  db_data:
  redis_data:
EOF

    # 下载并解压 WordPress
    echo "下载并安装 WordPress..."
    $DOWNLOAD_TOOL wp.tar.gz $DOWNLOAD_FLAGS "$WP_DOWNLOAD_URL"
    tar -xvzf wp.tar.gz
    mv wordpress/* html/
    rm -rf wordpress wp.tar.gz
    
    # 创建uploads目录并设置权限
    mkdir -p html/wp-content/uploads
    
    # 生成Nginx和PHP配置
    generate_nginx_config
    generate_php_config
    
    # 启动服务
    echo "拉取Docker镜像..."
    $DOCKER_COMPOSE pull
    
    echo "启动Docker服务..."
    $DOCKER_COMPOSE up -d
    
    # 等待容器启动并设置权限
    echo "等待服务初始化..."
    sleep 10
    
    # 获取容器ID并设置文件权限
    WP_CONTAINER_ID=$($DOCKER_COMPOSE ps -q wp || echo "")
    if [ -n "$WP_CONTAINER_ID" ]; then
        echo "设置WordPress文件权限..."
        docker exec -it $WP_CONTAINER_ID chown -R www-data:www-data /var/www/html
    fi
    
    # 显示完成信息
    echo -e "\n=========================================="
    echo "WordPress 自动部署完成！"
    echo "=========================================="
    echo "访问 http://您的服务器IP 完成WordPress安装"
    echo "\n重要信息："
    echo "- DockerHub用户名: $dockerhub_username"
    echo "- 项目目录: $project_dir"
    echo "- 数据库名称: $MYSQL_DATABASE"
    echo "- 数据库用户名: $mysql_user"
    echo "\n注意：所有敏感凭据（包括数据库密码和WordPress安全密钥）"
    echo "已保存在 $project_dir/.env 文件中，请妥善备份！"
    echo "=========================================="
}

# 运行主函数
main "$@"