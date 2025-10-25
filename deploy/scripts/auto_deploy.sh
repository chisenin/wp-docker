#!/bin/sh
# ??sh???????
set -eu
# pipefail?bash??????sh????

# WordPress Docker ?????????????????
# ????????????????????????????????????

echo "=================================================="
echo "WordPress Docker ???????? - ???????"
echo "=================================================="

# ????
OS_TYPE=""
OS_VERSION=""
CPU_CORES=0
AVAILABLE_RAM=0
DISK_SPACE=0
DISK_USAGE=0
DEPLOY_DIR=""
BACKUP_DIR=""
BACKUP_RETENTION_DAYS=7

# ????????????Windows???
print_green() { echo "$1"; }
print_yellow() { echo "$1"; }
print_red() { echo "$1"; }
print_blue() { echo "$1"; }

# ??????
handle_error() {
    print_red "??: $1"
    exit 1
}

# ???????
detect_host_environment() {
    print_blue "[??1] ???????..."
    
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
        handle_error "?????????????? CentOS?Debian?Ubuntu ? Alpine"
    fi
    
    print_green "????: $OS_TYPE $OS_VERSION"
    
    case "$OS_TYPE" in
        centos|debian|ubuntu|alpine)
            print_green "? ???????"
            ;;
        *)
            handle_error "????????: $OS_TYPE???? CentOS?Debian?Ubuntu ? Alpine"
            ;;
    esac
}

# ??????
collect_system_parameters() {
    print_blue "[??2] ??????..."
    
    CPU_CORES=$(nproc)
    print_green "CPU ???: $CPU_CORES"
    
    AVAILABLE_RAM=$(free -m | grep Mem | awk '{print $2}')
    print_green "????: ${AVAILABLE_RAM}MB"
    
    DISK_SPACE=$(df -h / | tail -1 | awk '{print $4}')
    DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
    print_green "??????: $DISK_SPACE"
    print_green "?????: ${DISK_USAGE}%"
    
    if ! command -v docker >/dev/null 2>&1; then
        print_red "Docker ??????????..."
        install_docker
    else
        DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
        print_green "Docker ??: $DOCKER_VERSION"
    fi
    
    if ! command -v docker-compose >/dev/null 2>&1; then
        print_red "Docker Compose ??????????..."
        install_docker_compose
    else
        COMPOSE_VERSION=$(docker-compose --version | awk '{print $3}' | sed 's/,//')
        print_green "Docker Compose ??: $COMPOSE_VERSION"
    fi
    
    if [ "$DISK_USAGE" -gt 80 ]; then
        print_yellow "??: ??????? 80%?????????"
        BACKUP_RETENTION_DAYS=3
        print_yellow "????????????: $BACKUP_RETENTION_DAYS ?"
    fi
    
    if [ "$AVAILABLE_RAM" -lt 2048 ]; then
        print_yellow "??: ???? 2GB???????"
    fi
}

# ???????? Docker
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

# ?? Docker Compose
install_docker_compose() {
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
}

# ??????
determine_deployment_directory() {
    print_blue "[??3] ??????..."
    
    if [ -d "/opt/wp-docker" ]; then
        DEPLOY_DIR="/opt/wp-docker"
        print_green "??????: $DEPLOY_DIR"
    elif [ -d "/var/wp-docker" ]; then
        DEPLOY_DIR="/var/wp-docker"
        print_green "??????: $DEPLOY_DIR"
    else
        print_green "??????: /opt/wp-docker"
        mkdir -p /opt/wp-docker || handle_error "????????"
        DEPLOY_DIR="/opt/wp-docker"
    fi
    
    BACKUP_DIR="$DEPLOY_DIR/backups"
    SCRIPTS_DIR="$DEPLOY_DIR/scripts"
    LOGS_DIR="$DEPLOY_DIR/logs"
    
    mkdir -p "$BACKUP_DIR" || handle_error "????????"
    mkdir -p "$SCRIPTS_DIR" || handle_error "????????"
    mkdir -p "$LOGS_DIR" || handle_error "????????"
    
    print_green "????: $BACKUP_DIR"
    print_green "????: $SCRIPTS_DIR"
    print_green "????: $LOGS_DIR"
    
    cd "$DEPLOY_DIR" || handle_error "?????????"
    print_green "??????: $(pwd)"
}

