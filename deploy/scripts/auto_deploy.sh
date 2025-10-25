#!/bin/bash

set -e

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE_CONFIG=${FORCE_CONFIG:-false}

mkdir -p "$DEPLOY_DIR/logs" 2>/dev/null

print_blue() {
    echo -e "\033[34m$1\033[0m"
}

OS_TYPE=""
OS_VERSION=""
CPU_CORES=0
AVAILABLE_RAM=0
AVAILABLE_DISK=0
PHP_MEMORY_LIMIT="512M"
BACKUP_RETENTION_DAYS=7
LOG_FILE="$DEPLOY_DIR/logs/deploy.log"
CPU_LIMIT="2"
MEMORY_LIMIT="2048m"
MARIADB_CPU_LIMIT="0.5"
MARIADB_MEMORY_LIMIT="512m"
NGINX_CPU_LIMIT="1"
NGINX_MEMORY_LIMIT="256m"

handle_error() {
    echo "Error: $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: $1" >> "$LOG_FILE"
    exit 1
}

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
}

load_env_file() {
    if [ -f ".env" ]; then
        log_message "Loading environment variables from .env file..."
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
            if [[ "$line" =~ ^([A-Za-z0-9_]+)\s*=\s*(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                value="${value%\"}"
                value="${value#\"}"
                value="${value%\'}"
                value="${value#\'}"
                export "$key"="$value"
            fi
        done < .env
        CPU_LIMIT="${CPU_LIMIT:-2}"
        MEMORY_LIMIT="${MEMORY_LIMIT:-2048m}"
        MARIADB_CPU_LIMIT="${MARIADB_CPU_LIMIT:-0.5}"
        MARIADB_MEMORY_LIMIT="${MARIADB_MEMORY_LIMIT:-512m}"
        NGINX_CPU_LIMIT="${NGINX_CPU_LIMIT:-1}"
        NGINX_MEMORY_LIMIT="${NGINX_MEMORY_LIMIT:-256m}"
    else
        log_message "Warning: .env file does not exist"
    fi
}

detect_host_environment() {
    log_message "[Stage 1] Detecting host environment..."
    load_env_file
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        OS_VERSION="$(cat /etc/debian_version)"
    elif [ -f /etc/centos-release ]; then
        OS_TYPE="centos"
        OS_VERSION="$(cat /etc/centos-release | sed 's/^.*release //;s/ .*$//')"
    elif [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"
        OS_VERSION="$(cat /etc/alpine-release)"
    else
        handle_error "Unsupported operating system type"
    fi
    log_message "Operating system: $OS_TYPE $OS_VERSION"
}

environment_preparation() {
    log_message "[Stage 2] Preparing environment..."
    log_message "Checking and creating www-data user/group..."
    if ! id -u www-data >/dev/null 2>&1; then
        log_message "Creating www-data user and group..."
        if [[ "$OS_TYPE" == "alpine" ]]; then
            addgroup -g 33 -S www-data || handle_error "Failed to create www-data group"
            adduser -u 33 -D -S -G www-data www-data || handle_error "Failed to create www-data user"
        else
            groupadd -g 33 www-data 2>/dev/null || :
            useradd -u 33 -g www-data -s /sbin/nologin -M www-data 2>/dev/null || :
        fi
        log_message "Success: www-data user/group created"
    fi
}

check_disk_space() {
    log_message "[Stage 3] Checking disk space..."
    AVAILABLE_DISK=$(df -h "$DEPLOY_DIR" | tail -1 | awk '{print $4}' | sed 's/G//')
    if (( $(echo "$AVAILABLE_DISK < 10" | bc -l) )); then
        handle_error "Insufficient disk space: $AVAILABLE_DISK GB (required: 10 GB)"
    fi
    log_message "Available disk space: ${AVAILABLE_DISK}GB"
}

check_memory() {
    log_message "[Stage 4] Checking memory..."
    if [[ "$OS_TYPE" == "alpine" ]]; then
        AVAILABLE_RAM=$(free -m | awk '/Mem:/ {print $2}')
    else
        AVAILABLE_RAM=$(free -m | grep Mem | awk '{print $2}')
    fi
    if [ "$AVAILABLE_RAM" -lt 2048 ]; then
        handle_error "Insufficient memory: ${AVAILABLE_RAM}MB (required: 2048 MB)"
    fi
    log_message "Available memory: ${AVAILABLE_RAM}MB"
}

determine_deploy_directory() {
    log_message "[Stage 5] Determining deployment directory..."
    cd "$DEPLOY_DIR"
    if [ ! -d "html" ]; then
        mkdir -p "html"
        chown -R www-data:www-data "html"
        chmod -R 755 "html"
    fi
    if [ ! -d "configs" ]; then
        mkdir -p "configs"
    fi
    if [ ! -d "backups" ]; then
        mkdir -p "backups/mysql"
        chown -R www-data:www-data "backups"
    fi
    log_message "Deployment directory: $DEPLOY_DIR"
}

generate_passwords() {
    log_message "[Stage 6] Generating random passwords and keys..."
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    fi
    if [ -z "$MYSQL_PASSWORD" ]; then
        MYSQL_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    fi
    if [ -z "$REDIS_PASSWORD" ]; then
        REDIS_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    fi
    if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
        WORDPRESS_DB_PASSWORD="$MYSQL_PASSWORD"
    fi
    export MYSQL_ROOT_PASSWORD MYSQL_PASSWORD REDIS_PASSWORD WORDPRESS_DB_PASSWORD
    log_message "Passwords and keys generated successfully"
}

generate_wordpress_keys() {
    log_message "[Stage 7] Generating WordPress security keys..."
    WORDPRESS_AUTH_KEY=$(openssl rand -base64 32)
    WORDPRESS_SECURE_AUTH_KEY=$(openssl rand -base64 32)
    WORDPRESS_LOGGED_IN_KEY=$(openssl rand -base64 32)
    WORDPRESS_NONCE_KEY=$(openssl rand -base64 32)
    WORDPRESS_AUTH_SALT=$(openssl rand -base64 32)
    WORDPRESS_SECURE_AUTH_SALT=$(openssl rand -base64 32)
    WORDPRESS_LOGGED_IN_SALT=$(openssl rand -base64 32)
    WORDPRESS_NONCE_SALT=$(openssl rand -base64 32)
    export WORDPRESS_AUTH_KEY WORDPRESS_SECURE_AUTH_KEY WORDPRESS_LOGGED_IN_KEY WORDPRESS_NONCE_KEY
    export WORDPRESS_AUTH_SALT WORDPRESS_SECURE_AUTH_SALT WORDPRESS_LOGGED_IN_SALT WORDPRESS_NONCE_SALT
    log_message "WordPress security keys generated successfully"
}

optimize_env_variables() {
    log_message "[Stage 8] Optimizing environment variables..."
    MYSQL_DATABASE="${MYSQL_DATABASE:-wordpress}"
    MYSQL_USER="${MYSQL_USER:-wordpress}"
    WORDPRESS_DB_NAME="${WORDPRESS_DB_NAME:-wordpress}"
    WORDPRESS_DB_USER="${WORDPRESS_DB_USER:-wordpress}"
    WORDPRESS_DB_HOST="${WORDPRESS_DB_HOST:-mariadb}"
    REDIS_HOST="${REDIS_HOST:-redis}"
    PHP_VERSION="${PHP_VERSION:-8.1}"
    MARIADB_VERSION="${MARIADB_VERSION:-10.9}"
    NGINX_VERSION="${NGINX_VERSION:-1.23}"
    REDIS_VERSION="${REDIS_VERSION:-7.0}"
    export MYSQL_DATABASE MYSQL_USER WORDPRESS_DB_NAME WORDPRESS_DB_USER WORDPRESS_DB_HOST REDIS_HOST
    export PHP_VERSION MARIADB_VERSION NGINX_VERSION REDIS_VERSION
    log_message "Environment variables optimized successfully"
}

set_permissions() {
    log_message "Setting permissions..."
    chown -R www-data:www-data "$DEPLOY_DIR/html"
    chmod -R 755 "$DEPLOY_DIR/html"
    chown -R www-data:www-data "$DEPLOY_DIR/backups"
    chmod -R 755 "$DEPLOY_DIR/backups"
    chown -R www-data:www-data "$DEPLOY_DIR/logs"
    chmod -R 755 "$DEPLOY_DIR/logs"
    log_message "Permissions set successfully"
}

cleanup_old_containers() {
    log_message "Cleaning up old containers..."
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        handle_error "docker-compose not found"
    fi
    if [ -f "docker-compose.yml" ]; then
        $DOCKER_COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    log_message "Old containers cleaned up successfully"
}

build_images() {
    log_message "[Stage 10] Building Docker images..."
    if [[ -z "$CPU_LIMIT" || "$CPU_LIMIT" == "" ]]; then
        log_message "Warning: CPU_LIMIT not set or empty, using default value 2"
        CPU_LIMIT="2"
    fi
    if [[ -z "$MEMORY_LIMIT" || "$MEMORY_LIMIT" == "" ]]; then
        log_message "Warning: MEMORY_LIMIT not set or empty, using default value 2048m"
        MEMORY_LIMIT="2048m"
    fi
    if [[ -z "$MARIADB_CPU_LIMIT" || "$MARIADB_CPU_LIMIT" == "" ]]; then
        log_message "Warning: MARIADB_CPU_LIMIT not set or empty, using default value 0.5"
        MARIADB_CPU_LIMIT="0.5"
    fi
    if [[ -z "$MARIADB_MEMORY_LIMIT" || "$MARIADB_MEMORY_LIMIT" == "" ]]; then
        log_message "Warning: MARIADB_MEMORY_LIMIT not set or empty, using default value 512m"
        MARIADB_MEMORY_LIMIT="512m"
    fi
    if [[ -z "$NGINX_CPU_LIMIT" || "$NGINX_CPU_LIMIT" == "" ]]; then
        log_message "Warning: NGINX_CPU_LIMIT not set or empty, using default value 1"
        NGINX_CPU_LIMIT="1"
    fi
    if [[ -z "$NGINX_MEMORY_LIMIT" || "$NGINX_MEMORY_LIMIT" == "" ]]; then
        log_message "Warning: NGINX_MEMORY_LIMIT not set or empty, using default value 256m"
        NGINX_MEMORY_LIMIT="256m"
    fi
    export CPU_LIMIT MEMORY_LIMIT MARIADB_CPU_LIMIT MARIADB_MEMORY_LIMIT NGINX_CPU_LIMIT NGINX_MEMORY_LIMIT
    if [ ! -f "docker-compose.yml" ] || [ "$FORCE_CONFIG" = true ]; then
        log_message "Generating docker-compose.yml file..."
        cat > docker-compose.yml << EOF
version: '3.8'

services:
  mariadb:
    image: mariadb:$MARIADB_VERSION
    container_name: wp_db
    restart: unless-stopped
    networks:
      - wp_network
    volumes:
      - ./backups/mysql:/var/lib/mysql
      - ./configs/mariadb:/etc/mysql/conf.d
    environment:
      - MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
      - MYSQL_DATABASE=$MYSQL_DATABASE
      - MYSQL_USER=$MYSQL_USER
      - MYSQL_PASSWORD=$MYSQL_PASSWORD
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-u", "root", "-p$MYSQL_ROOT_PASSWORD"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "${MARIADB_CPU_LIMIT}"
          memory: "${MARIADB_MEMORY_LIMIT}"

  redis:
    image: redis:$REDIS_VERSION
    container_name: wp_redis
    restart: unless-stopped
    networks:
      - wp_network
    command: redis-server --requirepass $REDIS_PASSWORD
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: "128m"

  php:
    build:
      context: ../build/Dockerfiles/php
      args:
        PHP_VERSION: $PHP_VERSION
    container_name: wp_php
    restart: unless-stopped
    networks:
      - wp_network
    volumes:
      - ./html:/var/www/html
      - ./configs/php.ini:/usr/local/etc/php/conf.d/custom.ini
    environment:
      - MYSQL_HOST=$WORDPRESS_DB_HOST
      - MYSQL_DATABASE=$WORDPRESS_DB_NAME
      - MYSQL_USER=$WORDPRESS_DB_USER
      - MYSQL_PASSWORD=$WORDPRESS_DB_PASSWORD
      - REDIS_HOST=$REDIS_HOST
      - REDIS_PASSWORD=$REDIS_PASSWORD
    healthcheck:
      test: ["CMD", "php-fpm", "-t"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "${CPU_LIMIT}"
          memory: "${MEMORY_LIMIT}"

  nginx:
    build:
      context: ../build/Dockerfiles/nginx
      args:
        NGINX_VERSION: $NGINX_VERSION
    container_name: wp_nginx
    restart: unless-stopped
    networks:
      - wp_network
    volumes:
      - ./html:/var/www/html
      - ./configs/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./configs/conf.d:/etc/nginx/conf.d:ro
      - ./logs/nginx:/var/log/nginx
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      - php
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "${NGINX_CPU_LIMIT}"
          memory: "${NGINX_MEMORY_LIMIT}"

networks:
  wp_network:
    driver: bridge

volumes:
  mysql_data:
  wordpress_data:
EOF
    fi
    if ! $DOCKER_COMPOSE_CMD config >/dev/null 2>&1; then
        handle_error "docker-compose.yml configuration syntax error"
    fi
    log_message "Current resource limits: CPU=$CPU_LIMIT, Memory=$MEMORY_LIMIT, MARIADB_CPU=$MARIADB_CPU_LIMIT, MARIADB_MEMORY=$MARIADB_MEMORY_LIMIT, NGINX_CPU=$NGINX_CPU_LIMIT, NGINX_MEMORY=$NGINX_MEMORY_LIMIT"
    log_message "Building Docker images..."
    $DOCKER_COMPOSE_CMD build || handle_error "Failed to build Docker images"
    log_message "Success: Image building completed"
}

generate_configs() {
    log_message "[Stage 9] Generating configuration files..."
    if [ ! -f "configs/nginx.conf" ] || [ "$FORCE_CONFIG" = true ]; then
        log_message "Generating Nginx configuration files..."
        local worker_processes="auto"
        if [[ "$OS_TYPE" == "alpine" ]]; then
            worker_processes="$(nproc)"
        fi
        mkdir -p "configs/conf.d"
        cat > configs/nginx.conf << EOF
user www-data;
worker_processes $worker_processes;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    
    gzip on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_vary on;
    gzip_types
        text/plain
        text/css
        text/javascript
        application/javascript
        application/json
        application/x-javascript
        application/xml
        application/xml+rss
        application/vnd.ms-fontobject
        font/opentype
        image/svg+xml
        image/x-icon;
    
    include /etc/nginx/conf.d/*.conf;
}
EOF
        cat > configs/conf.d/default.conf << EOF
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.php index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }
    
    location ~ /\.(?!well-known).* {
        deny all;
    }
    
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
}
EOF
        log_message "Nginx configuration files generated successfully"
    fi
    if [ ! -f "configs/php.ini" ] || [ "$FORCE_CONFIG" = true ]; then
        log_message "Generating PHP configuration file..."
        cat > configs/php.ini << EOF
max_execution_time = 300
max_input_time = 600
memory_limit = $PHP_MEMORY_LIMIT
post_max_size = 128M
upload_max_filesize = 128M
max_file_uploads = 20

date.timezone = Asia/Shanghai

expose_php = Off
display_errors = Off
log_errors = On
error_log = /var/log/php/error.log

session.save_handler = files
session.save_path = "/var/lib/php/sessions"
session.gc_probability = 1
session.gc_divisor = 1000
session.gc_maxlifetime = 1440
EOF
        log_message "PHP configuration file generated successfully"
    fi
    if [ ! -d "configs/mariadb" ]; then
        log_message "Creating MariaDB configuration directory..."
        mkdir -p "configs/mariadb"
        cat > configs/mariadb/custom.cnf << EOF
[mysqld]
max_connections = 100
max_allowed_packet = 16M
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-name-resolve
EOF
        log_message "MariaDB configuration created successfully"
    fi
}

start_services() {
    log_message "[Stage 11] Starting services..."
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        handle_error "docker-compose not found"
    fi
    if [ ! -f "html/wp-config.php" ]; then
        log_message "Downloading WordPress..."
        mkdir -p "html"
        curl -s -L https://wordpress.org/latest.tar.gz | tar -xz -C "html" --strip-components=1
        log_message "Configuring WordPress..."
        cp html/wp-config-sample.php html/wp-config.php
        sed -i "s/database_name_here/$WORDPRESS_DB_NAME/" html/wp-config.php
        sed -i "s/username_here/$WORDPRESS_DB_USER/" html/wp-config.php
        sed -i "s/password_here/$WORDPRESS_DB_PASSWORD/" html/wp-config.php
        sed -i "s/localhost/$WORDPRESS_DB_HOST/" html/wp-config.php
        sed -i "/define( 'AUTH_KEY',/c\\define( 'AUTH_KEY',         '$WORDPRESS_AUTH_KEY' );
" html/wp-config.php
        sed -i "/define( 'SECURE_AUTH_KEY',/c\\define( 'SECURE_AUTH_KEY',  '$WORDPRESS_SECURE_AUTH_KEY' );
" html/wp-config.php
        sed -i "/define( 'LOGGED_IN_KEY',/c\\define( 'LOGGED_IN_KEY',    '$WORDPRESS_LOGGED_IN_KEY' );
" html/wp-config.php
        sed -i "/define( 'NONCE_KEY',/c\\define( 'NONCE_KEY',        '$WORDPRESS_NONCE_KEY' );
" html/wp-config.php
        sed -i "/define( 'AUTH_SALT',/c\\define( 'AUTH_SALT',        '$WORDPRESS_AUTH_SALT' );
" html/wp-config.php
        sed -i "/define( 'SECURE_AUTH_SALT',/c\\define( 'SECURE_AUTH_SALT', '$WORDPRESS_SECURE_AUTH_SALT' );
" html/wp-config.php
        sed -i "/define( 'LOGGED_IN_SALT',/c\\define( 'LOGGED_IN_SALT',   '$WORDPRESS_LOGGED_IN_SALT' );
" html/wp-config.php
        sed -i "/define( 'NONCE_SALT',/c\\define( 'NONCE_SALT',       '$WORDPRESS_NONCE_SALT' );
" html/wp-config.php
        cat >> html/wp-config.php << EOF

/** Redis Configuration */
define('WP_CACHE', true);
define('WP_REDIS_HOST', '$REDIS_HOST');
define('WP_REDIS_PASSWORD', '$REDIS_PASSWORD');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
EOF
        log_message "WordPress configured successfully"
    fi
    log_message "Starting Docker containers..."
    $DOCKER_COMPOSE_CMD up -d || handle_error "Failed to start Docker containers"
    log_message "Waiting for containers to be ready..."
    sleep 10
    log_message "Checking container status..."
    if ! $DOCKER_COMPOSE_CMD ps | grep -q "Up"; then
        handle_error "Some containers failed to start"
    fi
    log_message "All containers are running successfully"
}

setup_backup_config() {
    log_message "[Stage 12] Setting up backup configuration..."
    mkdir -p "$DEPLOY_DIR/scripts"
    cat > "$DEPLOY_DIR/scripts/backup.sh" << 'EOF'
#!/bin/bash

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../backups" && pwd)"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$BACKUP_DIR/backup.log"
    echo "$1"
}

log_message "Starting backup process..."

# Backup WordPress files
log_message "Backing up WordPress files..."
if [ -d "../html" ]; then
    tar -czf "$BACKUP_DIR/wp_files_$DATE.tar.gz" -C "../html" .
    log_message "WordPress files backup completed"
else
    log_message "Warning: WordPress directory not found"
fi

# Backup MySQL database
log_message "Backing up MySQL database..."
if docker ps | grep -q "wp_db"; then
    docker exec wp_db mysqldump -u root -p$(grep MYSQL_ROOT_PASSWORD ../.env | cut -d '=' -f2) wordpress > "$BACKUP_DIR/wp_db_$DATE.sql"
    gzip "$BACKUP_DIR/wp_db_$DATE.sql"
    log_message "MySQL database backup completed"
else
    log_message "Warning: MySQL container not running"
fi

# Clean up old backups
log_message "Cleaning up old backups older than $BACKUP_RETENTION_DAYS days..."
find "$BACKUP_DIR" -name "wp_*.tar.gz" -o -name "wp_*.sql.gz" -type f -mtime +"$BACKUP_RETENTION_DAYS" -delete

log_message "Backup process completed successfully"
EOF
    chmod +x "$DEPLOY_DIR/scripts/backup.sh"
    if command -v crontab >/dev/null 2>&1; then
        log_message "Setting up daily backup cron job..."
        (crontab -l 2>/dev/null; echo "0 2 * * * $DEPLOY_DIR/scripts/backup.sh >> $DEPLOY_DIR/logs/backup.log 2>&1") | crontab -
        log_message "Daily backup cron job set up successfully"
    else
        log_message "Warning: crontab not found, skipping backup schedule"
    fi
}

display_deployment_info() {
    log_message "[Stage 13] Deployment completed successfully!"
    print_blue "\n========================================"
    print_blue "WordPress Docker Deployment Complete"
    print_blue "========================================"
    print_blue "Website URL: http://localhost"
    print_blue "Database Information:"
    print_blue "  Database Name: $MYSQL_DATABASE"
    print_blue "  Database User: $MYSQL_USER"
    print_blue "  Database Password: $MYSQL_PASSWORD"
    print_blue "  Root Password: $MYSQL_ROOT_PASSWORD"
    print_blue "Redis Information:"
    print_blue "  Redis Password: $REDIS_PASSWORD"
    print_blue "Deployment Directory: $DEPLOY_DIR"
    print_blue "Log File: $LOG_FILE"
    print_blue "========================================"
    print_blue "You can now access your WordPress site at http://localhost"
    print_blue "========================================\n"
}

main() {
    log_message "Starting WordPress Docker deployment..."
    
    while getopts "f" opt; do
        case $opt in
            f)
                FORCE_CONFIG=true
                log_message "Force config enabled: Will regenerate all configuration files"
                ;;
            *)
                echo "Usage: $0 [-f]"
                echo "  -f: Force regeneration of all configuration files"
                exit 1
                ;;
        esac
done
    
    detect_host_environment
    environment_preparation
    check_disk_space
    check_memory
    determine_deploy_directory
    generate_passwords
    generate_wordpress_keys
    optimize_env_variables
    set_permissions
    cleanup_old_containers
    generate_configs
    build_images
    start_services
    setup_backup_config
    display_deployment_info
    
    log_message "Deployment process completed successfully!"
}

main "$@"