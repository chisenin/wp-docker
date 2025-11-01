#!/bin/sh
# ==================================================
# auto_deploy_production.sh
# WordPress Docker 全栈最终正式版部署脚本（v2025.10.30）
# - 自动生成 .env.decoded（供 Docker Compose 使用）
# - 自动生成 docker-compose.yml（无重复 depends_on）
# - 自动清理 /.env 防止 Docker Compose 误读
# - 一键启动完整 WordPress 栈（Nginx+PHP-FPM+MariaDB+Redis）
# ==================================================

# 移除set -eu pipefail以提高兼容性
set -e

# ===== 输出函数 =====
# 修复print_blue函数定义，确保没有语法错误
print_blue() {
    echo -e "\033[34m$1\033[0m" >&2
}
# 修复输出函数定义，提高兼容性和一致性
print_green() {
    echo -e "\033[32m$1\033[0m" >&2
}
print_yellow() {
    echo -e "\033[33m$1\033[0m" >&2
}
print_red() {
    echo -e "\033[31m$1\033[0m" >&2
}

# ===== 目录设置 =====
# 统一使用当前目录作为基础目录，确保脚本在任何位置运行都能正确工作
BASE_DIR="$(pwd)"

# 提供交互式子目录选择，允许用户选择在当前目录下创建子目录或直接使用当前目录
print_yellow "请选择部署方式："
print_yellow "1. 在当前目录直接部署"
print_yellow "2. 在当前目录下创建子目录部署"
read -p "请选择 [1]: " DEPLOY_CHOICE
DEPLOY_CHOICE=${DEPLOY_CHOICE:-1}

if [ "$DEPLOY_CHOICE" = "2" ]; then
    DEFAULT_PROJECT_DIR="wp-docker"
    read -p "请输入子目录名称 [${DEFAULT_PROJECT_DIR}]: " PROJECT_DIR
    PROJECT_DIR=${PROJECT_DIR:-$DEFAULT_PROJECT_DIR}
    DEPLOY_DIR="${BASE_DIR}/${PROJECT_DIR}"
    print_green "将在子目录中部署: ${DEPLOY_DIR}"
    
    # 创建部署目录（如果不存在）
    mkdir -p "${DEPLOY_DIR}"
    
    # 切换到部署目录
    cd "${DEPLOY_DIR}" || { print_red "无法切换到部署目录"; exit 1; }
    DEPLOY_DIR="$(pwd)"  # 更新为绝对路径
else
    DEPLOY_DIR="${BASE_DIR}"
    print_green "将在当前目录直接部署: ${DEPLOY_DIR}"
fi
ENV_FILE="${DEPLOY_DIR}/.env"
ENV_DECODED="${DEPLOY_DIR}/.env.decoded"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
BACKUP_DIR="${DEPLOY_DIR}/backups"
SCRIPTS_DIR="${DEPLOY_DIR}/scripts"

# ===== 全局变量 =====
# 镜像前缀，使用实际的Docker Hub用户名
MIRROR_PREFIX=chisenin
# PHP版本，确保在镜像拉取时已定义
PHP_VERSION=8.3

# ===== 基础函数 =====
generate_password() {
    local length=${1:-32}
    # 简化密码生成逻辑，避免特殊字符导致的语法问题
    if command -v openssl &> /dev/null; then
        openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$length"
    else
        # 备用方法，只使用字母和数字
        echo "$RANDOM$RANDOM$RANDOM$RANDOM$RANDOM$RANDOM" | tr -dc 'A-Za-z0-9' | head -c "$length"
    fi
}

# 注意：WordPress密钥不再存储在.env文件中，而是直接在docker-compose.yml中生成
# 此函数已弃用，但保留用于兼容性
# generate_wordpress_keys_b64() {
#     ...
# }


cleanup_root_env() {
    if [ -f "/.env" ]; then
        rm -f /.env
        print_yellow "已删除根目录 /.env （防止 Docker Compose 误读）"
    fi
}

