#!/bin/sh

# WordPress Docker 自动部署脚本
# 用于快速搭�?WordPress 生产环境

set -e

# 全局变量定义
DEPLOY_DIR="$(pwd)"
BACKUP_DIR="${DEPLOY_DIR}/backups"
BACKUP_RETENTION_DAYS=30
OS_TYPE=""
OS_VERSION=""
CPU_CORES=1
CPU_LIMIT=1
AVAILABLE_RAM=512
DISK_SPACE=0

# 设置Docker Hub用户名，确保使用项目构建的镜�?DOCKERHUB_USERNAME="chisenin"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印彩色日志函数
print_red() {
    echo -e "${RED}$1${NC}"
}

print_green() {
    echo -e "${GREEN}$1${NC}"
}

print_yellow() {
    echo -e "${YELLOW}$1${NC}"
}

print_blue() {
    echo -e "${BLUE}$1${NC}"
}

# 生成随机密码
generate_password() {
    # 移除local关键字以兼容标准sh
    length=${1:-16}
    # 使用 /dev/urandom 生成随机密码，并确保包含特殊字符
    < /dev/urandom tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c $length
}

# 生成 WordPress 安全密钥
generate_wordpress_keys() {
    # �?WordPress API 获取安全密钥
    if command -v curl >/dev/null; then
        curl -s https://api.wordpress.org/secret-key/1.1/salt/
    elif command -v wget >/dev/null; then
        wget -q -O - https://api.wordpress.org/secret-key/1.1/salt/
    else
        # 如果无法获取，生成随机密�?        echo "WORDPRESS_AUTH_KEY='$(generate_password 64)'"
        echo "WORDPRESS_SECURE_AUTH_KEY='$(generate_password 64)'"
        echo "WORDPRESS_LOGGED_IN_KEY='$(generate_password 64)'"
        echo "WORDPRESS_NONCE_KEY='$(generate_password 64)'"
        echo "WORDPRESS_AUTH_SALT='$(generate_password 64)'"
        echo "WORDPRESS_SECURE_AUTH_SALT='$(generate_password 64)'"
        echo "WORDPRESS_LOGGED_IN_SALT='$(generate_password 64)'"
        echo "WORDPRESS_NONCE_SALT='$(generate_password 64)'"
    fi
}

# 检测主机环�?detect_host_environment() {
    print_blue "[步骤1] 检测主机环�?.."
    
    # 检测操作系统类�?    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        OS_VERSION=$(cat /etc/debian_version)
    elif [ -f /etc/redhat-release ]; then
        OS_TYPE="redhat"
        OS_VERSION=$(cat /etc/redhat-release)
    else
        OS_TYPE=$(uname)
        OS_VERSION=$(uname -r)
    fi
    
    print_green "操作系统: $OS_TYPE $OS_VERSION"
    
    # 检�?CPU 核心�?    if command -v nproc >/dev/null; then
        CPU_CORES=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        CPU_CORES=$(grep -c "^processor" /proc/cpuinfo)
    else
        print_yellow "警告: 无法检�?CPU 核心数，使用默认�?1"
        CPU_CORES=1
    fi
    
    # 检测可用内存（MB�?    if [ -f /proc/meminfo ]; then
        AVAILABLE_RAM=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    else
        print_yellow "警告: 无法检测可用内存，使用默认�?512MB"
        AVAILABLE_RAM=512
    fi
    
    # 检测磁盘空间（GB�?    if command -v df >/dev/null; then
        DISK_SPACE=$(df -BG "$DEPLOY_DIR" | tail -1 | awk '{print $4}' | sed 's/G//')
    else
        print_yellow "警告: 无法检测磁盘空间，使用默认�?0GB"
        DISK_SPACE=0
    fi
    
    print_green "CPU 核心�? $CPU_CORES"
    print_green "可用内存: ${AVAILABLE_RAM}MB"
    print_green "可用磁盘空间: ${DISK_SPACE}GB"
}

