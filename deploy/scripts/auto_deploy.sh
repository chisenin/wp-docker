#!/bin/bash

# WordPress Docker 自动部署脚本
# 用于快速搭建WordPress 生产环境

set -e

# ==============================================================================
# 函数：准备宿主机环境
# ==============================================================================
prepare_host_environment() {
    echo "------------------------------------------------"
    echo "检查并准备宿主机环境..."
    echo "------------------------------------------------"
    
    # 动态检测是否在 LXC 容器中
    if grep -q lxc /proc/1/cgroup 2>/dev/null; then
        echo "注意: 当前运行在 LXC 容器中，修改内核参数需要特殊处理..."
        # 检查 LXC 是否支持嵌套 Docker
        if [ -f /etc/pve/lxc/$(hostname).conf ]; then
            if ! grep -q "lxc.apparmor.profile: unconfined" /etc/pve/lxc/$(hostname).conf; then
                echo "⚠️ LXC 配置可能不支持嵌套 Docker，建议添加 'lxc.apparmor.profile: unconfined' 到 LXC 配置"
            fi
        fi
    fi
    
    # 1. 修复 vm.overcommit_memory (使用 /proc/sys)
    echo -n "检查 vm.overcommit_memory 设置... "
    CURRENT_OVERCOMMIT=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo "0")
    
    # 检查 sudo 是否可用
    SUDO_AVAILABLE=true
    if ! command -v sudo > /dev/null 2>&1; then
        SUDO_AVAILABLE=false
    fi
    
    if [ "$CURRENT_OVERCOMMIT" -ne "1" ]; then
        echo "当前值为 $CURRENT_OVERCOMMIT，必须设置为 1。"
        # 尝试通过写入 /proc/sys 来实时修改
        if [ "$SUDO_AVAILABLE" = true ] && echo 1 | sudo tee /proc/sys/vm/overcommit_memory > /dev/null 2>&1; then
            echo "✓ 已通过 /proc/sys 临时设置为 1。"
        else
            # 如果 sudo 不可用或失败，尝试直接写入（需要特权）
            if echo 1 > /proc/sys/vm/overcommit_memory 2>/dev/null; then
                 echo "✓ 已直接写入 /proc/sys 设置为 1。"
            else
                echo "✗ 失败。当前用户无权限修改内核参数。"
                echo "⚠️  CRITICAL: Redis 服务可能会失败。请联系宿主机管理员设置 vm.overcommit_memory=1。"
            fi
        fi
        
        # 尝试永久生效（如果可以访问宿主机文件系统）
        if [ "$SUDO_AVAILABLE" = true ]; then
            echo "尝试写入 /etc/sysctl.conf 永久生效..."
            if ! grep -q "^vm.overcommit_memory" /etc/sysctl.conf 2>/dev/null; then
                if echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf > /dev/null 2>&1; then
                    echo "✓ 已写入 /etc/sysctl.conf。"
                else
                    echo "✗ 无法写入 /etc/sysctl.conf。"
                fi
            else
                echo "✓ /etc/sysctl.conf 中已存在该配置。"
            fi
            # 尝试加载 sysctl 配置
            sudo sysctl -p > /dev/null 2>&1 || echo "⚠️  无法执行 'sudo sysctl -p'。"
        fi
    else
        echo "✓ 正确 (值为 $CURRENT_OVERCOMMIT)。"
    fi
    # 2. 检查 Docker 和 Docker Compose
    echo -n "检查 Docker 服务状态... "
    # 尝试使用 sudo 或直接运行 docker
    if [ "$SUDO_AVAILABLE" = true ] && sudo docker info > /dev/null 2>&1; then
        echo "✓ 正常 (使用 sudo)。"
        DOCKER_CMD="sudo docker"
        DOCKER_COMPOSE_CMD="sudo docker-compose"
    elif docker info > /dev/null 2>&1; then
        echo "✓ 正常 (无需 sudo)。"
        DOCKER_CMD="docker"
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo "✗ 失败。Docker 服务未运行或无权限。请启动 Docker 服务。"
        exit 1
    fi
    
    echo -n "检查 Docker Compose... "
    if ! docker-compose --version > /dev/null 2>&1; then
        echo "✗ 失败。未找到 docker-compose 命令。"
        exit 1
    else
        echo "✓ 正常。"
    fi
    
    echo "宿主机环境检查完成。"
    echo "------------------------------------------------"
}

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