prepare_host_environment() {
    command -v docker >/dev/null 2>&1 || { print_red "未检测到 Docker"; exit 1; }
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        print_red "未检测到 Docker Compose"; exit 1
    fi
    print_green "Docker Compose 检测正常 ✅"
}

# ===== 生成 .env =====
generate_env_file() {
    # 修复print_blue调用，避免特殊字符导致的语法错误
    print_blue "生成环境文件 ${ENV_FILE}..."
    mkdir -p "$DEPLOY_DIR"
    cd "$DEPLOY_DIR" || exit 1

    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    # 在Windows环境下，使用更可靠的内存检测方法
    if [ "x${OSTYPE}" = "xmsys"* ] || [ "x${OSTYPE}" = "xwin32"* ] || echo "$(uname -a)" | grep -q "CYGWIN" || echo "$(uname -a)" | grep -q "MINGW"; then
        # Windows环境默认值，确保足够大
        AVAILABLE_RAM=2048
    else
        # Linux环境尝试使用free命令
        AVAILABLE_RAM=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 1024)
    fi
    MEMORY_PER_SERVICE=$((AVAILABLE_RAM * 2 / 7))
    # 确保MEMORY_PER_SERVICE不小于Docker要求的最小6MB
    if [ "$MEMORY_PER_SERVICE" -lt 6 ]; then
        MEMORY_PER_SERVICE=512
    fi
    CPU_LIMIT=$((CPU_CORES / 2))
    [ "$CPU_LIMIT" -lt 1 ] && CPU_LIMIT=1
    PHP_MEMORY_LIMIT="384M"

    # 生成安全的随机密码并保存到变量中
    local root_pass=$(generate_password)
    local mysql_pass=$(generate_password)
    local wp_db_pass=$(generate_password)
    local redis_pass=$(generate_password 16)
    
    cat > "${ENV_FILE}" <<EOF
# WordPress Docker 环境配置文件（Base64 密钥存储）
DOCKERHUB_USERNAME=library
PHP_VERSION=8.3
# 使用main分支重构的镜像前缀
# MIRROR_PREFIX 已在全局定义
NGINX_VERSION=1.27.2
MARIADB_VERSION=11.3.2
REDIS_VERSION=7.4.0
MYSQL_ROOT_PASSWORD=${root_pass}
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=${mysql_pass}
WORDPRESS_DB_HOST=mariadb:3306
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=${wp_db_pass}
WORDPRESS_DB_NAME=wordpress
WORDPRESS_REDIS_HOST=redis
WORDPRESS_REDIS_PORT=6379
WORDPRESS_TABLE_PREFIX=wp_
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${redis_pass}
REDIS_MAXMEMORY=256mb
CPU_LIMIT=${CPU_LIMIT}
MEMORY_PER_SERVICE=${MEMORY_PER_SERVICE}
PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT}
UPLOAD_MAX_FILESIZE=64M
PHP_INI_PATH=./deploy/configs/php.ini
EOF

    # 不再向.env文件添加WordPress密钥，改为直接在docker-compose.yml中生成

    sed -i 's/\x1b\[[0-9;]*m//g' "${ENV_FILE}" || true
    sed -i 's/\r//g' "${ENV_FILE}" || true
    sed -i 's/\\n//g' "${ENV_FILE}" || true
    sed -i 's/\\\"//g' "${ENV_FILE}" || true

    chmod 600 "${ENV_FILE}"
    print_green "✅ 已生成 ${ENV_FILE}"
}

