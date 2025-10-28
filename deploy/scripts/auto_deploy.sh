#!/bin/bash
# ==================================================
# auto_deploy_production.sh
# WordPress Docker 全栈最终正式版部署脚本（v2025.10）
# - Base64 存储 WordPress 密钥（.env）
# - 生成解码后用于 Docker Compose 的 .env.decoded
# - 自动写入 docker-compose.yml 模板（Nginx+PHP-FPM+WP+MariaDB+Redis）
# - 自动清理 /.env 避免误读
# - 运行方式: sudo bash auto_deploy_production.sh
# ==================================================

set -euo pipefail

# ====== 输出函数（只用于终端） ======
print_blue()   { echo -e "\033[34m$1\033[0m" >&2; }
print_green()  { echo -e "\033[32m$1\033[0m" >&2; }
print_yellow() { echo -e "\033[33m$1\033[0m" >&2; }
print_red()    { echo -e "\033[31m$1\033[0m" >&2; }

# ====== 配置路径 ======
DEPLOY_DIR="/opt"
ENV_FILE="${DEPLOY_DIR}/.env"                 # 存储 base64 密钥的安全 env
ENV_DECODED="${DEPLOY_DIR}/.env.decoded"     # 解码后供 docker compose 使用
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
BACKUP_DIR="${DEPLOY_DIR}/backups"
SCRIPTS_DIR="${DEPLOY_DIR}/scripts"

# ====== 实用函数 ======
generate_password() {
    local length=${1:-32}
    # 优先使用 /dev/urandom，回退到 openssl
    tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom 2>/dev/null | head -c "$length" 2>/dev/null || \
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c "$length"
}

# 生成 base64 格式的 WordPress keys，每行纯 KEY=BASE64VALUE（无颜色、无提示）
generate_wordpress_keys_b64() {
    local key_names=("WORDPRESS_AUTH_KEY" "WORDPRESS_SECURE_AUTH_KEY" "WORDPRESS_LOGGED_IN_KEY" "WORDPRESS_NONCE_KEY" \
                     "WORDPRESS_AUTH_SALT" "WORDPRESS_SECURE_AUTH_SALT" "WORDPRESS_LOGGED_IN_SALT" "WORDPRESS_NONCE_SALT")
    for key in "${key_names[@]}"; do
        # 输出安全的 Base64 字符串（去掉换行/回车）
        val=$(generate_password 64 | base64 | tr -d '\n' | tr -d '\r')
        printf "%s=%s\n" "${key}" "${val}"
    done
}

# 清理可能存在的根目录 .env（防止 docker compose 误读）
cleanup_root_env() {
    if [ -f "/.env" ]; then
        rm -f /.env
        print_yellow "已删除根目录 /.env （防止 Docker Compose 误读）"
    fi
}

# 检查和准备 host 环境（docker / docker compose）
prepare_host_environment() {
    command -v docker >/dev/null 2>&1 || { print_red "未检测到 docker，请先安装 Docker"; exit 1; }
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        print_red "未检测到 docker compose，请安装或升级 Docker Compose"; exit 1
    fi
    print_green "检测 Docker: $($DOCKER_COMPOSE_CMD version | head -n1 || true)"
}