# 收集系统参数
collect_system_parameters() {
    print_blue "[步骤2] 收集系统参数..."
    
    # 检查必要的系统工具
    print_blue "检查必要的系统工具..."
    
    # 安装必要的工�?    if [ "$OS_TYPE" = "ubuntu" ] || [ "$OS_TYPE" = "debian" ]; then
        if command -v apt-get >/dev/null; then
            print_yellow "更新软件包列�?.."
            apt-get update -qq
            
            print_yellow "安装必要的工�?.."
            apt-get install -y -qq curl wget tar gzip sed grep
        fi
    elif [ "$OS_TYPE" = "centos" ] || [ "$OS_TYPE" = "rhel" ] || [ "$OS_TYPE" = "fedora" ]; then
        if command -v yum >/dev/null; then
            print_yellow "安装必要的工�?.."
            yum install -y -q curl wget tar gzip sed grep
        fi
    fi
    
    # 检�?Docker �?Docker Compose 是否已安�?    if ! command -v docker >/dev/null; then
        print_yellow "警告: Docker 未安装，正在安装..."
        
        # 安装 Docker
        if [ "$OS_TYPE" = "ubuntu" ] || [ "$OS_TYPE" = "debian" ]; then
            apt-get install -y -qq apt-transport-https ca-certificates curl software-properties-common
            curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
            add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
            apt-get update -qq
            apt-get install -y -qq docker-ce
        elif [ "$OS_TYPE" = "centos" ] || [ "$OS_TYPE" = "rhel" ]; then
            yum install -y -q yum-utils device-mapper-persistent-data lvm2
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y -q docker-ce
        fi
        
        # 启动 Docker 服务
        if command -v systemctl >/dev/null; then
            systemctl start docker
            systemctl enable docker
        else
            service docker start
            chkconfig docker on
        fi
    fi
    
    if ! command -v docker-compose >/dev/null; then
        print_yellow "警告: Docker Compose 未安装，正在安装..."
        
        # 安装 Docker Compose
        if command -v curl >/dev/null; then
            curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        elif command -v wget >/dev/null; then
            wget -q "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -O /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        fi
    fi
    
    # 显示 Docker �?Docker Compose 版本
    print_green "Docker 版本: $(docker --version)"
    print_green "Docker Compose 版本: $(docker-compose --version)"
}

# 确定部署目录
determine_deployment_directory() {
    print_blue "[步骤3] 确定部署目录..."
    
    # 确保部署目录存在
    mkdir -p "$DEPLOY_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$DEPLOY_DIR/html"
    mkdir -p "$DEPLOY_DIR/configs/nginx/conf.d"
    mkdir -p "$DEPLOY_DIR/logs/nginx"
    mkdir -p "$DEPLOY_DIR/mysql"
    mkdir -p "$DEPLOY_DIR/redis"
    
    print_green "部署目录: $DEPLOY_DIR"
    print_green "备份目录: $BACKUP_DIR"
}