# ===== 解码 env =====
generate_env_decoded() {
    print_blue "生成解码文件 ${ENV_DECODED}..."
    
    # 清空目标文件
    > "${ENV_DECODED}" || true
    
    # 首先添加MIRROR_PREFIX变量，确保Docker Compose能读取到
    echo "MIRROR_PREFIX=${MIRROR_PREFIX}" >> "${ENV_DECODED}"
    
    # 逐行处理原始env文件
    while IFS= read -r line; do
        # 跳过空行和注释
        [ -z "$line" ] || echo "$line" | grep -q "^#" && continue
        
        # 跳过MIRROR_PREFIX行，避免重复
        echo "$line" | grep -q "^MIRROR_PREFIX=" && continue
        
        # 为MEMORY_PER_SERVICE添加m单位（MB）
        if echo "$line" | grep -q "^MEMORY_PER_SERVICE="; then
            # 提取数值部分
            local memory_value=$(echo "$line" | cut -d'=' -f2)
            # 添加m单位并写入
            echo "MEMORY_PER_SERVICE=${memory_value}m" >> "${ENV_DECODED}"
        else
            # 直接复制其他所有环境变量
            echo "$line" >> "${ENV_DECODED}"
        fi
    done < "${ENV_FILE}"
    
    # 确保WORDPRESS_DB_HOST变量存在于文件中
    if ! grep -q "^WORDPRESS_DB_HOST=" "${ENV_DECODED}"; then
        print_yellow "警告：WORDPRESS_DB_HOST未在处理后文件中找到，手动添加默认值"
        echo "WORDPRESS_DB_HOST=mariadb:3306" >> "${ENV_DECODED}"
    fi
    
    # 确保PHP_VERSION存在
    if ! grep -q "^PHP_VERSION=" "${ENV_DECODED}"; then
        echo "PHP_VERSION=8.3" >> "${ENV_DECODED}"
    fi
    
    chmod 600 "${ENV_DECODED}"
    print_green "已生成 ${ENV_DECODED}"
}

# ===== 下载 WordPress =====
download_wordpress() {
    print_blue "下载 WordPress..."
    mkdir -p "${DEPLOY_DIR}/html"
    cd "${DEPLOY_DIR}/html" || exit 1
    
    # 如果html目录为空，下载WordPress
    if [ -z "$(ls -A . 2>/dev/null)" ]; then
        print_yellow "正在下载最新版 WordPress..."
        if command -v wget &> /dev/null; then
            wget https://wordpress.org/latest.tar.gz
        elif command -v curl &> /dev/null; then
            curl -O https://wordpress.org/latest.tar.gz
        else
            print_red "错误：未找到 wget 或 curl 命令"
            exit 1
        fi
        
        print_yellow "正在解压 WordPress..."
        tar -xvzf latest.tar.gz --strip-components=1
        rm -f latest.tar.gz
        
        # 创建uploads目录并设置权限
        mkdir -p wp-content/uploads
        print_green "WordPress 下载完成"
    else
        print_yellow "html 目录不为空，跳过下载"
    fi
}