# 生成 .env（base64 安全格式）
generate_env_file() {
    print_blue "[步骤] 生成 ${ENV_FILE}（Base64 安全格式）..."
    mkdir -p "$DEPLOY_DIR"
    cd "$DEPLOY_DIR" || exit 1

    # 基础键值
    local MEMORY_PER_SERVICE CPU_LIMIT PHP_MEMORY_LIMIT
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    AVAILABLE_RAM=$(free -m | awk '/^Mem:/{print $7}' || echo 1024)
    MEMORY_PER_SERVICE=$((AVAILABLE_RAM * 2 / 7))
    CPU_LIMIT=$((CPU_CORES / 2))
    [ "$CPU_LIMIT" -lt 1 ] && CPU_LIMIT=1
    PHP_MEMORY_LIMIT="384M"

    cat > "${ENV_FILE}" <<EOF
# WordPress Docker 环境配置文件（Base64 密钥存储）
DOCKERHUB_USERNAME=library
PHP_VERSION=8.3.26
NGINX_VERSION=1.27.2
MARIADB_VERSION=11.3.2
REDIS_VERSION=7.4.0
MYSQL_ROOT_PASSWORD=$(generate_password)
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=$(generate_password)
WORDPRESS_DB_HOST=mariadb:3306
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=$(generate_password)
WORDPRESS_DB_NAME=wordpress
WORDPRESS_REDIS_HOST=redis
WORDPRESS_REDIS_PORT=6379
WORDPRESS_TABLE_PREFIX=wp_
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=$(generate_password 16)
REDIS_MAXMEMORY=256mb
CPU_LIMIT=${CPU_LIMIT}
MEMORY_PER_SERVICE=${MEMORY_PER_SERVICE}
PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT}
UPLOAD_MAX_FILESIZE=64M
PHP_INI_PATH=./deploy/configs/php.ini
EOF

    # 将纯粹的 Base64 密钥追加到 .env（确保只写 KEY=VALUE 行）
    generate_wordpress_keys_b64 >> "${ENV_FILE}"

    # 最后再次确保没有控制字符或转义残留（严防污染）
    # sed 替换 ANSI 控制符、回车、\n 字面串、带转义的引号
    sed -i 's/\x1b\[[0-9;]*m//g' "${ENV_FILE}" || true
    sed -i 's/\r//g' "${ENV_FILE}" || true
    sed -i 's/\\n//g' "${ENV_FILE}" || true
    sed -i 's/\\\"//g' "${ENV_FILE}" || true

    chmod 600 "${ENV_FILE}"
    print_green "已写入 ${ENV_FILE}"
}

# 创建 .env.decoded（把 Base64 的 WP 密钥解码写入，以便 docker compose 使用）
generate_env_decoded() {
    print_blue "[步骤] 生成 ${ENV_DECODED}（解码后 env，供 docker compose 使用）..."
    # 先把除 WordPress 密钥以外的行原样拷贝
    grep -E -v '^WORDPRESS_(AUTH|SECURE_AUTH|LOGGED_IN|NONCE|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT)=' "${ENV_FILE}" > "${ENV_DECODED}" || true

    # 逐行解码并写入 decoded 文件（写入同样的变量名，但值为解码后的实际字符串）
    for key in WORDPRESS_AUTH_KEY WORDPRESS_SECURE_AUTH_KEY WORDPRESS_LOGGED_IN_KEY WORDPRESS_NONCE_KEY \
               WORDPRESS_AUTH_SALT WORDPRESS_SECURE_AUTH_SALT WORDPRESS_LOGGED_IN_SALT WORDPRESS_NONCE_SALT; do
        # 从 ENV_FILE 中提取 base64 值（if present）
        b64val=$(grep -E "^${key}=" "${ENV_FILE}" || true | sed -E "s/^${key}=(.*)$/\1/")
        if [ -n "${b64val}" ]; then
            # 若 base64 解码失败则保留原样
            decoded=$(echo "${b64val}" | base64 --decode 2>/dev/null || echo "${b64val}")
            # 确保 decoded 不含换行或回车
            decoded=$(printf "%s" "${decoded}" | tr -d '\r' | tr -d '\n')
            printf "%s=%s\n" "${key}" "${decoded}" >> "${ENV_DECODED}"
        fi
    done

    # 权限
    chmod 600 "${ENV_DECODED}"
    print_green "已写入 ${ENV_DECODED}"
}

