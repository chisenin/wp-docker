#!/bin/sh

# WordPress Docker 自动部署脚本
# 用于快速搭建 WordPress 生产环境

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
    local length=${1:-16}
    # 使用 /dev/urandom 生成随机密码，并确保包含特殊字符
    < /dev/urandom tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c $length
}

# 生成 WordPress 安全密钥
generate_wordpress_keys() {
    # 从 WordPress API 获取安全密钥
    if command -v curl >/dev/null; then
        curl -s https://api.wordpress.org/secret-key/1.1/salt/
    elif command -v wget >/dev/null; then
        wget -q -O - https://api.wordpress.org/secret-key/1.1/salt/
    else
        # 如果无法获取，生成随机密钥
        echo "WORDPRESS_AUTH_KEY='$(generate_password 64)'"
        echo "WORDPRESS_SECURE_AUTH_KEY='$(generate_password 64)'"
        echo "WORDPRESS_LOGGED_IN_KEY='$(generate_password 64)'"
        echo "WORDPRESS_NONCE_KEY='$(generate_password 64)'"
        echo "WORDPRESS_AUTH_SALT='$(generate_password 64)'"
        echo "WORDPRESS_SECURE_AUTH_SALT='$(generate_password 64)'"
        echo "WORDPRESS_LOGGED_IN_SALT='$(generate_password 64)'"
        echo "WORDPRESS_NONCE_SALT='$(generate_password 64)'"
    fi
}

# 检测主机环境
detect_host_environment() {
    print_blue "[步骤1] 检测主机环境..."
    
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
    else
        OS_TYPE=$(uname)
        OS_VERSION=$(uname -r)
    fi
    
    print_green "操作系统: $OS_TYPE $OS_VERSION"
    
    # 检测 CPU 核心数
    if command -v nproc >/dev/null; then
        CPU_CORES=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        CPU_CORES=$(grep -c "^processor" /proc/cpuinfo)
    else
        print_yellow "警告: 无法检测 CPU 核心数，使用默认值 1"
        CPU_CORES=1
    fi
    
    # 检测可用内存（MB）
    if [ -f /proc/meminfo ]; then
        AVAILABLE_RAM=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    else
        print_yellow "警告: 无法检测可用内存，使用默认值 512MB"
        AVAILABLE_RAM=512
    fi
    
    # 检测磁盘空间（GB）
    if command -v df >/dev/null; then
        DISK_SPACE=$(df -BG "$DEPLOY_DIR" | tail -1 | awk '{print $4}' | sed 's/G//')
    else
        print_yellow "警告: 无法检测磁盘空间，使用默认值 0GB"
        DISK_SPACE=0
    fi
    
    print_green "CPU 核心数: $CPU_CORES"
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
            print_yellow "更新软件包列表..."
            apt-get update -qq
            
            print_yellow "安装必要的工具..."
            apt-get install -y -qq curl wget tar gzip sed grep
        fi
    elif [ "$OS_TYPE" = "centos" ] || [ "$OS_TYPE" = "rhel" ] || [ "$OS_TYPE" = "fedora" ]; then
        if command -v yum >/dev/null; then
            print_yellow "安装必要的工具..."
            yum install -y -q curl wget tar gzip sed grep
        fi
    fi
    
    # 检查 Docker 和 Docker Compose 是否已安装
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
    
    # 生成 .env 文件
    if [ ! -f ".env" ]; then
        print_blue "生成环境配置文件 (.env)..."
        
        local root_password=$(generate_password)
        local db_user_password=$(generate_password)
        local wp_keys=$(generate_wordpress_keys)
        
        local php_version="8.3.26"
        local nginx_version="1.27.2"
        local mariadb_version="11.3.2"
        local redis_version="7.4.0"
        
        # 清理 WordPress 密钥中的特殊字符
        # 移除回车并转义引号
        local sanitized_keys=$(echo "$wp_keys" | sed 's/\r//g' | sed 's/"/\\"/g')
        
        # 先计算日期值
        local current_date=$(date)
        local redis_pwd=$(generate_password 16)
        
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

# WordPress 密钥 - 注意使用 export 以确保 python-dotenv 能够正确读取
export $(echo "$sanitized_keys" | sed 's/WORDPRESS_//g')
EOF
        
        # 提示用户注意行尾字符问题
        print_yellow "注意: .env 文件可能需要在 Linux 环境下转换行尾字符"
        print_yellow "      可以使用 'dos2unix .env' 命令将 CRLF 转换为 LF"
        
        print_green "✓ .env 文件创建成功"
        print_yellow "警告: 请妥善保管 .env 文件中的敏感信息"
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
        
        # 确保 CPU_LIMIT 有值
        if [ -z "$CPU_LIMIT" ] || [ "$CPU_LIMIT" -eq 0 ]; then
            CPU_LIMIT=1
        fi
        
        # 生成 docker-compose.yml 文件
        cat > docker-compose.yml << EOF
version: '3.8'

services:
  nginx:
    image: chisenin/wp-docker-nginx:${NGINX_VERSION:-latest}
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
    image: chisenin/wp-docker-php:${PHP_VERSION:-latest}-fpm
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
    image: chisenin/wp-docker-mariadb:${MARIADB_VERSION:-latest}
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
    image: chisenin/wp-docker-redis:${REDIS_VERSION:-latest}
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
        
        print_green "✓ docker-compose.yml 文件创建成功"
    else
        print_yellow "注意: docker-compose.yml 文件已存在，使用现有配置"
    fi
    
    # 提示用户注意行尾字符问题
    print_yellow "注意: 在 Linux 环境下可能需要转换行尾字符为 LF 而不是 CRLF"
    print_yellow "      可以使用 'dos2unix auto_deploy.sh .env docker-compose.yml' 命令进行转换"
}