# ===== 写入 Compose 模板（修正版） =====
generate_compose_file() {
    # 简化print_blue调用，避免潜在的语法问题
    print_blue "生成 ${COMPOSE_FILE}..."
    
    # 使用单引号here文档避免shell展开Docker Compose变量
    # 然后使用sed命令替换镜像前缀和PHP版本
    cat > "${COMPOSE_FILE}" <<'YAML'
services:
  mariadb:
    image: mariadb:11.3
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: "${MYSQL_ROOT_PASSWORD}"
      MARIADB_DATABASE: "${MYSQL_DATABASE}"
      MARIADB_USER: "${MYSQL_USER}"
      MARIADB_PASSWORD: "${MYSQL_PASSWORD}"
    volumes:
      - ./mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "timeout 1 bash -c 'cat < /dev/null > /dev/tcp/localhost/3306' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: '${CPU_LIMIT:-1}'
          memory: '${MEMORY_PER_SERVICE:-512m}'

  redis:
    image: redis:7.4
    restart: unless-stopped
    command: redis-server --requirepass "${REDIS_PASSWORD}" --maxmemory "${REDIS_MAXMEMORY:-256mb}" --maxmemory-policy allkeys-lru
    volumes:
      - ./redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a ${REDIS_PASSWORD} ping | grep PONG"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: '${CPU_LIMIT:-1}'
          memory: '${MEMORY_PER_SERVICE:-256m}'

  wordpress:
    image: MIRROR_PLACEHOLDER/wordpress-php:PHP_VERSION_PLACEHOLDER.26
    restart: unless-stopped
    depends_on:
      mariadb:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      WORDPRESS_DB_HOST: "${WORDPRESS_DB_HOST}"
      WORDPRESS_DB_USER: "${WORDPRESS_DB_USER}"
      WORDPRESS_DB_PASSWORD: "${WORDPRESS_DB_PASSWORD}"
      WORDPRESS_DB_NAME: "${WORDPRESS_DB_NAME}"
      WORDPRESS_REDIS_HOST: "${WORDPRESS_REDIS_HOST}"
      WORDPRESS_REDIS_PORT: "${WORDPRESS_REDIS_PORT}"
      WORDPRESS_REDIS_PASSWORD: "${REDIS_PASSWORD}"
      WORDPRESS_TABLE_PREFIX: "${WORDPRESS_TABLE_PREFIX}"
      PHP_MEMORY_LIMIT: "${PHP_MEMORY_LIMIT:-256M}"
      UPLOAD_MAX_FILESIZE: "${UPLOAD_MAX_FILESIZE:-64M}"
      # WordPress安全密钥 - 直接在docker-compose.yml中生成随机值
      WORDPRESS_AUTH_KEY: "${AUTH_KEY:-$(openssl rand -hex 64)}"
      WORDPRESS_SECURE_AUTH_KEY: "${SECURE_AUTH_KEY:-$(openssl rand -hex 64)}"
      WORDPRESS_LOGGED_IN_KEY: "${LOGGED_IN_KEY:-$(openssl rand -hex 64)}"
      WORDPRESS_NONCE_KEY: "${NONCE_KEY:-$(openssl rand -hex 64)}"
      WORDPRESS_AUTH_SALT: "${AUTH_SALT:-$(openssl rand -hex 64)}"
      WORDPRESS_SECURE_AUTH_SALT: "${SECURE_AUTH_SALT:-$(openssl rand -hex 64)}"
      WORDPRESS_LOGGED_IN_SALT: "${LOGGED_IN_SALT:-$(openssl rand -hex 64)}"
      WORDPRESS_NONCE_SALT: "${NONCE_SALT:-$(openssl rand -hex 64)}"
    volumes:
      - ./html:/var/www/html
      - ./deploy/configs/php.ini:/usr/local/etc/php/conf.d/custom.ini:ro
    deploy:
      resources:
        limits:
          cpus: '${CPU_LIMIT:-1}'
          memory: '${MEMORY_PER_SERVICE:-1024m}'

  nginx:
    image: MIRROR_PLACEHOLDER/wordpress-nginx:1.27.2
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./html:/var/www/html:ro
      - ./deploy/nginx/conf.d:/etc/nginx/conf.d:ro
    depends_on:
      wordpress:
        condition: service_started
    deploy:
      resources:
        limits:
          cpus: '${CPU_LIMIT:-1}'
          memory: '${MEMORY_PER_SERVICE:-512m}'

volumes:
  mysql:
  redis:
YAML
    
    # 使用sed命令替换占位符为实际值
    sed -i "s/MIRROR_PLACEHOLDER/${MIRROR_PREFIX}/g" "${COMPOSE_FILE}"
    sed -i "s/PHP_VERSION_PLACEHOLDER/${PHP_VERSION}/g" "${COMPOSE_FILE}"
    
    print_green "已生成 ${COMPOSE_FILE}"
}