# 设置Docker Hub用户名，确保使用项目构建的镜像
DOCKERHUB_USERNAME="chisenin"

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
    length=${1:-16}
    # 使用 /dev/urandom 生成随机密码，确保包含多种字符
    < /dev/urandom tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' | head -c $length
}

# 生成 WordPress 安全密钥
generate_wordpress_keys() {
    # 从WordPress API 获取安全密钥
    if command -v curl >/dev/null; then
        curl -s https://api.wordpress.org/secret-key/1.1/salt/ | sed "s/define('\(.*\)',\s*'\(.*\)');/\1=\2/"
    elif command -v wget >/dev/null; then
        wget -q -O - https://api.wordpress.org/secret-key/1.1/salt/ | sed "s/define('\(.*\)',\s*'\(.*\)');/\1=\2/"
    else
        # 如果无法获取，生成随机密钥
        echo "AUTH_KEY=$(generate_password 64)"
        echo "SECURE_AUTH_KEY=$(generate_password 64)"
        echo "LOGGED_IN_KEY=$(generate_password 64)"
        echo "NONCE_KEY=$(generate_password 64)"
        echo "AUTH_SALT=$(generate_password 64)"
        echo "SECURE_AUTH_SALT=$(generate_password 64)"
        echo "LOGGED_IN_SALT=$(generate_password 64)"
        echo "NONCE_SALT=$(generate_password 64)"
    fi
}