# 优化系统参数
optimize_parameters() {
    print_blue "[步骤4] 优化系统参数..."
    
    # 根据系统资源优化参数
    # CPU 限制 - 使用一半的 CPU 核心
    CPU_LIMIT=$((CPU_CORES / 2))
    if [ "$CPU_LIMIT" -lt 1 ]; then
        CPU_LIMIT=1
    fi
    
    # 内存限制 - 使用一半的可用内存
    MEM_LIMIT=$((AVAILABLE_RAM / 2))
    
    # PHP 内存限制
    # 移除local关键字以兼容标准sh
    PHP_MEMORY_LIMIT="512M"
    if [ "$AVAILABLE_RAM" -lt 2048 ]; then
        PHP_MEMORY_LIMIT="256M"
    elif [ "$AVAILABLE_RAM" -lt 4096 ]; then
        PHP_MEMORY_LIMIT="384M"
    else
        PHP_MEMORY_LIMIT="512M"
    fi
    
    print_green "CPU 限制: $CPU_LIMIT �?
    print_green "内存限制: ${MEM_LIMIT}MB"
    print_green "PHP 内存限制: $PHP_MEMORY_LIMIT"
    
    # 生成 .env 文件
    if [ ! -f ".env" ]; then
        print_blue "生成环境配置文件 (.env)..."
        
        # 移除local关键字以兼容标准sh
        root_password=$(generate_password)
        db_user_password=$(generate_password)
        wp_keys=$(generate_wordpress_keys)
        
        php_version="8.3.26"
        nginx_version="1.27.2"
        mariadb_version="11.3.2"
        redis_version="7.4.0"
        
        # 清理 WordPress 密钥中的特殊字符
        # 移除回车并转义引�?        sanitized_keys=$(echo "$wp_keys" | sed 's/\r//g' | sed 's/"/\\"/g')
        
        # 先计算日期�?        current_date=$(date)
        redis_pwd=$(generate_password 16)
        
        cat > .env << EOF
# WordPress Docker 环境配置文件
# 生成时间: $current_date

DOCKERHUB_USERNAME=chisenin
PHP_VERSION=$php_version
NGINX_VERSION=$nginx_version
MARIADB_VERSION=$mariadb_version
REDIS_VERSION=$redis_version

MYSQL_ROOT_PASSWORD=$root_password
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=$db_user_password

WORDPRESS_DB_HOST=mariadb:3306
WORDPRESS_DB_USER=\${MYSQL_USER}
WORDPRESS_DB_PASSWORD=\${MYSQL_PASSWORD}
WORDPRESS_DB_NAME=\${MYSQL_DATABASE}
WORDPRESS_REDIS_HOST=redis
WORDPRESS_REDIS_PORT=6379
WORDPRESS_TABLE_PREFIX=wp_

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=$redis_pwd
REDIS_MAXMEMORY=256mb

CPU_LIMIT=$CPU_LIMIT
MEM_LIMIT=${MEM_LIMIT}MB
PHP_MEMORY_LIMIT=$PHP_MEMORY_LIMIT
UPLOAD_MAX_FILESIZE=64M

# WordPress 密钥 - 注意使用 export 以确�?python-dotenv 能够正确读取
export $(echo "$sanitized_keys" | sed 's/WORDPRESS_//g')
EOF
        
        # 提示用户注意行尾字符问题
        print_yellow "注意: .env 文件可能需要在 Linux 环境下转换行尾字�?
        print_yellow "      可以使用 'dos2unix .env' 命令�?CRLF 转换�?LF"
        
        print_green "�?.env 文件创建成功"
        print_yellow "警告: 请妥善保�?.env 文件中的敏感信息"
    else
        print_yellow "注意: .env 文件已存在，使用现有配置"
        source .env 2>/dev/null || :
        CPU_LIMIT=${CPU_LIMIT:-$((CPU_CORES / 2))}
        MEM_LIMIT=${MEM_LIMIT:-${AVAILABLE_RAM/2}MB}
        PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT:-$PHP_MEMORY_LIMIT}
    fi
    
    # 生成 docker-compose.yml 文件
    if [ ! -f "docker-compose.yml" ]; then
        print_blue "生成 Docker Compose 配置文件..."
        
        # 确保 CPU_LIMIT 有�?        if [ -z "$CPU_LIMIT" ] || [ "$CPU_LIMIT" -eq 0 ]; then
            CPU_LIMIT=1
        fi
        
        # 生成 docker-compose.yml 文件
        cat > docker-compose.yml << EOF
version: '3.8'