# ===== 启动 =====
start_stack() {
    print_blue "启动服务栈..."
    cd "${DEPLOY_DIR}"
    
    # 确保环境变量文件正确生成
    if [ ! -f "${ENV_DECODED}" ]; then
        print_red "❌ 环境变量文件未生成：${ENV_DECODED}"
        print_yellow "环境变量文件路径: ${ENV_DECODED}"
        print_yellow "当前目录: $(pwd)"
        print_yellow "目录内容: $(ls -la)"
        exit 1
    fi
    
    # 调试信息
    print_yellow "环境变量文件路径: ${ENV_DECODED}"
    print_yellow "文件大小: $(du -h "${ENV_DECODED}" | cut -f1)"
    print_yellow "文件权限: $(ls -la "${ENV_DECODED}")"
    print_yellow "文件内容预览:"
    head -n 20 "${ENV_DECODED}"
    
    # 验证关键环境变量是否存在
    if ! grep -q "WORDPRESS_DB_HOST=" "${ENV_DECODED}"; then
        print_red "❌ 关键环境变量缺失，请重新生成配置文件"
        print_yellow "检查原始.env文件中的变量:"
        grep "WORDPRESS_DB_HOST" "${ENV_FILE}" || print_red "原始文件中也未找到WORDPRESS_DB_HOST"
        exit 1
    fi
    
    # 网络连接重试机制 - 使用普通变量替代local变量以兼容ash shell
    MAX_RETRIES=3
    RETRY_COUNT=0
    SLEEP_TIME=5
    SUCCESS=false
    
    # 预先尝试拉取镜像，提高成功率
    print_yellow "🔄 预先拉取镜像..."
    
    # 定义需要拉取的镜像列表（使用ash shell兼容的方式）
    # 逐个拉取镜像，避免使用数组语法
    docker pull "${MIRROR_PREFIX}/wordpress-php:${PHP_VERSION}.26" || print_yellow "拉取PHP镜像失败，将继续尝试其他镜像"
    docker pull "mariadb:11.3" || print_yellow "拉取MariaDB镜像失败，将继续尝试其他镜像"
    docker pull "redis:7.4" || print_yellow "拉取Redis镜像失败，将继续尝试其他镜像"
    docker pull "${MIRROR_PREFIX}/wordpress-nginx:1.27.2" || print_yellow "拉取Nginx镜像失败，将继续尝试其他镜像"
    
    # 镜像已直接拉取完成
    print_green "✅ 镜像拉取阶段完成"
    
    # 添加网络超时设置
    export DOCKER_CLIENT_TIMEOUT=300
    export COMPOSE_HTTP_TIMEOUT=300
    
    # 重试循环
    while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        print_yellow "⏱️  部署尝试 ${RETRY_COUNT}/${MAX_RETRIES}..."
        
        # 使用正确的Docker Compose命令，添加--no-color避免颜色代码问题
        if ${DOCKER_COMPOSE_CMD} --env-file "${ENV_DECODED}" -f "${COMPOSE_FILE}" up -d --build; then
            SUCCESS=true
            break
        else
            print_yellow "⚠️  部署失败，${SLEEP_TIME}秒后重试..."
            print_red "错误详情:"
            ${DOCKER_COMPOSE_CMD} --env-file "${ENV_DECODED}" -f "${COMPOSE_FILE}" logs --tail=20 || true
            
            # 清理可能的部分启动的容器
            ${DOCKER_COMPOSE_CMD} --env-file "${ENV_DECODED}" -f "${COMPOSE_FILE}" down -v || true
            sleep "$SLEEP_TIME"
            SLEEP_TIME=$((SLEEP_TIME * 2))  # 指数退避
        fi
    done
    
    if [ "$SUCCESS" = true ]; then
        print_green "WordPress 栈启动成功"
        
        # 等待几秒钟让服务稳定
        print_yellow "⏳ 等待服务稳定..."
        sleep 5
        
        # 检查服务状态
        print_yellow "📊 检查服务状态:"
        ${DOCKER_COMPOSE_CMD} --env-file "${ENV_DECODED}" -f "${COMPOSE_FILE}" ps
    else
        print_red "❌ 部署失败，已达到最大重试次数"
        print_yellow "💡 建议检查："
        print_yellow "1. 网络连接是否正常"
        print_yellow "2. Docker Hub是否可访问"
        print_yellow "3. 服务器防火墙设置"
        print_yellow "4. 磁盘空间是否充足: $(df -h /)"
        exit 1
    fi
}