# 检测主机环境
detect_host_environment() {
    print_blue "[步骤1] 检测主机环境.."
    
    # 检测操作系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        OS_VERSION=$(cat /etc/debian_version)
    elif [ -f /etc/redhat-release ]; then
        OS_TYPE="redhat"
        OS_VERSION=$(cat /etc/redhat-release)
    elif [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"
        OS_VERSION=$(cat /etc/alpine-release)
    else
        OS_TYPE=$(uname)
        OS_VERSION=$(uname -r)
    fi
    
    print_green "操作系统: $OS_TYPE $OS_VERSION"
    
    # 检测CPU核心数
    if command -v nproc >/dev/null; then
        CPU_CORES=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        CPU_CORES=$(grep -c "^processor" /proc/cpuinfo)
    else
        print_yellow "警告: 无法检测CPU核心数，使用默认值1"
        CPU_CORES=1
    fi
    
    # 检测可用内存（MB）
    if [ -f /proc/meminfo ]; then
        AVAILABLE_RAM=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    else
        print_yellow "警告: 无法检测可用内存，使用默认值512MB"
        AVAILABLE_RAM=512
    fi
    
    # 检测磁盘空间（GB）
    if command -v df >/dev/null; then
        DISK_SPACE=$(df -BG "$DEPLOY_DIR" | tail -1 | awk '{print $4}' | sed 's/G//')
    else
        print_yellow "警告: 无法检测磁盘空间，使用默认值0GB"
        DISK_SPACE=0
    fi
    
    print_green "CPU 核心数 $CPU_CORES"
    print_green "可用内存: ${AVAILABLE_RAM}MB"
    print_green "可用磁盘空间: ${DISK_SPACE}GB"
}

# 收集系统参数
collect_system_parameters() {
    print_blue "[步骤2] 收集系统参数..."
    
    # 检查必要的系统工具
    print_blue "检查必要的系统工具..."
    
    # 安装必要的工具
    if [ "$OS_TYPE" = "ubuntu" ] || [ "$OS_TYPE" = "debian" ]; then
        if command -v apt-get >/dev/null; then
            print_yellow "更新软件包列表.."
            apt-get update -qq
            
            print_yellow "安装必要的工具.."
            apt-get install -y -qq curl wget tar gzip sed grep dos2unix
        fi
    elif [ "$OS_TYPE" = "centos" ] || [ "$OS_TYPE" = "rhel" ] || [ "$OS_TYPE" = "fedora" ]; then
        if command -v yum >/dev/null; then
            print_yellow "安装必要的工具.."
            yum install -y -q curl wget tar gzip sed grep
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        if command -v apk >/dev/null; then
            print_yellow "更新软件包列表.."
            apk update -q
            
            print_yellow "安装必要的工具.."
            apk add -q curl wget tar gzip sed grep bash dos2unix
        fi
    fi
    
    # 检查Docker和Docker Compose是否已安装
    if ! command -v docker >/dev/null; then
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
        elif command -v service >/dev/null; then
            service docker start
            if command -v chkconfig >/dev/null; then
                chkconfig docker on
            elif command -v update-rc.d >/dev/null; then
                update-rc.d docker扔
            fi
        elif [ "$OS_TYPE" = "alpine" ]; then
            # Alpine 使用 openrc
            if command -v rc-service >/dev/null; then
                rc-service docker start
                rc-update add docker default
            fi
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
    
    # 显示 Docker 和 Docker Compose 版本
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
    mkdir -p "$DEPLOY_DIR/logs/mariadb"
    mkdir -p "$DEPLOY_DIR/mysql"
    mkdir -p "$DEPLOY_DIR/redis"
    
    # 设置初始权限，预防 MariaDB 日志问题
    docker run --rm -v "$(pwd)/logs/mariadb:/var/log/mysql" alpine:latest chown -R 999:999 /var/log/mysql
    docker run --rm -v "$(pwd)/mysql:/var/lib/mysql" alpine:latest chown -R 999:999 /var/lib/mysql
    
    print_green "部署目录: $DEPLOY_DIR"
    print_green "备份目录: $BACKUP_DIR"
}

# 优化系统参数
optimize_parameters() {
    print_blue "[步骤4] 优化系统参数..."
    
    # 根据系统资源优化参数
    # 内存限制优化
    TOTAL_MIN_MEMORY=768  # Nginx + PHP + MariaDB 最小内存需求
    if [ "$AVAILABLE_RAM" -lt "$TOTAL_MIN_MEMORY" ]; then
        MEMORY_PER_SERVICE=256
        print_yellow "警告: 系统内存不足，将为每个服务分配最小可行内存: ${MEMORY_PER_SERVICE}MB"
    else
        MEMORY_PER_SERVICE=$((AVAILABLE_RAM * 2 / 7))
        print_green "为各服务分配内存: ${MEMORY_PER_SERVICE}MB"
    fi
    
    # CPU 限制
    CPU_LIMIT=$((CPU_CORES / 2))
    if [ "$CPU_LIMIT" -lt 1 ]; then
        CPU_LIMIT=1
    fi
    
    # PHP 内存限制
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
    
    # 生成 .env 文件
    if [ ! -f ".env" ]; then
        print_blue "生成 .env 文件..."
        
        root_password=$(generate_password)
        db_user_password=$(generate_password)
        redis_pwd=$(generate_password 16)
        
        php_version="8.3.26"
        nginx_version="1.27.2"
        mariadb_version="11.3.2"
        redis_version="7.4.0"
        
        # 生成 .env 文件
        cat > .env << EOF
# WordPress Docker 环境配置文件
# 生成时间: $(date)

DOCKERHUB_USERNAME=chisenin
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
        
        # 转换行尾字符
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
    else
        print_yellow "注意: .env 文件已存在，使用现有配置"
        source .env 2>/dev/null || :
        CPU_LIMIT=${CPU_LIMIT:-$((CPU_CORES / 2))}
        MEMORY_PER_SERVICE=${MEMORY_PER_SERVICE:-$((AVAILABLE_RAM / 2))}
        PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT:-256M}
    fi
    
    # 生成 docker-compose.yml 文件
    if [ ! -f "docker-compose.yml" ]; then
        print_blue "生成 Docker Compose 配置文件..."
        
        # 确保 CPU_LIMIT 有效
        if [ -z "$CPU_LIMIT" ] || [ "$CPU_LIMIT" -eq 0 ]; then
            CPU_LIMIT=1
        fi
        
        # 验证PHP配置文件是否存在且为文件类型
        PHP_INI_PATH=${PHP_INI_PATH:-./deploy/configs/php.ini}
        if [ -d "$PHP_INI_PATH" ]; then
            print_yellow "警告: $PHP_INI_PATH 被检测为目录，正在删除..."
            rm -rf "$PHP_INI_PATH"
        fi
        
        if [ ! -f "$PHP_INI_PATH" ]; then
            print_yellow "警告: PHP配置文件 $PHP_INI_PATH 不存在或不是文件"
            mkdir -p "$(dirname "$PHP_INI_PATH")"
            echo "[PHP]" > "$PHP_INI_PATH"
            echo "memory_limit = ${PHP_MEMORY_LIMIT:-512M}" >> "$PHP_INI_PATH"
            echo "upload_max_filesize = ${UPLOAD_MAX_FILESIZE:-64M}" >> "$PHP_INI_PATH"
            print_green "已创建默认的php.ini配置文件"
        fi
        
        # 生成 docker-compose.yml 文件
        cat > docker-compose.yml << EOF
version: '3.8'

services:
  nginx:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-nginx:${NGINX_VERSION:-1.27.2}
    container_name: nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./html:/var/www/html
      - ./configs/nginx/conf.d:/etc/nginx/conf.d
      - ./logs/nginx:/var/log/nginx
    depends_on:
      php:
        condition: service_healthy
      redis:
        condition: service_healthy
      mariadb:
        condition: service_healthy
    restart: unless-stopped
    command: nginx -g 'daemon off;'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
  php:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-php:${PHP_VERSION:-8.3.26}
    container_name: php
    volumes:
      - ./html:/var/www/html
      - ${PHP_INI_PATH:-./deploy/configs/php.ini}:/usr/local/etc/php/php.ini:ro
    restart: unless-stopped
    command: ["php-fpm"]
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f 'php-fpm: master process' > /dev/null"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
  mariadb:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-mariadb:${MARIADB_VERSION:-11.3.2}
    container_name: mariadb
    user: "999:999"
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-rootpassword}
      MYSQL_DATABASE: ${MYSQL_DATABASE:-wordpress}
      MYSQL_USER: ${MYSQL_USER:-wordpress}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:-wordpresspassword}
      MARIADB_ROOT_HOST: "%"
    volumes:
      - ./mysql:/var/lib/mysql
      - ./logs/mariadb:/var/log/mysql
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h localhost --user=\$MYSQL_USER --password=\$MYSQL_PASSWORD || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
  redis:
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-redis:${REDIS_VERSION:-7.4.0}
    container_name: redis
    user: "999:999"
    volumes:
      - ./redis:/data
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD:-redispassword}", "--maxmemory", "${MEMORY_PER_SERVICE:-256}mb", "--maxmemory-policy", "allkeys-lru", "--appendonly", "yes"]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD:-redispassword}", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 60s
EOF
        
        # 转换行尾字符
        if command -v dos2unix >/dev/null 2>&1; then
            dos2unix docker-compose.yml >/dev/null 2>&1 && print_green "✓ 成功将 docker-compose.yml 文件行尾字符转换为 LF"
        elif command -v sed >/dev/null 2>&1; then
            sed -i 's/\r$//' docker-compose.yml >/dev/null 2>&1 && print_green "✓ 成功使用 sed 将 docker-compose.yml 文件行尾字符转换为 LF"
        else
            print_yellow "注意: 无法自动转换行尾字符，请在 Linux 环境下手动执行 'dos2unix docker-compose.yml'"
        fi
        
        print_green "docker-compose.yml 文件创建成功"
    else
        print_yellow "注意: docker-compose.yml 文件已存在，使用现有配置"
        # 转换行尾字符
        if command -v dos2unix >/dev/null 2>&1; then
            dos2unix docker-compose.yml >/dev/null 2>&1 && print_green "✓ 成功转换现有 docker-compose.yml 文件行尾字符"
        elif command -v sed >/dev/null 2>&1; then
            sed -i 's/\r$//' docker-compose.yml >/dev/null 2>&1 && print_green "✓ 成功使用 sed 转换现有 docker-compose.yml 文件行尾字符"
        fi
    fi
}