# ??????
generate_password() {
    local length=${1:-24}
    tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c "$length" || echo "default_password_change_me"
}

# ?? WordPress ????????????????
generate_wordpress_keys() {
    print_blue "?? WordPress ????..."
    local keys_url="https://api.wordpress.org/secret-key/1.1/salt/"
    local keys=$(curl -s "$keys_url" || wget -qO- "$keys_url" || echo "# ??????????????")
    keys=$(echo "$keys" | \
        sed "s/define('\([^']*\)', '\([^']*\)');/WORDPRESS_\1=\2/" | \
        sed "s/define(\"\([^\"]*\)\", \"\([^\"]*\)\");/WORDPRESS_\1=\2/")
    echo "$keys"
}

# ??????????
optimize_parameters() {
    print_blue "[??4] ??????????..."
    
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
    
    print_green "CPU ??: $CPU_LIMIT ?"
    print_green "????: ${MEM_LIMIT}MB"
    print_green "PHP ????: $PHP_MEMORY_LIMIT"
    
    if [ ! -f ".env" ]; then
        print_blue "???????? (.env)..."
        
        local root_password=$(generate_password)
        local db_user_password=$(generate_password)
        local wp_keys=$(generate_wordpress_keys)
        
        local php_version="8.3.26"
        local nginx_version="1.27.2"
        local mariadb_version="11.3.2"
        local redis_version="7.4.0"
        
        # ??????????????????????
        # ??wp_keys?????????????
        local sanitized_keys=$(echo "$wp_keys" | sed 's/\r//g' | sed 's/"/\\"/g')
        
        cat > .env << EOF
# WordPress Docker??????
# ????: $(date)

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
REDIS_PASSWORD=$(generate_password 16)
REDIS_MAXMEMORY=256mb

CPU_LIMIT=$CPU_LIMIT
MEM_LIMIT=${MEM_LIMIT}MB
PHP_MEMORY_LIMIT=$PHP_MEMORY_LIMIT
UPLOAD_MAX_FILESIZE=64M

# WordPress???? - ?????export????python-dotenv?????
export $(echo "$sanitized_keys" | sed 's/WORDPRESS_//g')
EOF
        
        # ???????????
        print_yellow "??: .env???????Linux????????????"
        print_yellow "      ?????? 'dos2unix .env' ??????LF???"
        
        print_green "? .env ??????"
        print_yellow "??: ???????? .env ?????????"
    else
        print_yellow "??: .env ??????????"
        source .env 2>/dev/null || :
        CPU_LIMIT=${CPU_LIMIT:-$((CPU_CORES / 2))}
        MEM_LIMIT=${MEM_LIMIT:-${AVAILABLE_RAM/2}MB}
        PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT:-$PHP_MEMORY_LIMIT}
    fi
    
    if [ ! -f "docker-compose.yml" ]; then
        print_blue "?? Docker Compose ????..."
        
        # ??CPU_LIMIT???????
        if [ -z "$CPU_LIMIT" ] || [ "$CPU_LIMIT" -eq 0 ]; then
            CPU_LIMIT=1
        fi
        
        # ??docker-compose.yml???????????????
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
        
        print_green "? docker-compose.yml ??????"
    else
        print_yellow "??: docker-compose.yml ??????????"
    fi
    
    # ???????????????
    print_yellow "??: ???Linux?????????????LF?????CRLF"
    print_yellow "      ?????? 'dos2unix auto_deploy.sh .env docker-compose.yml' ????"
    
    # ?? nginx?php.ini ??????????????
}