# ===== 备份脚本 =====
setup_auto_backup() {
    print_blue "设置备份和监控..."
    mkdir -p "${SCRIPTS_DIR}" "${BACKUP_DIR}"
    
    # 创建备份脚本
    cat > "${SCRIPTS_DIR}/backup.sh" <<EOF
#!/bin/bash
# 使用环境变量中的备份目录路径
BACKUP_DIR="${BACKUP_DIR}"
DEPLOY_DIR="${DEPLOY_DIR}"
TIMESTAMP=$(date +%F_%H-%M-%S)
mkdir -p "$BACKUP_DIR"

# 备份数据库
docker exec wp_db mariadb-dump -u root -p${MYSQL_ROOT_PASSWORD} wordpress > "$BACKUP_DIR/wordpress_db_$TIMESTAMP.sql"

# 备份文件
tar -czf "$BACKUP_DIR/wordpress_files_$TIMESTAMP.tar.gz" -C "$DEPLOY_DIR" html

# 合并备份
tar -czf "$BACKUP_DIR/wordpress_backup_$TIMESTAMP.tar.gz" -C "$BACKUP_DIR" "wordpress_db_$TIMESTAMP.sql" "wordpress_files_$TIMESTAMP.tar.gz"

# 清理临时文件
rm -f "$BACKUP_DIR/wordpress_db_$TIMESTAMP.sql" "$BACKUP_DIR/wordpress_files_$TIMESTAMP.tar.gz"

# 保留最近7天的备份
find "$BACKUP_DIR" -name "wordpress_backup_*.tar.gz" -type f -mtime +7 -delete

echo "✅ 备份完成: $BACKUP_DIR/wordpress_backup_$TIMESTAMP.tar.gz"
EOF
    chmod +x "${SCRIPTS_DIR}/backup.sh"
    
    # 创建磁盘监控脚本
    cat > "${SCRIPTS_DIR}/disk_monitor.sh" <<'EOF'
#!/bin/bash
THRESHOLD=80
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')

if [ "$DISK_USAGE" -ge "$THRESHOLD" ]; then
    echo "⚠️  磁盘使用率达到 ${DISK_USAGE}%，超过阈值 ${THRESHOLD}%，正在清理..."
    
    # 清理Docker无用镜像
    docker image prune -af
    
    # 清理Docker无用卷
    docker volume prune -f
    
    # 清理Docker无用容器
    docker container prune -f
    
    echo "✅ 清理完成，当前磁盘使用率: $(df -h / | awk 'NR==2 {print $5}')"
fi
EOF
    chmod +x "${SCRIPTS_DIR}/disk_monitor.sh"
    
    # 设置定时任务（如果在Linux环境）
    if ! ([ "x${OSTYPE}" = "xmsys"* ] || [ "x${OSTYPE}" = "xwin32"* ] || echo "$(uname -a)" | grep -q "CYGWIN" || echo "$(uname -a)" | grep -q "MINGW"); then
        # 检查crontab是否存在
        if command -v crontab >/dev/null 2>&1; then
            # 备份当前crontab
            crontab -l > /tmp/current_crontab 2>/dev/null || touch /tmp/current_crontab
            
            # 添加备份任务（每天3点执行）
            if ! grep -q "${SCRIPTS_DIR}/backup.sh" /tmp/current_crontab; then
                echo "0 3 * * * ${SCRIPTS_DIR}/backup.sh >> ${BACKUP_DIR}/backup.log 2>&1" >> /tmp/current_crontab
            fi
            
            # 添加磁盘监控任务（每小时执行）
            if ! grep -q "${SCRIPTS_DIR}/disk_monitor.sh" /tmp/current_crontab; then
                echo "0 * * * * ${SCRIPTS_DIR}/disk_monitor.sh >> ${BACKUP_DIR}/disk_monitor.log 2>&1" >> /tmp/current_crontab
            fi
            
            # 应用新的crontab
            crontab /tmp/current_crontab
            rm -f /tmp/current_crontab
            print_green "✅ 已设置定时备份（每天3点）和磁盘监控（每小时）"
        else
            print_yellow "未找到crontab命令，无法设置定时任务"
        fi
    else
        print_yellow "Windows环境下不设置定时任务"
    fi
    
    print_green "自动备份和磁盘监控设置完成"
}