# 写入 docker-compose.yml（最小可用模板：nginx->php-fpm->wordpress ; mariadb ; redis）
generate_compose_file() {
    print_blue "[步骤] 写入 ${COMPOSE_FILE}（docker-compose 模板）..."
    cat > "${COMPOSE_FILE}" <<'YAML'
version: "3.9"

services:
  mariadb:
    image: mariadb:${MARIADB_VERSION}
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${MYSQL_ROOT_PASSWORD}"
      MYSQL_DATABASE: "${MYSQL_DATABASE}"
      MYSQL_USER: "${MYSQL_USER}"
      MYSQL_PASSWORD: "${MYSQL_PASSWORD}"
    volumes:
      - ./mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:${REDIS_VERSION}
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}", "--maxmemory", "${REDIS_MAXMEMORY}", "--maxmemory-policy", "allkeys-lru"]
    volumes:
      - ./redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "PING"]
      interval: 10s
      timeout: 5s
      retries: 5

  wordpress:
    image: wordpress:${PHP_VERSION}-php-fpm
    depends_on:
      mariadb:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: unless-stopped
    environment:
      WORDPRESS_DB_HOST: "${WORDPRESS_DB_HOST}"
      WORDPRESS_DB_USER: "${WORDPRESS_DB_USER}"
      WORDPRESS_DB_PASSWORD: "${WORDPRESS_DB_PASSWORD}"
      WORDPRESS_DB_NAME: "${WORDPRESS_DB_NAME}"
      WORDPRESS_REDIS_HOST: "${WORDPRESS_REDIS_HOST}"
      WORDPRESS_REDIS_PORT: "${WORDPRESS_REDIS_PORT}"
      WORDPRESS_TABLE_PREFIX: "${WORDPRESS_TABLE_PREFIX}"
      # WordPress keys (从 .env.decoded 注入)
      WORDPRESS_AUTH_KEY: "${WORDPRESS_AUTH_KEY}"
      WORDPRESS_SECURE_AUTH_KEY: "${WORDPRESS_SECURE_AUTH_KEY}"
      WORDPRESS_LOGGED_IN_KEY: "${WORDPRESS_LOGGED_IN_KEY}"
      WORDPRESS_NONCE_KEY: "${WORDPRESS_NONCE_KEY}"
      WORDPRESS_AUTH_SALT: "${WORDPRESS_AUTH_SALT}"
      WORDPRESS_SECURE_AUTH_SALT: "${WORDPRESS_SECURE_AUTH_SALT}"
      WORDPRESS_LOGGED_IN_SALT: "${WORDPRESS_LOGGED_IN_SALT}"
      WORDPRESS_NONCE_SALT: "${WORDPRESS_NONCE_SALT}"
    volumes:
      - ./html:/var/www/html
      - ./deploy/configs/php.ini:/usr/local/etc/php/conf.d/custom.ini:ro
    depends_on:
      - mariadb
      - redis

  nginx:
    image: nginx:${NGINX_VERSION}
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./html:/var/www/html:ro
      - ./deploy/nginx/conf.d:/etc/nginx/conf.d:ro
    depends_on:
      - wordpress

volumes:
  mysql:
  redis:
YAML

    print_green "已写入 ${COMPOSE_FILE}"
}

# 启动 stack
start_stack() {
    print_blue "[步骤] 启动 Docker Compose 栈（使用 ${ENV_DECODED}）..."
    cd "${DEPLOY_DIR}" || exit 1

    # 使用明确的 env-file 来避免不同目录下的 .env 混淆
    if ! ${DOCKER_COMPOSE_CMD} --env-file "${ENV_DECODED}" -f "${COMPOSE_FILE}" up -d --build; then
        print_red "docker compose 启动失败，打印最后 100 行日志："
        ${DOCKER_COMPOSE_CMD} --env-file "${ENV_DECODED}" -f "${COMPOSE_FILE}" logs --tail=100 || true
        exit 1
    fi
    print_green "Docker Compose 启动成功 ✅"
}

# 生成备份脚本
setup_auto_backup() {
    mkdir -p "${SCRIPTS_DIR}" "${BACKUP_DIR}"
    cat > "${SCRIPTS_DIR}/backup.sh" <<'SH'
#!/bin/bash
BACKUP_DIR="/opt/backups"
TIMESTAMP=$(date +%F_%H-%M-%S)
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/wordpress_backup_$TIMESTAMP.tar.gz" -C /opt html mysql
echo "备份完成: $BACKUP_DIR/wordpress_backup_$TIMESTAMP.tar.gz"
SH
    chmod +x "${SCRIPTS_DIR}/backup.sh"
    print_green "已生成备份脚本：${SCRIPTS_DIR}/backup.sh"
}

# 显示关键信息
display_info() {
    print_blue "部署信息："
    print_green "访问地址: http://<server-ip> (端口 80)"
    print_green "部署目录: ${DEPLOY_DIR}"
    print_green "env (base64) : ${ENV_FILE}"
    print_green "env (decoded): ${ENV_DECODED}"
    print_green "compose file : ${COMPOSE_FILE}"
    print_green "备份脚本   : ${SCRIPTS_DIR}/backup.sh"
}

# ========== 主流程 ==========
main() {
    print_blue "=============================================="
    print_blue "WordPress Docker 全栈部署 - 最终正式版"
    print_blue "=============================================="

    cleanup_root_env
    prepare_host_environment
    generate_env_file
    generate_env_decoded
    generate_compose_file
    setup_auto_backup

    start_stack
    display_info
    print_green "部署完成 ✅"
}

main "$@"