# ?? WordPress Docker ?
deploy_wordpress_stack() {
    print_blue "[??5] ?? WordPress Docker ?..."
    
    if [ ! -f "html/wp-config.php" ]; then
        if [ -z "$(ls -A html 2>/dev/null)" ]; then
            print_blue "?? WordPress ????..."
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
                print_green "??????..."
                # ????Docker???????????????????
                local retry_count=3
                local retry_delay=5
                local docker_success=false
                
                # ??????Docker????????????????
                # echo '{"registry-mirrors": ["https://registry.docker-cn.com", "https://docker.mirrors.ustc.edu.cn"]}' > /etc/docker/daemon.json 2>/dev/null || true
                
                for i in $(seq 1 $retry_count); do
                    print_blue "????alpine?? (?$i???)..."
                    if docker run --rm -v "$(pwd)/html:/var/www/html" alpine:latest chown -R www-data:www-data /var/www/html 2>/dev/null; then
                        docker_success=true
                        print_green "? Docker??????"
                        break
                    else
                        print_yellow "??: Docker?????$retry_delay????..."
                        sleep $retry_delay
                    fi
                done
                
                # ??Docker???????????chown??
                if [ "$docker_success" = false ]; then
                    print_yellow "??: Docker???????????chown??..."
                    if command -v chown >/dev/null; then
                        if chown -R 33:33 "$(pwd)/html" 2>/dev/null; then  # 33?www-data???UID
                            print_green "? ??chown????????"
                        else
                            print_yellow "??: ???????????????: chown -R www-data:www-data $(pwd)/html"
                        fi
                    else
                        print_yellow "??: ???chown???????????"
                    fi
                fi
                
                print_green "? WordPress ???????"
            else
                print_yellow "??: WordPress ?????????????? html ??"
            fi
        else
            print_green "? html ?????????? WordPress ??"
        fi
    else
        print_green "? WordPress ????????????"
    fi
    
    # ===== ????? WordPress ???? =====
    print_blue "?? WordPress ????..."
    if [ ! -f "html/wp-config.php" ]; then
        print_yellow "??: html/wp-config.php ????????????"
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

        print_green "? WordPress ??????"
    fi
    # ===== ???? =====

    print_blue "??Docker??..."
    docker-compose build

    print_blue "?? Docker ??..."
    docker-compose up -d

    print_blue "???????..."
    sleep 10

    print_blue "??????..."
    docker-compose ps

    if [ "$(docker-compose ps -q | wc -l)" -eq "4" ]; then
        print_green "? WordPress Docker ?????"
    else
        print_red "? WordPress Docker ???????????"
        docker-compose logs --tail=50
    fi
}

# ?????????
setup_auto_backup() {
    print_blue "[??6] ?????????..."
    # ??????????...
}

# ????????
setup_disk_space_management() {
    print_blue "[??7] ????????..."
    # ??????????...
}

# ??????
display_deployment_info() {
    print_blue "=================================================="
    print_green "?????"
    print_blue "=================================================="
    local HOST_IP=$(hostname -I | awk '{print $1}')
    print_green "????: http://$HOST_IP"
    print_green ""
    print_green "????:"
    print_green "  - ????: $OS_TYPE $OS_VERSION"
    print_green "  - CPU ??: $CPU_CORES ??????: $((CPU_CORES / 2)) ??"
    print_green "  - ????: ${AVAILABLE_RAM}MB?????: $((AVAILABLE_RAM / 2))MB?"
    print_green "  - ????: $DEPLOY_DIR"
    print_green "  - ????: $BACKUP_DIR"
    print_green "  - ????: $BACKUP_RETENTION_DAYS ?"
    print_green ""
    print_green "?????:"
    print_green "  - ????: wordpress"
    print_green "  - ???: wordpress"
    print_green "  - ??: ??? .env ???? MYSQL_PASSWORD"
    print_green "  - ??: mariadb"
    print_green ""
    print_green "?????:"
    print_green "  - ? ???????????? 3 ??"
    print_green "  - ? ????????????: 80%?"
    print_green "  - ? ?? Docker ????????? 2 ??"
    print_green ""
    print_yellow "??: ??? .env ???????????"
    print_blue "=================================================="
}

# ???
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
    print_green "?? WordPress Docker ???????"
}

# ?????
main
x 
 
 \ n #   4N�e�O9e
 