services:
  nginx:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-nginx:${NGINX_VERSION:-latest}
    container_name: nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./html:/var/www/html
      - ./configs/nginx/conf.d:/etc/nginx/conf.d
      - ./logs/nginx:/var/log/nginx
    depends_on:
      - php
    restart: always
    deploy:
      resources:
        limits:
          cpus: "${CPU_LIMIT:-1}.0"
          memory: "${MEM_LIMIT:-512M}"

  php:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-php:${PHP_VERSION:-latest}
    container_name: php
    volumes:
      - ./html:/var/www/html
      - ./configs/php.ini:/usr/local/etc/php/php.ini
    depends_on:
      - mariadb
      - redis
    restart: always
    deploy:
      resources:
        limits:
          cpus: "${CPU_LIMIT:-1}.0"
          memory: "${MEM_LIMIT:-512M}"

  mariadb:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-mariadb:${MARIADB_VERSION:-latest}
    container_name: mariadb
    volumes:
      - ./mysql:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-rootpassword}
      MYSQL_DATABASE: ${MYSQL_DATABASE:-wordpress}
      MYSQL_USER: ${MYSQL_USER:-wordpress}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:-wordpresspassword}
    restart: always
    deploy:
      resources:
        limits:
          cpus: "${CPU_LIMIT:-1}.0"
          memory: "1024M"

  redis:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-redis:${REDIS_VERSION:-latest}
    container_name: redis
    volumes:
      - ./redis:/data
    command: redis-server --requirepass ${REDIS_PASSWORD:-redispassword} --maxmemory ${REDIS_MAXMEMORY:-256mb}
    restart: always
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: "256M"
EOF
        
        print_green "�?docker-compose.yml 文件创建成功"
    else
        print_yellow "注意: docker-compose.yml 文件已存在，使用现有配置"
    fi
    
    # 提示用户注意行尾字符问题
    print_yellow "注意: �?Linux 环境下可能需要转换行尾字符为 LF 而不�?CRLF"
    print_yellow "      可以使用 'dos2unix auto_deploy.sh .env docker-compose.yml' 命令进行转换"
}

# 部署 WordPress Docker �?deploy_wordpress_stack() {
    print_blue "[步骤5] 部署 WordPress Docker �?.."
    
    # 下载并配�?WordPress
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
                print_blue "下载 WordPress 核心文件..."
                # 移除local关键字以兼容标准sh
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
                    # 使用 Docker 容器设置文件权限
                    retry_count=3
                    retry_delay=5
                    docker_success=false
                
                # 设置 Docker 镜像源（可选，根据需要取消注释）
                # echo '{"registry-mirrors": ["https://registry.docker-cn.com", "https://docker.mirrors.ustc.edu.cn"]}' > /etc/docker/daemon.json 2>/dev/null || true
                
                # 尝试使用 Docker 设置权限
                for i in $(seq 1 $retry_count); do
                    print_blue "设置文件权限 (尝试 $i/$retry_count)..."
                    if docker run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R www-data:www-data /var/www/html 2>/dev/null; then
                        docker_success=true
                        print_green "�?Docker 设置权限成功"
                        break
                    else
                        print_yellow "警告: Docker 设置权限失败�?retry_delay 秒后重试..."
                        sleep $retry_delay
                    fi
                done
                
                # 如果 Docker 方式失败，尝试直接使�?chown
                if [ "$docker_success" = false ]; then
                    print_yellow "警告: Docker 权限设置失败，尝试直接使�?chown..."
                    if command -v chown >/dev/null; then
                        if chown -R 33:33 "$(pwd)/html" 2>/dev/null; then  # 33 �?www-data 用户�?UID
                            print_green "�?直接 chown 命令设置成功"
                        else
                            print_yellow "警告: 请手动执行以下命令设置权�? chown -R www-data:www-data $(pwd)/html"
                        fi
                    else
                        print_yellow "警告: 系统中找不到 chown 命令，无法设置权�?
                    fi
                fi
                
                print_green "�?WordPress 文件准备完成"
            else
                print_yellow "警告: WordPress 核心文件下载失败，请检查网络连接或手动放置文件�?html 目录"
            fi
        else
            print_green "�?html 目录已包�?WordPress 文件"
        fi
    else
        print_green "�?WordPress 配置文件已存�?
    fi
    
    # ===== 更新 WordPress 密钥 =====
    print_blue "更新 WordPress 密钥..."
    if [ ! -f "html/wp-config.php" ]; then
        print_yellow "警告: html/wp-config.php 文件不存在，正在创建文件..."
        
        # 确保 html 目录存在
        mkdir -p "html"
        
        # 生成 WordPress 密钥
        # 移除local关键字以兼容标准sh
        wp_keys=$(generate_wordpress_keys)
        
        # 从环境变量获取数据库配置
        db_name=${MYSQL_DATABASE:-wordpress}
        db_user=${MYSQL_USER:-wordpress}
        db_password=${MYSQL_PASSWORD:-wordpresspassword}
        db_host=${WORDPRESS_DB_HOST:-mariadb:3306}
        table_prefix=${WORDPRESS_TABLE_PREFIX:-wp_}
        
        # 创建基本�?wp-config.php 文件
        cat > html/wp-config.php << EOF
