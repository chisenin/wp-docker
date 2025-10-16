#!/bin/bash

# 自动部署脚本 - WordPress + Docker Compose 一键部署
# 本脚本会：创建目录结构、生成配置文件、下载WordPress、启动服务

echo "=================================================="
echo "WordPress Docker 自动部署脚本"
echo "=================================================="

# 创建并切换到部署目录
create_deployment_directory() {
    echo "创建部署目录..."
    
    # 提示用户输入部署目录名称，默认为wordpress-docker
    read -p "请输入部署目录名称 [默认: wordpress-docker]: " DEPLOY_DIR_NAME
    DEPLOY_DIR_NAME=${DEPLOY_DIR_NAME:-wordpress-docker}
    
    # 避免在系统重要目录直接创建
    if [[ "$DEPLOY_DIR_NAME" == "/" || "$DEPLOY_DIR_NAME" == "/root" || "$DEPLOY_DIR_NAME" == "/home" ]]; then
        echo "错误: 不能使用系统目录作为部署目录"
        exit 1
    fi
    
    # 创建完整的部署目录路径
    DEPLOY_DIR="$(pwd)/$DEPLOY_DIR_NAME"
    
    # 检查目录是否已存在
    if [ -d "$DEPLOY_DIR" ]; then
        read -p "目录 '$DEPLOY_DIR' 已存在，是否继续 [y/N]: " CONTINUE
        if [[ "$CONTINUE" != [Yy]* ]]; then
            echo "部署已取消"
            exit 0
        fi
    else
        # 创建新目录
        mkdir -p "$DEPLOY_DIR"
        echo "✓ 已创建部署目录: $DEPLOY_DIR"
    fi
    
    # 切换到部署目录
    cd "$DEPLOY_DIR" || { echo "错误: 无法切换到部署目录"; exit 1; }
    echo "✓ 已切换到部署目录: $(pwd)"
}

# 检查必要的工具
check_dependencies() {
    echo "检查依赖工具..."
    command -v docker >/dev/null 2>&1 || { echo "错误: 需要安装 Docker，但未找到。"; exit 1; }
    command -v docker-compose >/dev/null 2>&1 || { echo "错误: 需要安装 Docker Compose，但未找到。"; exit 1; }
    command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || { echo "错误: 需要安装 wget 或 curl，但都未找到。"; exit 1; }
    echo "✓ 依赖检查通过"
}

# 生成随机密码
generate_password() {
    local length=$1
    tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c "$length" || echo "default_password_change_me"
}

# 生成 WordPress 安全密钥
generate_wordpress_keys() {
    echo "生成 WordPress 安全密钥..."
    local keys_url="https://api.wordpress.org/secret-key/1.1/salt/"
    local keys=$(curl -s "$keys_url" || wget -qO- "$keys_url" || echo "# 安全密钥生成失败，请手动替换")
    echo "$keys"
}

# 创建目录结构
create_directory_structure() {
    echo "创建项目目录结构..."
    mkdir -p configs/nginx/conf.d
    mkdir -p html
    echo "✓ 目录结构创建完成"
}

# 生成 .env 文件
generate_env_file() {
    echo "生成环境配置文件 (.env)..."
    
    # 生成随机密码
    local root_password=$(generate_password 24)
    local db_user_password=$(generate_password 24)
    local wp_keys=$(generate_wordpress_keys)
    
    # 定义版本变量
    local php_version="8.3.26"
    local nginx_version="1.27.2"
    local db_version="10.11.14"
    local redis_version="8.2.2-alpine3.22"
    
    # 写入 .env 文件
    cat > .env << EOF
# 数据库配置
MYSQL_ROOT_PASSWORD=$root_password
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=$db_user_password

# WordPress 配置
WORDPRESS_DB_HOST=mariadb:3306
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=$db_user_password
WORDPRESS_DB_NAME=wordpress
WORDPRESS_REDIS_HOST=redis
WORDPRESS_REDIS_PORT=6379
WORDPRESS_TABLE_PREFIX=wp_

# 版本配置
PHP_VERSION=$php_version
NGINX_VERSION=$nginx_version
DB_VERSION=$db_version
REDIS_VERSION=$redis_version

# WordPress 安全密钥
$wp_keys
EOF
    
    echo "✓ .env 文件生成完成"
    echo "注意: 敏感信息已保存在 .env 文件中，请妥善保管"
}

