#!/bin/bash
# ==================================================
# auto_deploy_production.sh
# WordPress Docker 全栈最终正式版部署脚本（v2025.10.30）
# - Base64 存储 WordPress 密钥（.env）
# - 自动生成 .env.decoded（供 Docker Compose 使用）
# - 自动生成 docker-compose.yml（无重复 depends_on）
# - 自动清理 /.env 防止 Docker Compose 误读
# - 一键启动完整 WordPress 栈（Nginx+PHP-FPM+MariaDB+Redis）
# ==================================================

set -eu pipefail

# ===== 输出函数 =====
print_blue()   { echo -e "\033[34m$1\033[0m" >&2; }
print_green()  { echo -e "\033[32m$1\033[0m" >&2; }
print_yellow() { echo -e "\033[33m$1\033[0m" >&2; }
print_red()    { echo -e "\033[31m$1\033[0m" >&2; }

# ===== 目录设置 =====
# 自动检测操作系统，适配Windows和Linux环境
# 使用更可靠的方法检测Windows环境
if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "win32"* ]] || [[ "$(uname -a)" == *"CYGWIN"* ]] || [[ "$(uname -a)" == *"MINGW"* ]]; then
    # Windows环境
    DEPLOY_DIR="$(pwd)"
    print_green "Windows环境检测成功，使用当前目录: ${DEPLOY_DIR}"
else
    # Linux环境
    DEPLOY_DIR="/opt"
    print_green "Linux环境检测成功，使用目录: ${DEPLOY_DIR}"
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
    # 兼容Windows和Linux的密码生成
    if command -v openssl &> /dev/null; then
        openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c "$length"
    else
        # 备用方法
        echo "$RANDOM$RANDOM$RANDOM$RANDOM$RANDOM$RANDOM" | tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c "$length"
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
    print_blue "[步骤1] 生成 ${ENV_FILE}（Base64 安全格式）..."
    mkdir -p "$DEPLOY_DIR"
    cd "$DEPLOY_DIR" || exit 1

    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    AVAILABLE_RAM=$(free -m | awk '/^Mem:/{print $7}' || echo 1024)
    MEMORY_PER_SERVICE=$((AVAILABLE_RAM * 2 / 7))
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
    print_blue "[步骤2] 生成 ${ENV_DECODED}（解码后供 Docker Compose 使用）..."
    
    # 清空目标文件
    > "${ENV_DECODED}" || true
    
    # 首先添加MIRROR_PREFIX变量，确保Docker Compose能读取到
    echo "MIRROR_PREFIX=${MIRROR_PREFIX}" >> "${ENV_DECODED}"
    
    # 逐行处理原始env文件
    while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # 跳过MIRROR_PREFIX行，避免重复
        [[ "$line" =~ ^MIRROR_PREFIX= ]] && continue
        
            # 注意：不再处理WordPress密钥，它们将直接在docker-compose.yml中生成
        # 直接复制其他所有环境变量（包括WORDPRESS_DB_HOST等）
        echo "$line" >> "${ENV_DECODED}"
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
    print_green "✅ 已生成 ${ENV_DECODED}"
}

# ===== 下载 WordPress =====
download_wordpress() {
    print_blue "[步骤3.1] 下载并解压 WordPress..."
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
        print_green "✅ WordPress 下载完成"
    else
        print_yellow "⚠️  html 目录不为空，跳过下载"
    fi
}

# ===== 写入 Compose 模板（修正版） =====
generate_compose_file() {
    print_blue "[步骤3] 生成 ${COMPOSE_FILE}..."
    # 使用双引号的here文档，允许shell变量展开
    cat > "${COMPOSE_FILE}" <<YAML
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
    image: ${MIRROR_PREFIX}/wordpress-php:${PHP_VERSION}.26
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
    image: ${MIRROR_PREFIX}/wordpress-nginx:1.27.2
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
    print_green "✅ 已生成 ${COMPOSE_FILE}"
}