# 部署 WordPress Docker 栈
deploy_wordpress_stack() {
    print_blue "[步骤5] 部署 WordPress Docker 栈.."
    
    # 下载并配置WordPress
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
                # 设置文件权限
                retry_count=3
                retry_delay=5
                docker_success=false
                
                for i in $(seq 1 $retry_count); do
                    print_blue "设置文件权限 (尝试 $i/$retry_count)..."
                    if docker run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R 33:33 /var/www/html 2>/dev/null; then
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
    
    # 更新 WordPress 密钥
    print_blue "更新 WordPress 密钥..."
    if [ ! -f "html/wp-config.php" ]; then
        print_yellow "警告: html/wp-config.php 文件不存在，正在创建文件..."
        
        mkdir -p "html"
        
        db_name=${MYSQL_DATABASE:-wordpress}
        db_user=${MYSQL_USER:-wordpress}
        db_password=${MYSQL_PASSWORD:-wordpresspassword}
        db_host=${WORDPRESS_DB_HOST:-mariadb:3306}
        table_prefix=${WORDPRESS_TABLE_PREFIX:-wp_}
        
        # 生成 PHP 格式的密钥
        wp_keys=$(generate_wordpress_keys | sed 's/=\(.*\)/, "\1");/')
        
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

\$table_prefix = '$table_prefix';

// 安全密钥
$wp_keys

define('WP_DEBUG', false);
if ( !defined('ABSPATH') )
    define('ABSPATH', dirname(__FILE__) . '/');
require_once(ABSPATH . 'wp-settings.php');
EOF
        
        print_green "wp-config.php 文件创建成功"
    else
        # 更新 wp-config.php 中的密钥
        sed_cmd="sed -i"
        if ! sed --version >/dev/null 2>&1; then
            sed_cmd="sed -i ''"
        fi
        
        for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            if [ -n "${!key}" ]; then
                $sed_cmd "s|define('$key',.*);|define('$key', '${!key}');|g" html/wp-config.php
            fi
        done
        
        print_green "WordPress 密钥更新完成"
    fi
    
    # 构建 Docker 镜像
    print_blue "构建 Docker 镜像..."
    docker-compose build

    # 检查是否需要重置数据库
    if [ -d "mysql" ] && [ "$(ls -A mysql 2>/dev/null)" ]; then
        print_yellow "检测到数据库数据目录已存在，检查容器状态..."
        docker-compose down >/dev/null 2>&1
        if ! docker-compose up -d >/dev/null 2>&1; then
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
    docker run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R 33:33 /var/www/html
    docker run --rm -v "$(pwd)/logs/mariadb:/var/log/mysql" alpine:latest chown -R 999:999 /var/log/mysql
    docker run --rm -v "$(pwd)/mysql:/var/lib/mysql" alpine:latest chown -R 999:999 /var/lib/mysql
    docker run --rm -v "$(pwd)/logs/nginx:/var/log/nginx" alpine:latest chown -R 33:33 /var/log/nginx
    
    # 加载 .env 文件
    set -a
    if [ -f ".env" ]; then
        # 只加载 KEY=VALUE 格式的行
        grep -E '^[A-Z_]+=' .env | grep -v '^\s*#' | while IFS= read -r line; do
            if [[ "$line" == *"="* ]]; then
                key=$(echo "$line" | cut -d'=' -f1)
                value=$(echo "$line" | cut -d'=' -f2-)
                export "$key=$value"
            fi
        done
        print_green "✓ 成功加载 .env 文件变量"
    else
        print_red "错误: .env 文件不存在!"
        exit 1
    fi
    set +a
    
    # 启动 Docker 容器
    print_blue "启动 Docker 容器..."
    docker-compose up -d

    # 等待服务启动
    print_blue "等待服务初始化.."
    MAX_RETRIES=10
    RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        print_yellow "等待MariaDB初始化 (尝试 $((RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep 10
        
        if docker-compose ps mariadb | grep -q "Up.*healthy"; then
            print_green "数据库连接成功"
            break
        fi
        
        RETRY_COUNT=$((RETRY_COUNT+1))
    done
    
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        print_red "数据库连接失败，尝试重置权限..."
        print_yellow "等待MariaDB完全初始化..."
        sleep 20
        
        print_yellow "尝试设置MariaDB root密码..."
        docker-compose exec -T mariadb sh -c "mariadb -u root -e \"ALTER USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD:-rootpassword}'; ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD:-rootpassword}'; FLUSH PRIVILEGES;\" 2>/dev/null" || \
        print_yellow "密码设置可能已完成或不需要，请继续..."
    fi

    # 显示容器状态
    print_blue "显示容器状态.."
    docker-compose ps

    # 验证部署是否成功
    print_blue "等待10秒后验证服务状态..."
    sleep 10
    
    if [ "$(docker-compose ps -q | wc -l)" -ge "3" ] && docker-compose ps | grep -q "Up.*healthy"; then
        print_green "WordPress Docker 栈部署成功"
        print_blue "服务状态摘要："
        docker-compose ps
    else
        print_red "WordPress Docker 栈部署失败，请查看日志"
        print_yellow "保存各服务日志..."
        sh -c "docker-compose logs --tail=50 mariadb > mariadb.log 2>&1"
        sh -c "docker-compose logs --tail=50 nginx > nginx.log 2>&1"
        sh -c "docker-compose logs --tail=50 php > php.log 2>&1"
        sh -c "docker-compose logs --tail=50 redis > redis.log 2>&1"
        print_yellow "日志已保存到相应的.log文件中，请检查"
    fi
}