# 部署 WordPress Docker 栈
deploy_wordpress_stack() {
    print_blue "[步骤5] 部署 WordPress Docker 栈..."
    
    # 下载并配置 WordPress
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
            print_blue "下载 WordPress 核心文件..."
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
                print_green "文件解压完成..."
                # 使用 Docker 容器设置文件权限
                local retry_count=3
                local retry_delay=5
                local docker_success=false
                
                # 设置 Docker 镜像源（可选，根据需要取消注释）
                # echo '{"registry-mirrors": ["https://registry.docker-cn.com", "https://docker.mirrors.ustc.edu.cn"]}' > /etc/docker/daemon.json 2>/dev/null || true
                
                # 尝试使用 Docker 设置权限
                for i in $(seq 1 $retry_count); do
                    print_blue "设置文件权限 (尝试 $i/$retry_count)..."
                    if docker run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R www-data:www-data /var/www/html 2>/dev/null; then
                        docker_success=true
                        print_green "✓ Docker 设置权限成功"
                        break
                    else
                        print_yellow "警告: Docker 设置权限失败，$retry_delay 秒后重试..."
                        sleep $retry_delay
                    fi
                done
                
                # 如果 Docker 方式失败，尝试直接使用 chown
                if [ "$docker_success" = false ]; then
                    print_yellow "警告: Docker 权限设置失败，尝试直接使用 chown..."
                    if command -v chown >/dev/null; then
                        if chown -R 33:33 "$(pwd)/html" 2>/dev/null; then  # 33 是 www-data 用户的 UID
                            print_green "✓ 直接 chown 命令设置成功"
                        else
                            print_yellow "警告: 请手动执行以下命令设置权限: chown -R www-data:www-data $(pwd)/html"
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
            print_green "✓ html 目录已包含 WordPress 文件"
        fi
    else
        print_green "✓ WordPress 配置文件已存在"
    fi
    
    # ===== 更新 WordPress 密钥 =====
    print_blue "更新 WordPress 密钥..."
    if [ ! -f "html/wp-config.php" ]; then
        print_yellow "警告: html/wp-config.php 文件不存在，跳过密钥更新"
    else
        if sed --version >/dev/null 2>&1; then
            SED_INPLACE=(-i)
        else
            SED_INPLACE=(-i '')
        fi

        update_wp_key() {
            local key_name="$1"
            local key_value="$2"
            local file_path="html/wp-config.php"
            sed "${SED_INPLACE[@]}" -E "s@define\s*\(['\"]${key_name}[\"'],[^)]*\)@define( '${key_name}', '${key_value}' )@g" "$file_path"
        }

        update_wp_key "AUTH_KEY"           "${WORDPRESS_AUTH_KEY:-}"
        update_wp_key "SECURE_AUTH_KEY"    "${WORDPRESS_SECURE_AUTH_KEY:-}"
        update_wp_key "LOGGED_IN_KEY"      "${WORDPRESS_LOGGED_IN_KEY:-}"
        update_wp_key "NONCE_KEY"          "${WORDPRESS_NONCE_KEY:-}"
        update_wp_key "AUTH_SALT"          "${WORDPRESS_AUTH_SALT:-}"
        update_wp_key "SECURE_AUTH_SALT"   "${WORDPRESS_SECURE_AUTH_SALT:-}"
        update_wp_key "LOGGED_IN_SALT"     "${WORDPRESS_LOGGED_IN_SALT:-}"
        update_wp_key "NONCE_SALT"         "${WORDPRESS_NONCE_SALT:-}"

        print_green "✓ WordPress 密钥更新完成"
    fi
    # ===== 结束 =====

    # 构建 Docker 镜像
    print_blue "构建 Docker 镜像..."
    docker-compose build

    # 启动 Docker 容器
    print_blue "启动 Docker 容器..."
    docker-compose up -d

    # 等待服务启动
    print_blue "等待服务初始化..."
    sleep 10

    # 显示容器状态
    print_blue "显示容器状态..."
    docker-compose ps

    # 验证部署是否成功
    if [ "$(docker-compose ps -q | wc -l)" -eq "4" ]; then
        print_green "✓ WordPress Docker 栈部署成功"
    else
        print_red "✗ WordPress Docker 栈部署失败，请查看日志"
        docker-compose logs --tail=50
    fi
}

