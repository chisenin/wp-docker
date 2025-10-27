#!/bin/bash

# WordPress Docker 全栈自动部署脚本 - 生产环境优化版

set -e
# set -x  # 启用调试模式，完成后可注释掉

# 颜色输出函数
print_blue() { echo -e "\033[34m$1\033[0m"; }
print_green() { echo -e "\033[32m$1\033[0m"; }
print_yellow() { echo -e "\033[33m$1\033[0m"; }
print_red() { echo -e "\033[31m$1\033[0m"; }

# 生成随机密码
generate_password() {
    length=${1:-32}
    tr -dc 'A-Za-z0-9!@#$%^&*()' < /dev/urandom | head -c "$length" 2>/dev/null || openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*()' | head -c "$length"
}

# 生成 WordPress 安全密钥
generate_wordpress_keys() {
    local keys=()
    local key_names=("AUTH_KEY" "SECURE_AUTH_KEY" "LOGGED_IN_KEY" "NONCE_KEY" "AUTH_SALT" "SECURE_AUTH_SALT" "LOGGED_IN_SALT" "NONCE_SALT")
    local api_success=false
    
    print_blue "尝试从 WordPress API 获取安全密钥..."
    if command -v curl >/dev/null; then
        keys=($(curl -s --connect-timeout 10 https://api.wordpress.org/secret-key/1.1/salt/ | grep "define" | sed "s/define('\(.*\)',\s*'\(.*\)');/\1=\2/" || true))
        if [ ${#keys[@]} -eq 8 ]; then
            api_success=true
            print_green "✓ 成功从 WordPress API 获取密钥"
        else
            print_yellow "警告: WordPress API 请求失败或返回不完整密钥，生成随机密钥..."
        fi
    elif command -v wget >/dev/null; then
        keys=($(wget -q --timeout=10 -O - https://api.wordpress.org/secret-key/1.1/salt/ | grep "define" | sed "s/define('\(.*\)',\s*'\(.*\)');/\1=\2/" || true))
        if [ ${#keys[@]} -eq 8 ]; then
            api_success=true
            print_green "✓ 成功从 WordPress API 获取密钥"
        else
            print_yellow "警告: WordPress API 请求失败或返回不完整密钥，生成随机密钥..."
        fi
    else
        print_yellow "警告: 未找到 curl 或 wget，生成随机密钥..."
    fi
    
    if [ "$api_success" = false ]; then
        keys=()
        for key in "${key_names[@]}"; do
            keys+=("$key=$(generate_password 64)")
        done
        print_green "✓ 已生成随机密钥"
    fi
    
    for key in "${keys[@]}"; do
        if [[ "$key" =~ ^[A-Z_]+=.+$ ]]; then
            echo "$key"
        else
            print_red "错误: 无效的密钥格式: $key"
            exit 1
        fi
    done
}

# 检查宿主机环境
prepare_host_environment() {
    print_blue "检查并准备宿主机环境..."
    print_blue "------------------------------------------------"
    
    if [ -f /proc/sys/vm/overcommit_memory ]; then
        overcommit=$(cat /proc/sys/vm/overcommit_memory)
        if [ "$overcommit" -ne 1 ]; then
            print_yellow "警告: vm.overcommit_memory 未设置为 1，尝试修改..."
            if sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1; then
                print_green "✓ vm.overcommit_memory 设置为 1"
            else
                print_red "错误: 无法设置 vm.overcommit_memory，请手动设置为 1"
                exit 1
            fi
        else
            print_green "✓ 正确 (值为 1)。"
        fi
    else
        print_yellow "警告: 未找到 /proc/sys/vm/overcommit_memory，可能在容器环境中"
    fi
    
    if systemctl is-active docker >/dev/null 2>&1; then
        print_green "✓ 正常 (无需 sudo)。"
    elif docker info >/dev/null 2>&1; then
        print_green "✓ 正常 (无需 sudo)。"
    else
        print_red "错误: Docker 服务未运行或未安装"
        exit 1
    fi
    
    if command -v docker-compose >/dev/null 2>&1; then
        print_green "✓ 正常。"
        DOCKER_COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        print_green "✓ 正常。"
        DOCKER_COMPOSE_CMD="docker compose"
    else
        print_red "错误: Docker Compose 未安装"
        exit 1
    fi
    
    DOCKER_CMD="docker"
    print_green "宿主机环境检查完成。"
    print_blue "------------------------------------------------"
}

# 检测主机环境
detect_host_environment() {
    print_blue "[步骤1] 检测主机环境.."
    OS=$(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null || echo "unknown")
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    AVAILABLE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    AVAILABLE_DISK=$(df -h / | awk 'NR==2{print $4}' | sed 's/G//')
    
    print_green "操作系统: $OS"
    print_green "CPU 核心数 $CPU_CORES"
    print_green "可用内存: ${AVAILABLE_RAM}MB"
    print_green "可用磁盘空间: ${AVAILABLE_DISK}GB"
}

# 收集系统参数
collect_system_parameters() {
    print_blue "[步骤2] 收集系统参数..."
    
    print_blue "检查必要的系统工具..."
    for tool in curl wget tar; do
        if ! command -v $tool >/dev/null 2>&1; then
            print_yellow "警告: 未找到 $tool，尝试安装..."
            apt-get update >/dev/null 2>&1
            apt-get install -y $tool >/dev/null 2>&1 || print_yellow "警告: 无法自动安装 $tool，请手动安装"
        fi
    done
    
    print_blue "更新软件包列表.."
    apt-get update >/dev/null 2>&1 || print_yellow "警告: 软件包列表更新失败"
    
    print_blue "安装必要的工具.."
    for tool in dos2unix sed; do
        if ! command -v $tool >/dev/null 2>&1; then
            apt-get install -y $tool >/dev/null 2>&1 || print_yellow "警告: 无法自动安装 $tool"
        fi
    done
    
    print_green "Docker 版本: $($DOCKER_CMD --version)"
    print_green "Docker Compose 版本: $($DOCKER_COMPOSE_CMD version)"
}

# 确定部署目录
determine_deployment_directory() {
    print_blue "[步骤3] 确定部署目录..."
    DEPLOY_DIR="/opt"
    BACKUP_DIR="/opt/backups"
    
    mkdir -p "$DEPLOY_DIR" "$BACKUP_DIR" 2>/dev/null || :
    cd "$DEPLOY_DIR" || {
        print_red "错误: 无法切换到部署目录 $DEPLOY_DIR"
        exit 1
    }
    
    print_green "部署目录: $DEPLOY_DIR"
    print_green "备份目录: $BACKUP_DIR"
}

# 优化系统参数
optimize_parameters() {
    print_blue "[步骤4] 优化系统参数..."
    
    TOTAL_MIN_MEMORY=768
    if [ "$AVAILABLE_RAM" -lt "$TOTAL_MIN_MEMORY" ]; then
        MEMORY_PER_SERVICE=256
        print_yellow "警告: 系统内存不足，将为每个服务分配最小可行内存: ${MEMORY_PER_SERVICE}MB"
    else
        MEMORY_PER_SERVICE=$((AVAILABLE_RAM * 2 / 7))
        print_green "为各服务分配内存: ${MEMORY_PER_SERVICE}MB"
    fi
    
    CPU_LIMIT=$((CPU_CORES / 2))
    if [ "$CPU_LIMIT" -lt 1 ]; then
        CPU_LIMIT=1
    fi
    
    PHP_MEMORY_LIMIT="512M"
    if [ "$AVAILABLE_RAM" -lt 2048 ]; then
        PHP_MEMORY_LIMIT="256M"
    elif [ "$AVAILABLE_RAM" -lt 4096 ]; then
        PHP_MEMORY_LIMIT="384M"
    else
        PHP_MEMORY_LIMIT="512M"
    fi
    
    print_green "CPU 限制: $CPU_LIMIT 核心"
    print_green "内存限制: ${MEMORY_PER_SERVICE}MB"
    print_green "PHP 内存限制: $PHP_MEMORY_LIMIT"
    
    if [ ! -f ".env" ]; then
        print_blue "生成环境配置文件 (.env)..."
        
        root_password=$(generate_password)
        db_user_password=$(generate_password)
        redis_pwd=$(generate_password 16)
        
        php_version="8.3.26"
        nginx_version="1.27.2"
        mariadb_version="11.3.2"
        redis_version="7.4.0"
        
        cat > .env << EOF
# WordPress Docker 环境配置文件
# 生成时间: $(date)

DOCKERHUB_USERNAME=library
PHP_VERSION=${php_version}
NGINX_VERSION=${nginx_version}
MARIADB_VERSION=${mariadb_version}
REDIS_VERSION=${redis_version}

MYSQL_ROOT_PASSWORD=${root_password}
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=${db_user_password}

WORDPRESS_DB_HOST=mariadb:3306
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=${db_user_password}
WORDPRESS_DB_NAME=wordpress
WORDPRESS_REDIS_HOST=redis
WORDPRESS_REDIS_PORT=6379
WORDPRESS_TABLE_PREFIX=wp_

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${redis_pwd}
REDIS_MAXMEMORY=256mb

CPU_LIMIT=${CPU_LIMIT}
MEMORY_PER_SERVICE=${MEMORY_PER_SERVICE}
PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT}
UPLOAD_MAX_FILESIZE=64M
PHP_INI_PATH=./deploy/configs/php.ini

# WordPress 密钥
$(generate_wordpress_keys)
EOF
        
        if command -v dos2unix >/dev/null 2>&1; then
            dos2unix .env >/dev/null 2>&1 && print_green "✓ 成功将 .env 文件行尾字符转换为 LF"
        elif command -v sed >/dev/null 2>&1; then
            sed -i 's/\r$//' .env >/dev/null 2>&1 && print_green "✓ 成功使用 sed 将 .env 文件行尾字符转换为 LF"
        else
            print_yellow "注意: 无法自动转换行尾字符，请在 Linux 环境下手动执行 'dos2unix .env'"
        fi
        
        chmod 600 .env
        print_green ".env 文件创建成功"
        print_green "✓ 已设置 .env 文件权限为 600（安全权限）"
        print_yellow "警告: 请妥善保存 .env 文件中的敏感信息"
        
        # 验证 .env 文件中的密钥
        print_blue "验证 .env 文件中的密钥..."
        for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            if ! grep -q "^$key=" .env; then
                print_red "错误: .env 文件中缺失密钥 $key"
                print_yellow ".env 文件内容（屏蔽敏感信息）："
                sed 's/\(MYSQL_ROOT_PASSWORD\|MYSQL_PASSWORD\|REDIS_PASSWORD\)=.*/\1=[HIDDEN]/' .env
                exit 1
            fi
        done
        print_green "✓ .env 文件密钥验证通过"
    else
        print_yellow "注意: .env 文件已存在，使用现有配置"
        source .env 2>/dev/null || :
        CPU_LIMIT=${CPU_LIMIT:-$((CPU_CORES / 2))}
        MEMORY_PER_SERVICE=${MEMORY_PER_SERVICE:-$((AVAILABLE_RAM / 2))}
        PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT:-256M}
        
        # 验证现有 .env 文件中的密钥
        print_blue "验证现有 .env 文件中的密钥..."
        for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            if ! grep -q "^$key=" .env; then
                print_red "错误: 现有 .env 文件中缺失密钥 $key，尝试重新生成..."
                rm -f .env
                optimize_parameters
                return
            fi
        done
        print_green "✓ 现有 .env 文件密钥验证通过"
    fi
    
    mkdir -p ./configs/nginx/conf.d
    print_blue "生成 Nginx 配置文件..."
    cat > ./configs/nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
    index index.php index.html index.htm;

    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
    fastcgi_read_timeout 300;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg|eot|otf|ttc)$ {
        expires max;
        log_not_found off;
    }

    error_log /var/log/nginx/error.log warn;
    access_log /var/log/nginx/access.log;
}
EOF
    print_green "Nginx 配置文件创建成功"
    
    print_blue "验证 Nginx 配置文件..."
    cp ./configs/nginx/conf.d/default.conf /tmp/default.conf
    sed -i 's/fastcgi_pass php:9000;/fastcgi_pass 127.0.0.1:9000;/' /tmp/default.conf
    if $DOCKER_CMD run --rm -v /tmp/default.conf:/etc/nginx/conf.d/default.conf nginx:${NGINX_VERSION:-1.27.2} nginx -t -c /etc/nginx/nginx.conf 2>&1 | tee /tmp/nginx_config_test.log; then
        print_green "✓ Nginx 配置文件语法正确"
    else
        print_red "错误: Nginx 配置文件语法错误，请检查以下内容："
        cat ./configs/nginx/conf.d/default.conf
        print_yellow "Nginx 配置测试日志："
        cat /tmp/nginx_config_test.log
        exit 1
    fi
    rm -f /tmp/default.conf
}

# 部署 WordPress Docker 栈
deploy_wordpress_stack() {
    print_blue "[步骤5] 部署 WordPress Docker 栈.."
    
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
            print_blue "下载 WordPress 核心文件..."
            temp_file="/tmp/wordpress-latest.tar.gz"
            if command -v wget >/dev/null; then
                wget -q -O "$temp_file" https://wordpress.org/latest.tar.gz
            else
                curl -s -o "$temp_file" https://wordpress.org/latest.tar.gz
            fi
            if [ -f "$temp_file" ]; then
                tar -xzf "$temp_file" -C .
                mv wordpress/* html/
                rm -rf wordpress "$temp_file"
                print_green "文件解压完成..."
                retry_count=3
                retry_delay=5
                docker_success=false
                
                for i in $(seq 1 $retry_count); do
                    print_blue "设置文件权限 (尝试 $i/$retry_count)..."
                    if $DOCKER_CMD run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R 33:33 /var/www/html 2>/dev/null; then
                        docker_success=true
                        print_green "Docker 设置权限成功"
                        break
                    else
                        print_yellow "警告: Docker 设置权限失败，$retry_delay 秒后重试..."
                        sleep $retry_delay
                    fi
                done
                
                if [ "$docker_success" = false ]; then
                    print_yellow "警告: Docker 权限设置失败，尝试直接使用 chown..."
                    if command -v chown >/dev/null; then
                        if chown -R 33:33 "$(pwd)/html" 2>/dev/null; then
                            print_green "直接 chown 命令设置成功"
                        else
                            print_yellow "警告: 请手动执行以下命令设置权限 chown -R www-data:www-data $(pwd)/html"
                        fi
                    else
                        print_yellow "警告: 系统中找不到 chown 命令，无法设置权限"
                    fi
                fi
                
                print_green "✓ WordPress 文件准备完成"
            else
                print_yellow "警告: WordPress 核心文件下载失败，请检查网络连接或手动放置文件到 html 目录"
            fi
        else
            print_green "html 目录已包含 WordPress 文件"
        fi
    else
        print_green "WordPress 配置文件已存在"
    fi
    
    print_blue "加载 .env 文件变量..."
    if [ -f ".env" ]; then
        set -a
        grep -E '^[A-Z_][A-Z0-9_]*=' .env | while IFS= read -r line; do
            if [[ "$line" == *"="* ]]; then
                key=$(echo "$line" | cut -d'=' -f1)
                value=$(echo "$line" | cut -d'=' -f2-)
                export "$key=$value"
            fi
        done
        set +a
        print_green "✓ 成功加载 .env 文件变量"
        print_yellow "加载的 .env 变量（屏蔽敏感信息）："
        grep -E '^[A-Z_][A-Z0-9_]*=' .env | sed 's/\(MYSQL_ROOT_PASSWORD\|MYSQL_PASSWORD\|REDIS_PASSWORD\)=.*/\1=[HIDDEN]/' || true
    else
        print_red "错误: .env 文件不存在!"
        exit 1
    fi
    
    print_blue "验证环境变量中的密钥..."
    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        if [ -z "${!key}" ]; then
            print_red "错误: 环境变量中缺失密钥 $key"
            print_yellow ".env 文件内容（屏蔽敏感信息）："
            sed 's/\(MYSQL_ROOT_PASSWORD\|MYSQL_PASSWORD\|REDIS_PASSWORD\)=.*/\1=[HIDDEN]/' .env
            exit 1
        fi
    done
    print_green "✓ 环境变量密钥验证通过"
    
    print_blue "更新 WordPress 密钥..."
    if [ ! -f "html/wp-config.php" ]; then
        print_yellow "警告: html/wp-config.php 文件不存在，正在创建文件..."
        
        mkdir -p "html"
        
        db_name=${MYSQL_DATABASE:-wordpress}
        db_user=${MYSQL_USER:-wordpress}
        db_password=${MYSQL_PASSWORD:-wordpresspassword}
        db_host=${WORDPRESS_DB_HOST:-mariadb:3306}
        table_prefix=${WORDPRESS_TABLE_PREFIX:-wp_}
        
        wp_keys=""
        for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            wp_keys="$wp_keys\ndefine('$key', '${!key}');"
        done
        
        cat > html/wp-config.php << EOF
<?php
/**
 * WordPress 配置文件
 * WordPress Docker 自动部署脚本生成
 */

// 数据库设置
define('DB_NAME', '$db_name');
define('DB_USER', '$db_user');
define('DB_PASSWORD', '$db_password');
define('DB_HOST', '$db_host');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

// 表前缀
define('WP_TABLE_PREFIX', '$table_prefix');

// 安全密钥
$wp_keys

// 其他设置
define('WP_DEBUG', false);
if ( !defined('ABSPATH') )
    define('ABSPATH', dirname(__FILE__) . '/');
require_once(ABSPATH . 'wp-settings.php');
EOF
        
        print_green "wp-config.php 文件创建成功"
    else
        sed_cmd="sed -i"
        if ! sed --version >/dev/null 2>&1; then
            sed_cmd="sed -i ''"
        fi
        
        for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            if [ -n "${!key}" ]; then
                $sed_cmd "s|define('$key',.*);|define('$key', '${!key}');|g" html/wp-config.php
            else
                print_red "错误: 缺失密钥 $key，无法更新 wp-config.php"
                print_yellow ".env 文件内容（屏蔽敏感信息）："
                sed 's/\(MYSQL_ROOT_PASSWORD\|MYSQL_PASSWORD\|REDIS_PASSWORD\)=.*/\1=[HIDDEN]/' .env
                exit 1
            fi
        done
        
        print_green "WordPress 密钥更新完成"
    fi
    
    print_blue "验证 wp-config.php 语法..."
    if $DOCKER_CMD run --rm -v "$(pwd)/html:/var/www/html" php:${PHP_VERSION:-8.3.26}-fpm php -l /var/www/html/wp-config.php 2>/dev/null; then
        print_green "✓ wp-config.php 语法正确"
    else
        print_red "错误: wp-config.php 语法错误，请检查以下内容："
        cat html/wp-config.php | sed 's/define('\''DB_PASSWORD'\'',.*);/define('\''DB_PASSWORD'\'', '\''[HIDDEN]'\'');/'
        print_yellow ".env 文件内容（屏蔽敏感信息）："
        sed 's/\(MYSQL_ROOT_PASSWORD\|MYSQL_PASSWORD\|REDIS_PASSWORD\)=.*/\1=[HIDDEN]/' .env
        exit 1
    fi
    
    print_blue "构建 Docker 镜像..."
    $DOCKER_COMPOSE_CMD build

    if [ -d "mysql" ] && [ "$(ls -A mysql 2>/dev/null)" ]; then
        print_yellow "检测到数据库数据目录已存在，检查容器状态..."
        $DOCKER_COMPOSE_CMD down >/dev/null 2>&1
        if ! $DOCKER_COMPOSE_CMD up -d >/dev/null 2>&1; then
            print_red "数据库容器启动失败，可能是数据目录存在兼容性问题"
            print_yellow "建议清理数据库数据目录并重新初始化"
            read -p "是否清理数据库数据目录？(y/N): " reset_db
            if [ "$reset_db" = "y" ] || [ "$reset_db" = "Y" ]; then
                print_blue "清理数据库数据目录..."
                rm -rf mysql/*
                print_green "数据库数据目录已清理"
            fi
        else
            print_green "数据库容器启动成功，使用现有数据目录"
        fi
    fi

    print_blue "配置文件权限和用户设置..."
    $DOCKER_CMD run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R 33:33 /var/www/html
    $DOCKER_CMD run --rm -v "$(pwd)/logs/mariadb:/var/log/mysql" alpine:latest chown -R 999:999 /var/log/mysql
    $DOCKER_CMD run --rm -v "$(pwd)/mysql:/var/lib/mysql" alpine:latest chown -R 999:999 /var/lib/mysql
    $DOCKER_CMD run --rm -v "$(pwd)/logs/nginx:/var/log/nginx" alpine:latest chown -R 33:33 /var/log/nginx
    
    set -a
    if [ -f ".env" ]; then
        grep -E '^[A-Z_][A-Z0-9_]*=' .env | while IFS= read -r line; do
            if [[ "$line" == *"="* ]]; then
                key=$(echo "$line" | cut -d'=' -f1)
                value=$(echo "$line" | cut -d'=' -f2-)
                export "$key=$value"
            fi
        done
        print_green "✓ 成功加载 .env 文件变量"
        print_yellow "加载的 .env 变量："
        grep -E '^[A-Z_][A-Z0-9_]*=' .env | sed 's/\(MYSQL_ROOT_PASSWORD\|MYSQL_PASSWORD\|REDIS_PASSWORD\)=.*/\1=[HIDDEN]/' || true
    else
        print_red "错误: .env 文件不存在!"
        exit 1
    fi
    set +a
    
    print_blue "启动 Docker 容器..."
    if ! $DOCKER_COMPOSE_CMD up -d; then
        print_red "容器启动失败，检查日志..."
        print_yellow "Nginx 日志："
        $DOCKER_CMD logs nginx
        print_yellow "PHP 日志："
        $DOCKER_CMD logs php
        print_yellow "MariaDB 日志："
        $DOCKER_CMD logs mariadb
        print_yellow "Redis 日志："
        $DOCKER_CMD logs redis
        print_yellow "Nginx 容器状态："
        $DOCKER_CMD inspect nginx | grep -E '"Status"|"Health"'
        print_yellow "检查 Nginx 配置文件："
        $DOCKER_CMD run --rm -v "$(pwd)/configs/nginx/conf.d:/etc/nginx/conf.d" nginx:${NGINX_VERSION:-1.27.2} nginx -t -c /etc/nginx/nginx.conf
        print_yellow "检查 wp-config.php 内容："
        cat html/wp-config.php | sed 's/define('\''DB_PASSWORD'\'',.*);/define('\''DB_PASSWORD'\'', '\''[HIDDEN]'\'');/'
        exit 1
    fi

    print_blue "等待服务初始化.."
    MAX_RETRIES=15
    RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        print_yellow "等待MariaDB初始化 (尝试 $((RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep 15
        
        if $DOCKER_COMPOSE_CMD ps mariadb | grep -q "Up.*healthy"; then
            print_green "数据库连接成功"
            break
        fi
        
        RETRY_COUNT=$((RETRY_COUNT+1))
    done
    
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        print_red "数据库连接失败，检查 MariaDB 日志..."
        $DOCKER_CMD logs mariadb
        print_yellow "尝试设置MariaDB root密码..."
        $DOCKER_COMPOSE_CMD exec -T mariadb sh -c "mariadb -u root -e \"ALTER USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD:-rootpassword}'; ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD:-rootpassword}'; FLUSH PRIVILEGES;\" 2>/dev/null" || \
        print_yellow "密码设置可能已完成或不需要，请继续..."
    fi

    print_blue "显示容器状态.."
    $DOCKER_COMPOSE_CMD ps

    print_blue "等待10秒后验证服务状态..."
    sleep 10
    
    if [ "$($DOCKER_COMPOSE_CMD ps -q | wc -l)" -ge "3" ] && $DOCKER_COMPOSE_CMD ps | grep -q "Up.*healthy"; then
        print_green "WordPress Docker 栈部署成功"
        print_blue "服务状态摘要："
        $DOCKER_COMPOSE_CMD ps
    else
        print_red "WordPress Docker 栈部署失败，请查看日志"
        print_yellow "保存各服务日志..."
        $DOCKER_COMPOSE_CMD logs --tail=50 mariadb > mariadb.log 2>&1
        $DOCKER_COMPOSE_CMD logs --tail=50 nginx > nginx.log 2>&1
        $DOCKER_COMPOSE_CMD logs --tail=50 php > php.log 2>&1
        $DOCKER_COMPOSE_CMD logs --tail=50 redis > redis.log 2>&1
        print_yellow "日志已保存到相应的.log文件中，请检查"
        print_yellow "Nginx 容器状态："
        $DOCKER_CMD inspect nginx | grep -E '"Status"|"Health"'
        print_yellow "检查 Nginx 配置文件："
        $DOCKER_CMD run --rm -v "$(pwd)/configs/nginx/conf.d:/etc/nginx/conf.d" nginx:${NGINX_VERSION:-1.27.2} nginx -t -c /etc/nginx/nginx.conf
        print_yellow "检查 wp-config.php 内容："
        cat html/wp-config.php | sed 's/define('\''DB_PASSWORD'\'',.*);/define('\''DB_PASSWORD'\'', '\''[HIDDEN]'\'');/'
    fi
}

# 设置自动备份
setup_auto_backup() {
    print_blue "设置自动备份..."
    mkdir -p "$BACKUP_DIR" 2>/dev/null || :
    cat > "$DEPLOY_DIR/scripts/backup.sh" << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/backups"
TIMESTAMP=$(date +%F_%H-%M-%S)
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/wordpress_backup_$TIMESTAMP.tar.gz" -C /opt html mysql
print_green "备份完成: wordpress_backup_$TIMESTAMP.tar.gz"
EOF
    chmod +x "$DEPLOY_DIR/scripts/backup.sh"
    print_green "自动备份脚本已生成: $DEPLOY_DIR/scripts/backup.sh"
}

# 设置磁盘空间管理
setup_disk_space_management() {
    print_blue "设置磁盘空间管理..."
    cat > "$DEPLOY_DIR/scripts/cleanup.sh" << 'EOF'
#!/bin/bash
find /opt/backups -type f -name "*.tar.gz" -mtime +7 -delete
print_green "清理7天前的备份文件完成"
EOF
    chmod +x "$DEPLOY_DIR/scripts/cleanup.sh"
    print_green "磁盘空间管理脚本已生成: $DEPLOY_DIR/scripts/cleanup.sh"
}

# 显示部署信息
display_deployment_info() {
    print_blue "显示部署信息..."
    print_green "WordPress 站点: http://localhost"
    print_green "部署目录: $DEPLOY_DIR"
    print_green "备份目录: $BACKUP_DIR"
    print_yellow "请确保防火墙允许 80 和 443 端口"
}

# 主函数
main() {
    for func in prepare_host_environment detect_host_environment collect_system_parameters determine_deployment_directory optimize_parameters deploy_wordpress_stack setup_auto_backup setup_disk_space_management display_deployment_info; do
        if ! type -t "$func" >/dev/null; then
            print_red "错误: 函数 $func 未定义"
            exit 1
        fi
    done
    
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
    
    print_green "WordPress Docker 自动部署完成"
}

# 执行主函数
main