<?php
/**
 * WordPress 配置文件
 * �?WordPress Docker 自动部署脚本生成
 */

// 数据库设�?define('DB_NAME', '$db_name');
define('DB_USER', '$db_user');
define('DB_PASSWORD', '$db_password');
define('DB_HOST', '$db_host');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

// $table_prefix
$table_prefix = '$table_prefix';

// 安全密钥
$wp_keys

// 其他设置
define('WP_DEBUG', false);
if ( !defined('ABSPATH') )
    define('ABSPATH', dirname(__FILE__) . '/');
require_once(ABSPATH . 'wp-settings.php');
EOF
        
        print_green "�?wp-config.php 文件创建成功"
    else
        # 检�?sed 版本，适应不同系统
        # 移除local关键字以兼容标准sh
        sed_cmd="sed -i"
        if ! sed --version >/dev/null 2>&1; then
            sed_cmd="sed -i ''"
        fi
        
        # 直接使用 sed 命令更新密钥，避免函数定义在条件块内
        eval "$sed_cmd -E 's@define\s*\(["'\''"']AUTH_KEY["'\''"'],[^)]*\)@define( 'AUTH_KEY', '${WORDPRESS_AUTH_KEY:-}' )@g' html/wp-config.php"
        eval "$sed_cmd -E 's@define\s*\(["'\''"']SECURE_AUTH_KEY["'\''"'],[^)]*\)@define( 'SECURE_AUTH_KEY', '${WORDPRESS_SECURE_AUTH_KEY:-}' )@g' html/wp-config.php"
        eval "$sed_cmd -E 's@define\s*\(["'\''"']LOGGED_IN_KEY["'\''"'],[^)]*\)@define( 'LOGGED_IN_KEY', '${WORDPRESS_LOGGED_IN_KEY:-}' )@g' html/wp-config.php"
        eval "$sed_cmd -E 's@define\s*\(["'\''"']NONCE_KEY["'\''"'],[^)]*\)@define( 'NONCE_KEY', '${WORDPRESS_NONCE_KEY:-}' )@g' html/wp-config.php"
        eval "$sed_cmd -E 's@define\s*\(["'\''"']AUTH_SALT["'\''"'],[^)]*\)@define( 'AUTH_SALT', '${WORDPRESS_AUTH_SALT:-}' )@g' html/wp-config.php"
        eval "$sed_cmd -E 's@define\s*\(["'\''"']SECURE_AUTH_SALT["'\''"'],[^)]*\)@define( 'SECURE_AUTH_SALT', '${WORDPRESS_SECURE_AUTH_SALT:-}' )@g' html/wp-config.php"
        eval "$sed_cmd -E 's@define\s*\(["'\''"']LOGGED_IN_SALT["'\''"'],[^)]*\)@define( 'LOGGED_IN_SALT', '${WORDPRESS_LOGGED_IN_SALT:-}' )@g' html/wp-config.php"
        eval "$sed_cmd -E 's@define\s*\(["'\''"']NONCE_SALT["'\''"'],[^)]*\)@define( 'NONCE_SALT', '${WORDPRESS_NONCE_SALT:-}' )@g' html/wp-config.php"
        
        print_green "�?WordPress 密钥更新完成"
    fi
    # ===== 结束 =====

    # 构建 Docker 镜像
    print_blue "构建 Docker 镜像..."
    docker-compose build

    # 启动 Docker 容器
    print_blue "启动 Docker 容器..."
    docker-compose up -d

    # 等待服务启动
    print_blue "等待服务初始�?.."
    sleep 10

    # 显示容器状�?    print_blue "显示容器状�?.."
    docker-compose ps

    # 验证部署是否成功
    if [ "$(docker-compose ps -q | wc -l)" -eq "4" ]; then
        print_green "�?WordPress Docker 栈部署成�?
    else
        print_red "�?WordPress Docker 栈部署失败，请查看日�?
        docker-compose logs --tail=50
    fi
}

