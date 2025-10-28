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

set -euo pipefail

# ===== 输出函数 =====
print_blue()   { echo -e "\033[34m$1\033[0m" >&2; }
print_green()  { echo -e "\033[32m$1\033[0m" >&2; }
print_yellow() { echo -e "\033[33m$1\033[0m" >&2; }
print_red()    { echo -e "\033[31m$1\033[0m" >&2; }

# ===== 目录设置 =====
DEPLOY_DIR="/opt"
ENV_FILE="${DEPLOY_DIR}/.env"
ENV_DECODED="${DEPLOY_DIR}/.env.decoded"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
BACKUP_DIR="${DEPLOY_DIR}/backups"
SCRIPTS_DIR="${DEPLOY_DIR}/scripts"

# ===== 基础函数 =====
generate_password() {
    local length=${1:-32}
    tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom 2>/dev/null | head -c "$length" 2>/dev/null || \
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c "$length"
}

generate_wordpress_keys_b64() {
    local key_names=("WORDPRESS_AUTH_KEY" "WORDPRESS_SECURE_AUTH_KEY" "WORDPRESS_LOGGED_IN_KEY" "WORDPRESS_NONCE_KEY" \
                     "WORDPRESS_AUTH_SALT" "WORDPRESS_SECURE_AUTH_SALT" "WORDPRESS_LOGGED_IN_SALT" "WORDPRESS_NONCE_SALT")
    for key in "${key_names[@]}"; do
        val=$(generate_password 64 | base64 | tr -d '\n' | tr -d '\r')
        printf "%s=%s\n" "${key}" "${val}"
    done
}

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

    generate_wordpress_keys_b64 >> "${ENV_FILE}"

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
    grep -E -v '^WORDPRESS_' "${ENV_FILE}" > "${ENV_DECODED}" || true
    for key in WORDPRESS_AUTH_KEY WORDPRESS_SECURE_AUTH_KEY WORDPRESS_LOGGED_IN_KEY WORDPRESS_NONCE_KEY \
               WORDPRESS_AUTH_SALT WORDPRESS_SECURE_AUTH_SALT WORDPRESS_LOGGED_IN_SALT WORDPRESS_NONCE_SALT; do
        b64val=$(grep -E "^${key}=" "${ENV_FILE}" | sed -E "s/^${key}=(.*)$/\1/")
        [ -n "$b64val" ] && {
            decoded=$(echo "$b64val" | base64 --decode 2>/dev/null || echo "$b64val")
            decoded=$(printf "%s" "$decoded" | tr -d '\r\n')
            printf "%s=%s\n" "$key" "$decoded" >> "${ENV_DECODED}"
        }
    done
    chmod 600 "${ENV_DECODED}"
    print_green "✅ 已生成 ${ENV_DECODED}"
}

# ===== 写入 Compose 模板（修正版） =====
generate_compose_file() {
    print_blue "[步骤3] 生成 ${COMPOSE_FILE}..."
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
      WORDPRESS_TABLE_PREFIX: "${WORDPRESS_TABLE_PREFIX}"
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

  nginx:
    image: nginx:${NGINX_VERSION}
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./html:/var/www/html:ro
      - ./deploy/nginx/conf.d:/etc/nginx/conf.d:ro
    depends_on:
      wordpress:
        condition: service_started

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
    if ! docker compose --env-file "${ENV_DECODED}" -f "${COMPOSE_FILE}" up -d --build; then
        print_red "❌ 启动失败，打印日志："
        docker compose --env-file "${ENV_DECODED}" -f "${COMPOSE_FILE}" logs --tail=50 || true
        exit 1
    fi
    print_green "✅ WordPress 栈启动成功"
}

# ===== 备份脚本 =====
setup_auto_backup() {
    mkdir -p "${SCRIPTS_DIR}" "${BACKUP_DIR}"
    cat > "${SCRIPTS_DIR}/backup.sh" <<'EOF'
#!/bin/bash
BACKUP_DIR="/opt/backups"
TIMESTAMP=$(date +%F_%H-%M-%S)
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/wordpress_backup_$TIMESTAMP.tar.gz" -C /opt html mysql
echo "✅ 备份完成: $BACKUP_DIR/wordpress_backup_$TIMESTAMP.tar.gz"
EOF
    chmod +x "${SCRIPTS_DIR}/backup.sh"
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

# ===== 主程序 =====
main() {
    print_blue "=============================================="
    print_blue "WordPress Docker 全栈部署 - 最终正式版（修正 compose）"
    print_blue "=============================================="

    cleanup_root_env
    prepare_host_environment
    generate_env_file
    generate_env_decoded
    generate_compose_file
    setup_auto_backup
    start_stack
    display_info
    print_green "🎉 部署完成 ✅"
}

main "$@"