# ===== 启动 =====
start_stack() {
    print_blue "[步骤4] 启动 Docker Compose 栈..."
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
    
    # 网络连接重试机制
    local MAX_RETRIES=3
    local RETRY_COUNT=0
    local SLEEP_TIME=5
    local SUCCESS=false
    
    # 预先尝试拉取镜像，提高成功率
    print_yellow "🔄 预先拉取镜像..."
    
    # 定义需要拉取的镜像列表（使用正确的Docker Hub镜像名称和标签）
    local images=(
        "${MIRROR_PREFIX}/wordpress-php:${PHP_VERSION}.26"
        "mariadb:11.3"
        "redis:7.4"
        "${MIRROR_PREFIX}/wordpress-nginx:1.27.2"
    )
    
    # 为每个镜像添加拉取重试机制
    for image in "${images[@]}"; do
        local pull_retries=3
        local pull_success=false
        local pull_sleep=3
        
        for ((i=1; i<=pull_retries; i++)); do
            print_yellow "  拉取镜像 ${image} (尝试 ${i}/${pull_retries})..."
            if docker pull "$image"; then
                pull_success=true
                break
            else
                print_yellow "  镜像拉取失败，${pull_sleep}秒后重试..."
                sleep "$pull_sleep"
                pull_sleep=$((pull_sleep * 2))
            fi
        done
        
        if [ "$pull_success" = true ]; then
            print_green "  ✅ 镜像 ${image} 拉取成功"
        else
            print_yellow "  ⚠️  镜像 ${image} 拉取失败，将在启动时尝试"
        fi
    done
    
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
        print_green "✅ WordPress 栈启动成功"
        
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
    print_blue "[步骤5] 设置自动备份和磁盘监控..."
    mkdir -p "${SCRIPTS_DIR}" "${BACKUP_DIR}"
    
    # 创建备份脚本
    cat > "${SCRIPTS_DIR}/backup.sh" <<'EOF'
#!/bin/bash
BACKUP_DIR="/opt/backups"
TIMESTAMP=$(date +%F_%H-%M-%S)
mkdir -p "$BACKUP_DIR"

# 备份数据库
docker exec wp_db mariadb-dump -u root -p${MYSQL_ROOT_PASSWORD} wordpress > "$BACKUP_DIR/wordpress_db_$TIMESTAMP.sql"

# 备份文件
tar -czf "$BACKUP_DIR/wordpress_files_$TIMESTAMP.tar.gz" -C /opt html

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
    if [[ "$OSTYPE" != "msys"* ]] && [[ "$OSTYPE" != "win32"* ]] && [[ "$(uname -a)" != *"CYGWIN"* ]] && [[ "$(uname -a)" != *"MINGW"* ]]; then
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
            print_yellow "⚠️  未找到crontab命令，无法设置定时任务"
        fi
    else
        print_yellow "⚠️  Windows环境下不设置定时任务"
    fi
    
    print_green "✅ 自动备份和磁盘监控设置完成"
}

display_info() {
    print_blue "📋 部署信息："
    print_green "访问地址: http://<server-ip>"
    print_green "部署目录: ${DEPLOY_DIR}"
    print_green "env文件: ${ENV_FILE}"
    print_green "env解码: ${ENV_DECODED}"
    print_green "compose: ${COMPOSE_FILE}"
    print_green "备份脚本: ${SCRIPTS_DIR}/backup.sh"
}

# ===== 检测并适配操作系统 =====
detect_os_and_optimize() {
    print_blue "[步骤0.5] 检测操作系统并优化配置..."
    
    if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "win32"* ]] || [[ "$(uname -a)" == *"CYGWIN"* ]] || [[ "$(uname -a)" == *"MINGW"* ]]; then
        print_yellow "Windows环境，使用基础配置"
        return
    fi
    
    # Linux环境检测
    if [ -f "/etc/os-release" ]; then
        source /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
        
        print_green "检测到操作系统: $OS_NAME $OS_VERSION"
        
        # 根据不同Linux发行版进行优化
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
                        echo 1 > /proc/sys/vm/overcommit_memory 2>/dev/null || print_yellow "⚠️  无权限设置overcommit_memory，Redis性能可能受限"
                    fi
                fi
                ;;
            alpine)
                print_yellow "Alpine环境，应用apk优化"
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
    
    print_green "✅ 操作系统适配和配置准备完成"
}

# ===== 主程序 =====
main() {
    print_blue "=============================================="
    print_blue "WordPress Docker 全栈部署 - 最终正式版（修正 compose）"
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
    print_green "🎉 部署完成 ✅"
}

main "$@"