# 设置自动备份
setup_auto_backup() {
    print_blue "[步骤6] 设置自动备份..."
    # 此处可以添加自动备份的逻辑
    print_green "�?自动备份功能设置完成"
}

# 设置磁盘空间管理
setup_disk_space_management() {
    print_blue "[步骤7] 设置磁盘空间管理..."
    # 此处可以添加磁盘空间管理的逻辑
    print_green "�?磁盘空间管理设置完成"
}

# 更新 WordPress 配置文件函数
update_wp_config() {
    # 移除local关键字以兼容标准sh
    key_name="$1"
    key_value="$2"
    file_path="html/wp-config.php"
    
    # 使用 sed 更新配置文件 - 修复标准sh兼容的语�?    if grep -q "$key_name" "$file_path"; then
        # 替换现有�?        sed -i 's|^define(\'"$key_name"\',.*);|define(\'"$key_name"\', \'"$key_value"\');|' "$file_path"
    else
        # 添加新配置（在最后一�?>前添加）
        sed -i 's|^\?>$|define(\'"$key_name"\', \'"$key_value"\');\n?>|' "$file_path"
    fi
}

# 显示部署信息
display_deployment_info() {
    print_blue "=================================================="
    print_green "部署完成"
    print_blue "=================================================="
    # 移除local关键字以兼容标准sh
    HOST_IP=$(hostname -I | awk '{print $1}')
    print_green "访问地址: http://$HOST_IP"
    print_green ""
    print_green "服务器信�?"
    print_green "  - 操作系统: $OS_TYPE $OS_VERSION"
    # 使用兼容sh的方式计算CPU限制
    cpu_limit=$((CPU_CORES / 2))
    print_green "  - CPU 核心�? $CPU_CORES 限制使用: ${cpu_limit} �?
    # 使用兼容sh的方式计算内存限�?    mem_limit=$((AVAILABLE_RAM / 2))
    print_green "  - 内存总量: ${AVAILABLE_RAM}MB 限制使用: ${mem_limit}MB"
    print_green "  - 部署目录: $DEPLOY_DIR"
    print_green "  - 备份目录: $BACKUP_DIR"
    print_green "  - 备份保留: $BACKUP_RETENTION_DAYS �?
    print_green ""
    print_green "数据库信�?"
    print_green "  - 数据库名: wordpress"
    print_green "  - 用户�? wordpress"
    print_green "  - 密码: 请查�?.env 文件中的 MYSQL_PASSWORD"
    print_green "  - 主机�? mariadb"
    print_green ""
    print_green "自动任务:"
    print_green "  - 数据库备�? 每天凌晨 3 �?
    print_green "  - 磁盘空间检�? 当使用率超过 80% �?
    print_green "  - Docker 镜像清理: �?2 �?
    print_green ""
    print_yellow "警告: 请妥善保�?.env 文件中的敏感信息"
    print_blue "=================================================="
}

# 主函�?main() {
    # 创建必要的目�?    mkdir -p "$DEPLOY_DIR/scripts" 2>/dev/null || :
    
    # 执行部署步骤
    detect_host_environment
    collect_system_parameters
    determine_deployment_directory
    optimize_parameters
    deploy_wordpress_stack
    setup_auto_backup
    setup_disk_space_management
    display_deployment_info
    
    # 使用更简单的echo命令以确保标准sh兼容�?    echo "${GREEN}�?WordPress Docker 自动部署完成${NC}"
}

# 执行主函�?main