# 设置自动备份
setup_auto_backup() {
    print_blue "[步骤6] 设置自动备份..."
    CRON_JOB="0 3 * * * docker-compose -f $DEPLOY_DIR/docker-compose.yml exec -T mariadb mariadb-dump -u \$MYSQL_USER -p\$MYSQL_PASSWORD \$MYSQL_DATABASE > $BACKUP_DIR/db_backup_\$(date +\%Y\%m\%d).sql && find $BACKUP_DIR -mtime +$BACKUP_RETENTION_DAYS -delete"
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    print_green "自动备份功能设置完成（每天凌晨3点备份，保留 $BACKUP_RETENTION_DAYS 天）"
}

# 设置磁盘空间管理
setup_disk_space_management() {
    print_blue "[步骤7] 设置磁盘空间管理..."
    CRON_JOB="0 * * * * [ \$(df -P $DEPLOY_DIR | awk 'NR==2 {print int((\$3/\$2)*100)}') -gt 80 ] && $DOCKER_CMD system prune -f"
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    print_green "磁盘空间管理设置完成（使用率 >80% 时自动清理 Docker）"
}

# 更新 WordPress 配置文件函数
update_wp_config() {
    key_name="$1"
    key_value="$2"
    file_path="html/wp-config.php"
    
    if grep -q "$key_name" "$file_path"; then
        sed -i "s|define('$key_name',.*);|define('$key_name', '$key_value');|g" "$file_path"
    else
        sed -i "s|^\?>$|define('$key_name', '$key_value');\n?>|" "$file_path"
    fi
}