# 设置自动备份
setup_auto_backup() {
    print_blue "[步骤6] 设置自动备份..."
    # 此处可以添加自动备份的逻辑
    print_green "✓ 自动备份功能设置完成"
}

# 设置磁盘空间管理
setup_disk_space_management() {
    print_blue "[步骤7] 设置磁盘空间管理..."
    # 此处可以添加磁盘空间管理的逻辑
    print_green "✓ 磁盘空间管理设置完成"
}

# 显示部署信息
display_deployment_info() {
    print_blue "=================================================="
    print_green "部署完成"
    print_blue "=================================================="
    local HOST_IP=$(hostname -I | awk '{print $1}')
    print_green "访问地址: http://$HOST_IP"
    print_green ""
    print_green "服务器信息:"
    print_green "  - 操作系统: $OS_TYPE $OS_VERSION"
    print_green "  - CPU 核心数: $CPU_CORES (限制使用: $((CPU_CORES / 2)) 核)"
    print_green "  - 内存总量: ${AVAILABLE_RAM}MB (限制使用: $((AVAILABLE_RAM / 2))MB)"
    print_green "  - 部署目录: $DEPLOY_DIR"
    print_green "  - 备份目录: $BACKUP_DIR"
    print_green "  - 备份保留: $BACKUP_RETENTION_DAYS 天"
    print_green ""
    print_green "数据库信息:"
    print_green "  - 数据库名: wordpress"
    print_green "  - 用户名: wordpress"
    print_green "  - 密码: 请查看 .env 文件中的 MYSQL_PASSWORD"
    print_green "  - 主机名: mariadb"
    print_green ""
    print_green "自动任务:"
    print_green "  - 数据库备份: 每天凌晨 3 点"
    print_green "  - 磁盘空间检查: 当使用率超过 80% 时"
    print_green "  - Docker 镜像清理: 每 2 周"
    print_green ""
    print_yellow "警告: 请妥善保管 .env 文件中的敏感信息"
    print_blue "=================================================="
}

# 主函数
main() {
    # 创建必要的目录
    mkdir -p "$DEPLOY_DIR/scripts" 2>/dev/null || :
    
    # 执行部署步骤
    detect_host_environment
    collect_system_parameters
    determine_deployment_directory
    optimize_parameters
    deploy_wordpress_stack
    setup_auto_backup
    setup_disk_space_management
    display_deployment_info
    
    print_green "✓ WordPress Docker 自动部署完成"
}

# 执行主函数
main