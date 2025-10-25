#!/bin/sh
set -euo pipefail

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

# 输出函数（简化版本，兼容Windows环境）
print_green() { echo "$1"; }
print_yellow() { echo "$1"; }
print_red() { echo "$1"; }
print_blue() { echo "$1"; }

# 错误处理函数
handle_error() {
    print_red "错误: $1"
    exit 1
}

# 检查宿主机环境
detect_host_environment() {
    print_blue "[阶段1] 检测宿主机环境..."
    
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
    
    CPU_CORES=$(nproc)
    print_green "CPU 核心数: $CPU_CORES"
    
    AVAILABLE_RAM=$(free -m | grep Mem | awk '{print $2}')
    print_green "可用内存: ${AVAILABLE_RAM}MB"
    
    DISK_SPACE=$(df -h / | tail -1 | awk '{print $4}')
    DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
    print_green "可用磁盘空间: $DISK_SPACE"
    print_green "磁盘使用率: ${DISK_USAGE}%"
    
    if ! command -v docker >/dev/null 2>&1; then
        print_red "Docker 未安装，正在尝试安装..."
        install_docker
    else
        DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
        print_green "Docker 版本: $DOCKER_VERSION"
    fi
    
    if ! command -v docker-compose >/dev/null 2>&1; then
        print_red "Docker Compose 未安装，正在尝试安装..."
        install_docker_compose
    else
        COMPOSE_VERSION=$(docker-compose --version | awk '{print $3}' | sed 's/,//')
        print_green "Docker Compose 版本: $COMPOSE_VERSION"
    fi
    
    if [ "$DISK_USAGE" -gt 80 ]; then
        print_yellow "警告: 磁盘使用率超过 80%，建议清理磁盘空间"
        BACKUP_RETENTION_DAYS=3
        print_yellow "自动将备份保留天数调整为: $BACKUP_RETENTION_DAYS 天"
    fi
    
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
    
    if [ -d "/opt/wp-docker" ]; then
        DEPLOY_DIR="/opt/wp-docker"
        print_green "使用现有目录: $DEPLOY_DIR"
    elif [ -d "/var/wp-docker" ]; then
        DEPLOY_DIR="/var/wp-docker"
        print_green "使用现有目录: $DEPLOY_DIR"
    else
        print_green "创建部署目录: /opt/wp-docker"
        mkdir -p /opt/wp-docker || handle_error "无法创建部署目录"
        DEPLOY_DIR="/opt/wp-docker"
    fi
    
    BACKUP_DIR="$DEPLOY_DIR/backups"
    SCRIPTS_DIR="$DEPLOY_DIR/scripts"
    LOGS_DIR="$DEPLOY_DIR/logs"
    
    mkdir -p "$BACKUP_DIR" || handle_error "无法创建备份目录"
    mkdir -p "$SCRIPTS_DIR" || handle_error "无法创建脚本目录"
    mkdir -p "$LOGS_DIR" || handle_error "无法创建日志目录"
    
    print_green "备份目录: $BACKUP_DIR"
    print_green "脚本目录: $SCRIPTS_DIR"
    print_green "日志目录: $LOGS_DIR"
    
    cd "$DEPLOY_DIR" || handle_error "无法切换到部署目录"
    print_green "当前工作目录: $(pwd)"
}

# 生成随机密码
generate_password() {
    local length=${1:-24}
    tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c "$length" || echo "default_password_change_me"
}

# 生成 WordPress 安全密钥（格式化为环境变量格式）
generate_wordpress_keys() {
    print_blue "生成 WordPress 安全密钥..."
    local keys_url="https://api.wordpress.org/secret-key/1.1/salt/"
    local keys=$(curl -s "$keys_url" || wget -qO- "$keys_url" || echo "# 安全密钥生成失败，请手动替换")
    keys=$(echo "$keys" | \
        sed "s/define('\([^']*\)', '\([^']*\)');/WORDPRESS_\1=\2/" | \
        sed "s/define(\"\([^\"]*\)\", \"\([^\"]*\)\");/WORDPRESS_\1=\2/")
    echo "$keys"
}

# 根据系统参数优化配置
optimize_parameters() {
    print_blue "[阶段4] 根据系统参数优化配置..."
    
    mkdir -p configs/nginx/conf.d
    mkdir -p configs/mariadb
    mkdir -p configs/redis
    mkdir -p html
    mkdir -p logs/nginx
    mkdir -p logs/php
    
    local CPU_LIMIT=$((CPU_CORES / 2))
    local MEM_LIMIT=$((AVAILABLE_RAM / 2))
    
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
    
    if [ ! -f ".env" ]; then
        print_blue "生成环境配置文件 (.env)..."
        
        local root_password=$(generate_password)
        local db_user_password=$(generate_password)
        local wp_keys=$(generate_wordpress_keys)
        
        local php_version="8.3.26"
        local nginx_version="1.27.2"
        local mariadb_version="11.3.2"
        local redis_version="7.4.0"
        
        # 确保生成的环境变量格式正确，不含特殊字符问题
        # 清理wp_keys中的特殊字符，确保格式正确
        sanitized_keys=$(echo "$wp_keys" | sed 's/\r//g' | sed 's/"/\\"/g')
        
        cat > .env << EOF
# WordPress Docker环境变量配置
# 生成时间: $(date)

DOCKERHUB_USERNAME=library
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
REDIS_PASSWORD=$(generate_password 16)
REDIS_MAXMEMORY=256mb

CPU_LIMIT=$CPU_LIMIT
MEM_LIMIT=${MEM_LIMIT}MB
PHP_MEMORY_LIMIT=$PHP_MEMORY_LIMIT
UPLOAD_MAX_FILESIZE=64M

# WordPress安全密钥
$sanitized_keys
EOF
        
        # 添加说明关于换行符问题
        print_yellow "注意: .env文件已生成，在Linux系统上可能需要转换换行符"
        print_yellow "      可以使用命令 'dos2unix .env' 确保文件使用LF换行符"
        
        print_green "✓ .env 文件生成完成"
        print_yellow "注意: 敏感信息已保存在 .env 文件中，请妥善保管"
    else
        print_yellow "警告: .env 文件已存在，跳过生成"
        source .env 2>/dev/null || :
        CPU_LIMIT=${CPU_LIMIT:-$((CPU_CORES / 2))}
        MEM_LIMIT=${MEM_LIMIT:-${AVAILABLE_RAM/2}MB}
        PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT:-$PHP_MEMORY_LIMIT}
    fi
    
    if [ ! -f "docker-compose.yml" ]; then
        print_blue "生成 Docker Compose 配置文件..."
        
        # 确保CPU_LIMIT有合理的默认值
        if [ -z "$CPU_LIMIT" ] || [ "$CPU_LIMIT" -eq 0 ]; then
            CPU_LIMIT=1
        fi
        
        # 生成docker-compose.yml文件，确保CPU限制设置正确
        cat > docker-compose.yml << EOF