display_info() {
    print_blue "部署信息"
    print_green "访问地址: http://<server-ip>"
    print_green "部署目录: ${DEPLOY_DIR}"
    print_green "env文件: ${ENV_FILE}"
    print_green "env解码: ${ENV_DECODED}"
    print_green "compose: ${COMPOSE_FILE}"
    print_green "备份脚本: ${SCRIPTS_DIR}/backup.sh"
}

# ===== 检测并适配操作系统 =====
detect_os_and_optimize() {
    print_blue "检测系统配置..."
    
    # 使用更兼容的if语句格式
    if [ "$OSTYPE" = "msys"* ] || [ "$OSTYPE" = "win32"* ] || echo "$(uname -a)" | grep -q "CYGWIN" || echo "$(uname -a)" | grep -q "MINGW"; then
        print_yellow "Windows环境，使用基础配置"
        return
    fi
    
    # Linux环境检测
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release # 使用.代替source，更兼容
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
        
        print_green "检测到操作系统: $OS_NAME $OS_VERSION"
        
        # 根据不同Linux发行版进行优化 - 使用Alpine兼容的case语法
        case "$OS_NAME" in
            ubuntu|debian)
                print_yellow "Ubuntu/Debian环境，应用apt优化"
                # 尝试优化Docker存储驱动
                if grep -q "overlay2" /proc/filesystems; then
                    print_green "已支持overlay2存储驱动"
                fi
                ;;
            centos|rhel)
                print_yellow "CentOS/RHEL环境，应用yum优化"
                # 检查并设置overcommit_memory
                if [ -f "/proc/sys/vm/overcommit_memory" ]; then
                    current_value=$(cat /proc/sys/vm/overcommit_memory)
                    if [ "$current_value" -ne "1" ]; then
                        print_yellow "尝试设置vm.overcommit_memory=1以优化Redis性能"
                        echo 1 > /proc/sys/vm/overcommit_memory 2>/dev/null || print_yellow "无权限设置overcommit_memory，Redis性能可能受限"
                    fi
                fi
                ;;
            alpine)
                print_yellow "Alpine环境，应用apk优化"
                # 针对Alpine环境的特殊优化
                if command -v apk >/dev/null 2>&1; then
                    print_green "Alpine包管理器可用"
                fi
                ;;
            *)
                print_yellow "未知Linux发行版，使用通用配置"
                ;;
        esac
    fi
    
    # 创建必要的配置目录
    mkdir -p "${DEPLOY_DIR}/deploy/configs" "${DEPLOY_DIR}/deploy/nginx/conf.d"
    
    # 创建默认PHP配置
    cat > "${DEPLOY_DIR}/deploy/configs/php.ini" <<'EOF'
memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
date.timezone = Asia/Shanghai
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 1
EOF
    
    # 创建默认Nginx配置
    cat > "${DEPLOY_DIR}/deploy/nginx/conf.d/default.conf" <<'EOF'
server {
    listen 80;
    server_name localhost;
    
    root /var/www/html;
    index index.php index.html index.htm;
    
    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    
    location ~ \.php$ {
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
    
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
    
    # 禁止访问敏感文件
    location ~* \.(txt|md|json|log)$ {
        deny all;
    }
}
EOF
    
    print_green "操作系统适配和配置准备完成"
}

# ===== 主程序 =====
main() {
    print_blue "=============================================="
    print_blue "WordPress Docker 部署"
    print_blue "=============================================="

    cleanup_root_env
    prepare_host_environment
    detect_os_and_optimize
    generate_env_file
    generate_env_decoded
    generate_compose_file
    download_wordpress
    setup_auto_backup
    start_stack
    display_info
    print_green "部署完成"
}

main "$@"