# 显示部署信息
display_deployment_info() {
    print_blue "=================================================="
    print_green "部署完成"
    print_blue "=================================================="
    HOST_IP=$(hostname -I | awk '{print $1}')
    print_green "访问地址: http://$HOST_IP"
    print_green ""
    print_green "服务器信息"
    print_green "  - 操作系统: $OS_TYPE $OS_VERSION"
    print_green "  - CPU 核心数: $CPU_CORES 限制使用: $CPU_LIMIT 核"
    print_green "  - 内存总量: ${AVAILABLE_RAM}MB 限制使用: ${MEMORY_PER_SERVICE}MB"
    print_green "  - 部署目录: $DEPLOY_DIR"
    print_green "  - 备份目录: $BACKUP_DIR"
    print_green "  - 备份保留: $BACKUP_RETENTION_DAYS 天"
    print_green ""
    print_green "数据库信息"
    print_green "  - 数据库名: wordpress"
    print_green "  - 用户名: wordpress"
    print_green "  - 密码: 请查看 .env 文件中的 MYSQL_PASSWORD"
    print_green "  - 主机名: mariadb"
    print_green ""
    print_green "自动任务:"
    print_green "  - 数据库备份: 每天凌晨 3 点"
    print_green "  - 磁盘空间检查: 当使用率超过 80% 时"
    print_green "  - Docker 镜像清理: 每小时"
    print_green ""
    print_yellow "警告: 请妥善保管 .env 文件中的敏感信息"
    print_blue "=================================================="
}

# 主函数
main() {
    mkdir -p "$DEPLOY_DIR/scripts" 2>/dev/null || :
    
    prepare_host_environment
    detect_host_environment
    collect_system_parameters
    determine_deployment_directory
    optimize_parameters
    deploy_wordpress_stack
    setup_auto_backup
    setup_disk_space_management
    display_deployment_info
    
    echo "WordPress Docker 自动部署完成"
}

# 执行主函数
main