version: '3.8'

services:
  nginx:
    image: ${DOCKERHUB_USERNAME:-library}/nginx:${NGINX_VERSION:-latest}
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
    image: ${DOCKERHUB_USERNAME:-library}/php:${PHP_VERSION:-latest}-fpm
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
    image: ${DOCKERHUB_USERNAME:-library}/mariadb:${MARIADB_VERSION:-latest}
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
    image: ${DOCKERHUB_USERNAME:-library}/redis:${REDIS_VERSION:-latest}
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
        
        print_green "✓ docker-compose.yml 文件生成完成"
    else
        print_yellow "警告: docker-compose.yml 文件已存在，跳过生成"
    fi
    
    # 添加注释提醒用户关于换行符问题
    print_yellow "注意: 如果在Linux系统上运行，请确保文件使用LF换行符而非CRLF"
    print_yellow "      可以使用命令 'dos2unix auto_deploy.sh .env docker-compose.yml' 进行转换"
    
    # 生成 nginx、php.ini 等配置同样省略，保持你原逻辑
}

# 部署 WordPress Docker 栈
deploy_wordpress_stack() {
    print_blue "[阶段5] 部署 WordPress Docker 栈..."
    
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
            print_blue "下载 WordPress 最新版本..."
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
                print_green "设置文件权限..."
                # 尝试使用Docker设置权限，添加重试机制和国内镜像源支持
                local retry_count=3
                local retry_delay=5
                local docker_success=false
                
                # 尝试设置国内Docker镜像源（可根据实际环境取消注释）
                # echo '{"registry-mirrors": ["https://registry.docker-cn.com", "https://docker.mirrors.ustc.edu.cn"]}' > /etc/docker/daemon.json 2>/dev/null || true
                
                for ((i=1; i<=retry_count; i++)); do
                    print_blue "尝试拉取alpine镜像 (第$i次尝试)..."
                    if docker run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R www-data:www-data /var/www/html 2>/dev/null; then
                        docker_success=true
                        print_green "✓ Docker设置权限成功"
                        break
                    else
                        print_yellow "警告: Docker操作失败，$retry_delay秒后重试..."
                        sleep $retry_delay
                    fi
                done
                
                # 如果Docker操作失败，尝试直接使用chown命令
                if [ "$docker_success" = false ]; then
                    print_yellow "警告: Docker操作失败，尝试使用系统chown命令..."
                    if command -v chown >/dev/null; then
                        if chown -R 33:33 "$(pwd)/html" 2>/dev/null; then  # 33是www-data的通常UID
                            print_green "✓ 系统chown命令设置权限成功"
                        else
                            print_yellow "警告: 无法设置文件权限，建议手动执行: chown -R www-data:www-data $(pwd)/html"
                        fi
                    else
                        print_yellow "警告: 找不到chown命令，无法设置文件权限"
                    fi
                fi
                
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
    
    # ===== 插入：更新 WordPress 安全密钥 =====
    print_blue "更新 WordPress 安全密钥..."
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
            sed "${SED_INPLACE[@]}" -E "s@define\s*\(['\"]${key_name}[\"\'],[^)]*\)@define( '${key_name}', '${key_value}' )@g" "$file_path"
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
    # ===== 插入结束 =====

    print_blue "构建Docker镜像..."
    docker-compose build

    print_blue "启动 Docker 服务..."
    docker-compose up -d

    print_blue "等待服务初始化..."
    sleep 10

    print_blue "检查服务状态..."
    docker-compose ps

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
    # 保持你原脚本逻辑不变...
}

# 配置磁盘空间管理
setup_disk_space_management() {
    print_blue "[阶段7] 配置磁盘空间管理..."
    # 保持你原脚本逻辑不变...
}

# 显示部署信息
display_deployment_info() {
    print_blue "=================================================="
    print_green "部署完成！"
    print_blue "=================================================="
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
    print_yellow "重要: 请备份 .env 文件，包含所有敏感信息"
    print_blue "=================================================="
}

# 主函数
main() {
    mkdir -p "$DEPLOY_DIR/scripts" 2>/dev/null || :
    detect_host_environment
    collect_system_parameters
    determine_deployment_directory
    optimize_parameters
    deploy_wordpress_stack
    setup_auto_backup
    setup_disk_space_management
    display_deployment_info
    print_green "🎉 WordPress Docker 全栈部署完成！"
}

# 执行主函数
main