# 生成 docker-compose.yml 文件
generate_docker_compose_file() {
    echo "生成 Docker Compose 配置文件..."
    
    cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  mariadb:
    image: mariadb:${DB_VERSION:-10.11.14}
    container_name: wp_db
    restart: unless-stopped
    networks: [app-network]
    volumes: [db_data:/var/lib/mysql]
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE:-wordpress}
      MYSQL_USER: ${MYSQL_USER:-wordpress}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    expose: ["3306"]

  redis:
    image: redis:${REDIS_VERSION:-8.2.2-alpine3.22}
    container_name: wp_redis
    restart: unless-stopped
    networks: [app-network]
    command: redis-server --appendonly yes
    volumes: [redis_data:/data]
    expose: ["6379"]

  php:
    image: chisenin/wordpress-php:${PHP_VERSION:-8.3.26}
    container_name: wp_fpm
    restart: unless-stopped
    networks: [app-network]
    volumes:
      - ./html:/var/www/html
      - ./configs/php.ini:/usr/local/etc/php/php.ini:ro
    expose: ["9000"]
    depends_on: [mariadb, redis]
    environment:
      WORDPRESS_DB_HOST: ${WORDPRESS_DB_HOST:-mariadb:3306}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER:-wordpress}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME:-wordpress}
      WORDPRESS_TABLE_PREFIX: ${WORDPRESS_TABLE_PREFIX:-wp_}
      WORDPRESS_REDIS_HOST: ${WORDPRESS_REDIS_HOST:-redis}
      WORDPRESS_REDIS_PORT: ${WORDPRESS_REDIS_PORT:-6379}
      # WordPress 安全密钥将从 .env 文件注入

  nginx:
    image: chisenin/wordpress-nginx:${NGINX_VERSION:-1.27.2}
    container_name: wp_nginx
    restart: unless-stopped
    networks: [app-network]
    volumes:
      - ./configs/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./configs/nginx/conf.d:/etc/nginx/conf.d:ro
      - ./html:/var/www/html
    ports: ["80:80"]
    depends_on: [php]

networks:
  app-network:
    driver: bridge

volumes:
  db_data:
  redis_data:
EOF
    
    echo "✓ docker-compose.yml 文件生成完成"
}

# 生成 Nginx 配置文件
generate_nginx_config() {
    echo "生成 Nginx 配置文件..."
    
    # 生成主配置文件
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
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    keepalive_timeout 65;
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
        fastcgi_pass wp:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
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
    
    echo "✓ Nginx 配置文件生成完成"
}

# 生成 PHP 配置文件
generate_php_config() {
    echo "生成 PHP 配置文件..."
    
    cat > configs/php.ini << 'EOF'
[PHP]
memory_limit = 512M
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
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 4000
opcache.revalidate_freq = 60
opcache.fast_shutdown = 1
EOF
    
    echo "✓ PHP 配置文件生成完成"
}

# 下载 WordPress
download_wordpress() {
    echo "下载 WordPress 最新版本..."
    
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
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
                echo "设置文件权限..."
                docker run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R www-data:www-data /var/www/html
                
                echo "✓ WordPress 下载并解压完成"
            else
                echo "警告: WordPress 下载失败，请手动下载并解压到 html 目录"
            fi
        else
            echo "✓ html 目录已存在内容，跳过 WordPress 下载"
        fi
    else
        echo "✓ WordPress 配置文件已存在，跳过下载"
    fi
}

# 启动服务
start_services() {
    echo "启动 Docker 服务..."
    
    # 拉取最新镜像（静默模式）
    echo "拉取最新镜像..."
    docker-compose pull --quiet
    
    # 启动服务
    echo "启动容器..."
    docker-compose up -d
    
    # 检查服务状态
    echo "检查服务状态..."
    docker-compose ps
    
    echo "✓ 服务启动完成"
}

# 显示部署信息
display_deployment_info() {
    echo "=================================================="
    echo "部署完成！"
    echo "=================================================="
    echo "访问地址: http://$(hostname -I | awk '{print $1}')"
    echo ""
    echo "数据库信息:"
    echo "  - 数据库名: wordpress"
    echo "  - 用户名: wordpress"
    echo "  - 密码: 请查看 .env 文件中的 MYSQL_PASSWORD"
    echo "  - 主机: db"
    echo ""
    echo "后续步骤:"
    echo "1. 打开浏览器访问上述地址"
    echo "2. 完成 WordPress 安装向导"
    echo "3. 推荐安装 Redis Object Cache 插件启用缓存"
    echo ""
    echo "重要: 请备份 .env 文件，包含所有敏感信息"
    echo "=================================================="
}

# 主函数
main() {
    create_deployment_directory  # 先创建并切换到部署目录
    check_dependencies
    create_directory_structure
    generate_env_file
    generate_docker_compose_file
    generate_nginx_config
    generate_php_config
    download_wordpress
    start_services
    display_deployment_info
}

# 执行主函数
main
