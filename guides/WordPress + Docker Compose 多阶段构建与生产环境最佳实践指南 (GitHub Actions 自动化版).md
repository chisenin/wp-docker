# WordPress + Docker Compose 多阶段构建与生产环境最佳实践指南

本指南提供了一个现代化、稳健、安全且便于团队协作的 WordPress 生产环境部署方案，使用 Docker Compose 编排服务，结合多阶段构建优化 PHP-FPM、Nginx、MariaDB 和 Redis 镜像，并通过 GitHub Actions 实现 CI/CD 自动化。

## 核心理念

- **确定性**：避免使用 `:latest` 标签，动态提取精确版本，确保生产稳定
- **Alpine 基石**：统一使用 Alpine 基础镜像，兼顾小体积与安全性
- **多阶段构建**：分离开发与运行环境，生成轻量生产镜像
- **配置即代码**：所有配置纳入版本控制，变更通过 Pull Request 审查
- **CI/CD 自动化**：GitHub Actions 自动构建、测试、推送镜像
- **自动版本监控**：定期检查依赖版本更新，自动触发构建和发布

## 项目目录结构

```
wp-docker/
├── .gitignore                        # Git 忽略规则
├── README.md                         # 项目说明
├── README.release                    # 发布说明
├── docker-compose.yml                # 开发环境服务编排
├── .env.example                      # 环境变量模板
├── .github/workflows/                # GitHub Actions 工作流
│   ├── version-monitor-and-build.yml # 版本监控与自动构建工作流（包含构建与推送功能）
│   ├── version-monitor.yml           # 版本监控工作流
│   └── verify-only.yml               # 配置验证工作流
├── build/                            # 构建相关文件
│   ├── Dockerfiles/                  # Dockerfile 目录
│   │   ├── base/                     # 共享 Alpine 基础镜像
│   │   ├── php/                      # PHP-FPM 镜像
│   │   ├── nginx/                    # Nginx 镜像
│   │   ├── mariadb/                  # MariaDB 镜像
│   │   └── redis/                    # Redis 镜像
│   ├── deploy_configs/               # 部署配置目录
│   │   ├── php/                      # PHP 配置
│   │   ├── nginx/                    # Nginx 配置
│   │   ├── mariadb/                  # MariaDB 配置
│   │   └── redis/                    # Redis 配置
│   └── scripts/                      # 构建脚本目录
│       ├── check_versions.sh         # 版本检查脚本
│       ├── mariadb/                  # MariaDB 脚本
│       ├── redis/                    # Redis 脚本
│       └── test-build.sh             # 构建测试脚本
├── deploy/                           # 部署相关文件
│   ├── .env.example                  # 部署环境变量模板
│   ├── docker-compose.yml            # 生产环境服务编排
│   ├── configs/                      # 配置文件目录
│   └── scripts/                      # 部署脚本目录
│       └── auto_deploy.sh            # 自动化部署脚本
└── html/                             # WordPress 源码目录
```

### 初始化 Git

1. **初始化仓库**:

   ```bash
   git init
   ```

2. **创建 `.gitignore`**:

   ```
   .dockerignore
   *.log
   html/wp-config.php
   .env
   *.key
   *.pem
   .vscode/
   .idea/
   *.swp
   ```

3. **初始提交**:

   ```bash
   git add .
   git commit -m "feat: 初始化 WordPress 项目，包含基础 Docker 配置与目录结构"
   ```

4. **配置 GitHub Secrets**:

   - 在 GitHub 仓库设置 `DOCKERHUB_USERNAME` 和 `DOCKERHUB_TOKEN`。
   - 添加 `GITHUB_TOKEN`（自动生成）以支持创建 Releases。

------

## Docker Compose 配置 (`docker-compose.yml`)

### 生产环境配置示例

```yaml
version: '3.8'

services:
  # --- MariaDB 数据库服务 ---
  mariadb:
    # 使用我们构建的MariaDB镜像，支持自动版本更新
    build:
      context: .
      dockerfile: build/Dockerfiles/mariadb/Dockerfile
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-mariadb:${MARIADB_VERSION:-11.3.2}
    container_name: wp_db
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      - db_data:/var/lib/mysql
      - ./build/deploy_configs/mariadb/my.cnf:/etc/my.cnf:ro
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    expose:
      - "3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-u", "root", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 30s
      timeout: 10s
      retries: 3

  # --- Redis 缓存服务 ---
  redis:
    # 使用我们构建的Redis镜像，支持自动版本更新
    build:
      context: .
      dockerfile: build/Dockerfiles/redis/Dockerfile
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-redis:${REDIS_VERSION:-7.4.0}
    container_name: wp_redis
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      - redis_data:/data
      - ./build/deploy_configs/redis/redis.conf:/etc/redis/redis.conf:ro
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD:-}
      REDIS_MAXMEMORY: ${REDIS_MAXMEMORY:-256mb}
    expose:
      - "6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3

  # --- PHP-FPM 服务 ---
  php:
    # 使用我们构建的PHP镜像，支持自动版本更新
    build:
      context: .
      dockerfile: build/Dockerfiles/php/Dockerfile
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-php:${PHP_VERSION:-8.3.26}
    container_name: wp_fpm
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      # 注意：宿主机 html 目录挂载到容器内 /var/www/html
      - ./html:/var/www/html
      # 使用deploy目录中的PHP配置
      - ./build/deploy_configs/php/php.ini:/usr/local/etc/php/php.ini:ro
    expose:
      - "9000"
    depends_on:
      mariadb:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      WORDPRESS_DB_HOST: mariadb:3306
      WORDPRESS_DB_USER: ${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
      WORDPRESS_REDIS_HOST: redis
      WORDPRESS_REDIS_PORT: 6379
      PHP_OPCACHE_ENABLE: 1
      PHP_MEMORY_LIMIT: ${PHP_MEMORY_LIMIT:-512M}
    healthcheck:
      test: ["CMD", "php-fpm", "-t"]
      interval: 60s
      timeout: 10s
      retries: 3

  # --- Nginx 服务 ---
  nginx:
    # 使用我们构建的Nginx镜像，支持自动版本更新
    build:
      context: .
      dockerfile: build/Dockerfiles/nginx/Dockerfile
    image: ${DOCKERHUB_USERNAME:-library}/wordpress-nginx:${NGINX_VERSION:-1.27.2}
    container_name: wp_nginx
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      # 挂载自定义配置文件
      - ./build/deploy_configs/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./build/deploy_configs/nginx/conf.d:/etc/nginx/conf.d:ro
      - ./html:/var/www/html
      - nginx_logs:/var/log/nginx
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      php:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 60s
      timeout: 10s
      retries: 3

networks:
  app-network:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.18.0.0/16

volumes:
  db_data:
    driver: local
  redis_data:
    driver: local
  nginx_logs:
    driver: local
```

**主要特点**:

- 使用自定义构建的所有组件镜像（MariaDB、Redis、PHP、Nginx）
- 支持自动版本更新，通过环境变量控制版本号
- 健康检查确保服务可用性
- 服务依赖关系基于健康状态
- 挂载外部配置文件，便于修改
- 支持HTTPS（需要添加SSL证书）
- 环境变量默认值确保无配置文件也能运行

------

## 构建共享 Alpine Base 镜像

**`build/Dockerfiles/base/Dockerfile`**:

```dockerfile
FROM alpine:3.22

# 设置 Alpine 源并更新
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories && \
    apk update --no-cache && \
    # 安装基础工具
    apk add --no-cache tzdata curl wget ca-certificates && \
    # 设置时区为上海
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    # 清理缓存
    rm -rf /var/cache/apk/* 2>/dev/null || true

# 创建必要的目录结构
RUN mkdir -p /var/log && \
    chmod 777 /var/log

# 健康检查基础命令
HEALTHCHECK --interval=30s --timeout=10s --retries=3 CMD ["echo", "Base image is healthy"]

# 默认命令
CMD ["/bin/sh"]

------

## 构建自定义 PHP-FPM 镜像

**`build/Dockerfiles/php/Dockerfile`**:

```dockerfile
ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE} AS base

FROM php:8.3.26-fpm-alpine3.22 AS builder
ARG COMPOSER_HASH=""

# 获取 PHP 版本
RUN php -v | head -1 | cut -d' ' -f2 | cut -d'-' -f1 > /tmp/php_version || echo "8.3.26" > /tmp/php_version

# 复制 Alpine 源配置
COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 安装构建依赖并编译 PHP 扩展
RUN apk update --no-cache && \
    apk add --no-cache libzip-dev freetype-dev libpng-dev libjpeg-turbo-dev icu-dev libwebp-dev \
                     git zip unzip autoconf g++ libtool && \
    # 配置 GD 扩展
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp && \
    # 安装 WordPress 必需的 PHP 扩展
    docker-php-ext-install -j$(nproc) pdo_mysql mysqli gd exif intl zip opcache && \
    # 安装 Redis 扩展
    pecl install redis && \
    docker-php-ext-enable redis

# 安装 Composer
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    EXPECTED_HASH=$( [ -n "$COMPOSER_HASH" ] && echo "$COMPOSER_HASH" || echo "ed0feb545ba87161262f2d45a633e34f591ebb3381f2e0063c345ebea4d228dd0043083717770234ec00c5a9f9593792" ) && \
    php -r "if (hash_file('sha384', 'composer-setup.php') === '$EXPECTED_HASH') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); exit(1); }; echo PHP_EOL;" && \
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
    php -r "unlink('composer-setup.php');" && \
    # 清理缓存
    rm -rf /var/cache/apk/* 2>/dev/null || true

FROM php:8.3.26-fpm-alpine3.22 AS final

# 复制配置和构建的扩展
COPY --from=base /etc/apk/repositories /etc/apk/repositories
COPY --from=base /etc/localtime /etc/localtime
COPY --from=base /etc/timezone /etc/timezone
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /tmp/php_version /tmp/php_version

# 启用扩展
RUN docker-php-ext-enable pdo_mysql mysqli gd exif intl zip opcache redis && \
    # 清理缓存
    rm -rf /var/cache/apk/* 2>/dev/null || true

# 复制 PHP 配置文件
COPY ./build/deploy_configs/php/php.ini /usr/local/etc/php/php.ini

# 创建必要的目录并设置权限
RUN mkdir -p /var/log/php /var/www/html && \
    chown -R www-data:www-data /var/log/php /var/www/html && \
    chmod -R 755 /var/log/php /var/www/html

# 健康检查
HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD php-fpm -t || exit 1

# 设置工作目录
WORKDIR /var/www/html

# 切换到 www-data 用户
USER www-data

# 默认命令
CMD ["php-fpm", "-F"]
```

## 构建自定义 MariaDB 镜像（新增）

**`build/Dockerfiles/mariadb/Dockerfile`**:

```dockerfile
ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE} AS base

FROM mariadb:11.3.2 AS builder

# 获取 MariaDB 版本
RUN mysql --version | awk '{print $5}' | cut -d'-' -f1 > /tmp/mariadb_version || echo "11.3.2" > /tmp/mariadb_version

# 复制 Alpine 源配置
COPY --from=base /etc/apk/repositories /etc/apk/repositories
COPY --from=base /etc/localtime /etc/localtime
COPY --from=base /etc/timezone /etc/timezone

# 安装必要工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget tzdata && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

FROM mariadb:11.3.2 AS final

# 复制版本信息和工具
COPY --from=builder /tmp/mariadb_version /tmp/mariadb_version
COPY --from=builder /etc/localtime /etc/localtime
COPY --from=builder /etc/timezone /etc/timezone

# 添加 WordPress 优化配置
COPY ./build/deploy_configs/mariadb/my.cnf /etc/my.cnf

# 创建数据目录和日志目录
RUN mkdir -p /var/lib/mysql /var/log/mysql && \
    chown -R mysql:mysql /var/lib/mysql /var/log/mysql && \
    chmod -R 755 /var/lib/mysql /var/log/mysql

# 复制初始化脚本
COPY ./build/scripts/mariadb/entrypoint.sh /entrypoint.sh
COPY ./build/scripts/mariadb/init.sql /docker-entrypoint-initdb.d/

RUN chmod +x /entrypoint.sh

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD mysqladmin ping -u root -p$MYSQL_ROOT_PASSWORD || exit 1

# 暴露端口
EXPOSE 3306

# 设置入口点
ENTRYPOINT ["/entrypoint.sh"]
CMD ["mysqld"]
```

------

## 构建自定义 Redis 镜像（新增）

**`build/Dockerfiles/redis/Dockerfile`**:

```dockerfile
ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE} AS base

FROM redis:7.4.0-alpine3.22 AS builder

# 获取 Redis 版本
RUN redis-server --version | awk '{print $3}' | cut -d'v' -f2 > /tmp/redis_version || echo "7.4.0" > /tmp/redis_version

# 复制 Alpine 源配置
COPY --from=base /etc/apk/repositories /etc/apk/repositories
COPY --from=base /etc/localtime /etc/localtime
COPY --from=base /etc/timezone /etc/timezone

# 安装必要工具
RUN apk update --no-cache && \
    apk add --no-cache curl wget tzdata && \
    rm -rf /var/cache/apk/*

FROM redis:7.4.0-alpine3.22 AS final

# 复制版本信息和配置
COPY --from=builder /tmp/redis_version /tmp/redis_version
COPY --from=builder /etc/localtime /etc/localtime
COPY --from=builder /etc/timezone /etc/timezone

# 创建配置目录和数据目录
RUN mkdir -p /etc/redis /data && \
    chown -R redis:redis /etc/redis /data && \
    chmod -R 755 /etc/redis /data

# 复制 Redis 配置
COPY ./build/deploy_configs/redis/redis.conf /etc/redis/redis.conf

# 复制入口点脚本
COPY ./build/scripts/redis/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD redis-cli ping || exit 1

# 暴露端口
EXPOSE 6379

# 设置数据目录
VOLUME ["/data"]

# 设置入口点
ENTRYPOINT ["/entrypoint.sh"]
CMD ["redis-server", "/etc/redis/redis.conf"]
```

## 构建自定义 Nginx 镜像

**`build/Dockerfiles/nginx/Dockerfile`**:

```dockerfile
ARG NGINX_VERSION=1.27.2
ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE} AS base

FROM nginx:${NGINX_VERSION}-alpine AS builder

# 获取 Nginx 版本
RUN nginx -v 2>&1 | cut -d'/' -f2 | cut -d' ' -f1 > /tmp/nginx_version || echo "1.27.2" > /tmp/nginx_version

# 复制 Alpine 源配置
COPY --from=base /etc/apk/repositories /etc/apk/repositories
COPY --from=base /etc/localtime /etc/localtime
COPY --from=base /etc/timezone /etc/timezone

# 安装必要工具
RUN apk update --no-cache && \
    apk add --no-cache vim bash curl wget && \
    rm -rf /var/cache/apk/*

FROM nginx:${NGINX_VERSION}-alpine AS final

# 复制版本信息和工具
COPY --from=builder /tmp/nginx_version /tmp/nginx_version
COPY --from=builder /etc/apk/repositories /etc/apk/repositories
COPY --from=builder /etc/localtime /etc/localtime
COPY --from=builder /etc/timezone /etc/timezone
COPY --from=builder /bin/bash /bin/bash
COPY --from=builder /usr/bin/vim /usr/bin/vim
COPY --from=builder /usr/bin/curl /usr/bin/curl
COPY --from=builder /usr/bin/wget /usr/bin/wget

# 复制 Nginx 配置
COPY ./build/deploy_configs/nginx/nginx.conf /etc/nginx/nginx.conf
COPY ./build/deploy_configs/nginx/conf.d /etc/nginx/conf.d

# 创建必要的目录并设置权限
RUN mkdir -p /var/www/html /var/log/nginx /var/cache/nginx && \
    chown -R nginx:nginx /var/www/html /var/log/nginx /var/cache/nginx && \
    chmod -R 755 /var/www/html /var/log/nginx /var/cache/nginx

# 健康检查
HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD nginx -t || exit 1

# 暴露端口
EXPOSE 80
EXPOSE 443

# 默认命令
CMD ["nginx", "-g", "daemon off;"]

# 设置工作目录
WORKDIR /var/www/html

# 切换到 nginx 用户
USER nginx

```nginx
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;
events {
    worker_connections 1024;
}
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    keepalive_timeout 65;
    include /etc/nginx/conf.d/*.conf;
}
```

**`build/deploy_configs/nginx/conf.d/wordpress.conf`**:

```nginx
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
    index index.php index.html index.htm;

    # 日志设置
    access_log /var/log/nginx/wordpress.access.log;
    error_log /var/log/nginx/wordpress.error.log warn;

    # Gzip设置（站点级）
    gzip on;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/js text/xml application/javascript application/json application/xml;

    # 安全头
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # 位置规则：静态文件直接提供
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }

    # 禁止访问敏感文件
    location ~* /\.(?!well-known).* {
        deny all;
    }
    location ~* \.(ini|log|conf|bak|old)$ {
        deny all;
    }

    # WordPress REST API 缓存
    location ~ ^/wp-json/ {
        expires 10m;
        try_files $uri $uri/ /index.php?$args;
    }

    # 主位置规则
    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    # PHP处理
    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        
        # 性能优化
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    # 禁止访问版本文件
    location ~ /wp-admin/includes/ {
        deny all;
    }
    location ~ /wp-includes/js/tinymce/langs/ {
        deny all;
    }
    location ~ /wp-includes/theme-compat/ {
        deny all;
    }

    # 限制XML-RPC以防止DDoS攻击
    location ~* /xmlrpc.php {
        limit_req zone=xmlrpc_limit burst=10 nodelay;
        try_files $uri =404;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
```

------

## GitHub Actions 自动化构建与 Releases

**`.github/workflows/build-and-push.yml`**:

```yaml
name: Build and Push Docker Images
on:
  push: { branches: [main, test-nginx-only] }
  pull_request: { branches: [main, test-nginx-only] }
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - name: Build and Push Base Image
        run: docker buildx build --platform linux/amd64,linux/arm64 -f ./Dockerfiles/base/Dockerfile -t ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-base:3.22 --push ./Dockerfiles/base
      - name: Check Changed Components
        id: check-changes
        run: |
          updated_components=""
          php_changed=$(git diff --name-only origin/main HEAD | grep -q "Dockerfiles/php/" && echo true || echo false)
          nginx_changed=$(git diff --name-only origin/main HEAD | grep -q "Dockerfiles/nginx/" && echo true || echo false)
          base_changed=$(git diff --name-only origin/main HEAD | grep -q "Dockerfiles/base/" && echo true || echo false)
          $base_changed && updated_components="$updated_components base"
          $php_changed && updated_components="$updated_components php"
          $nginx_changed && updated_components="$updated_components nginx"
          echo "updated_components=$updated_components" >> $GITHUB_OUTPUT
      - name: Extract Versions
        id: extract
        run: |
          PHP_VERSION=$(cat Dockerfiles/php/php_version.txt 2>/dev/null || echo '8.3.26')
          NGINX_VERSION=$(cat Dockerfiles/nginx/nginx_version.txt 2>/dev/null || echo '1.27.2')
          COMPOSER_HASH=$(cat Dockerfiles/php/composer_hash.txt 2>/dev/null || echo 'ed0feb545ba87161262f2d45a633e34f591ebb3381f2e0063c345ebea4d228dd0043083717770234ec00c5a9f9593792')
          echo "php_version=$PHP_VERSION" >> $GITHUB_OUTPUT
          echo "nginx_version=$NGINX_VERSION" >> $GITHUB_OUTPUT
          echo "composer_hash=$COMPOSER_HASH" >> $GITHUB_OUTPUT
      - name: Build and Push PHP Image
        if: contains(steps.check-changes.outputs.updated_components, 'php') || contains(steps.check-changes.outputs.updated_components, 'base')
        run: docker buildx build --platform linux/amd64,linux/arm64 --build-arg BASE_IMAGE=${{ secrets.DOCKERHUB_USERNAME }}/wordpress-base:3.22 --build-arg COMPOSER_HASH=${{ steps.extract.outputs.composer_hash }} -f ./Dockerfiles/php/Dockerfile -t ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:${{ steps.extract.outputs.php_version }} --push .
      - name: Build and Push Nginx Image
        if: contains(steps.check-changes.outputs.updated_components, 'nginx') || contains(steps.check-changes.outputs.updated_components, 'base')
        run: docker buildx build --platform linux/amd64,linux/arm64 --build-arg BASE_IMAGE=${{ secrets.DOCKERHUB_USERNAME }}/wordpress-base:3.22 --build-arg NGINX_VERSION=${{ steps.extract.outputs.nginx_version }} -f ./Dockerfiles/nginx/Dockerfile -t ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:${{ steps.extract.outputs.nginx_version }} --push .
      - name: Generate Release Assets
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          echo "Generating .env file for release..."
          cat > .env << EOF
          DOCKERHUB_USERNAME=${{ secrets.DOCKERHUB_USERNAME }}
          PHP_VERSION=${{ steps.extract.outputs.php_version }}
          NGINX_VERSION=${{ steps.extract.outputs.nginx_version }}
          MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24)
          MYSQL_DATABASE=wordpress
          MYSQL_USER=wordpress
          MYSQL_PASSWORD=$(openssl rand -base64 24)
          EOF
          echo "Copying docker-compose.yml..."
          cp docker-compose.yml docker-compose-release.yml
      - name: Create GitHub Release
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: actions/create-release@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          tag_name: v${{ steps.extract.outputs.php_version }}-${{ steps.extract.outputs.nginx_version }}
          release_name: WordPress Release v${{ steps.extract.outputs.php_version }}-${{ steps.extract.outputs.nginx_version }}
          body: |
            Automated release for WordPress with PHP ${{ steps.extract.outputs.php_version }} and Nginx ${{ steps.extract.outputs.nginx_version }}.
            Includes .env and docker-compose.yml for deployment.
          draft: false
          prerelease: false
          assets: |
            - path: .env
              name: .env
            - path: docker-compose-release.yml
              name: docker-compose.yml
      - name: Docker Compose Validation
        run: |
          echo "DOCKERHUB_USERNAME=library" > .env
          echo "PHP_VERSION=8.3-fpm-alpine3.22" >> .env
          echo "NGINX_VERSION=1.27-alpine" >> .env
          echo "MYSQL_ROOT_PASSWORD=test_root_password" >> .env
          echo "MYSQL_DATABASE=wordpress" >> .env
          echo "MYSQL_USER=wordpress" >> .env
          echo "MYSQL_PASSWORD=test_wordpress_password" >> .env
          docker compose config -q || exit 1
          docker compose config
```

**说明**:

- **Releases 功能**：在 `main` 分支推送时，生成 `.env`（包含随机密码和版本号）和 `docker-compose.yml`，并通过 `actions/create-release` 创建 GitHub Release，附带这两个文件作为资产。
- **触发条件**：仅在 `main` 分支推送时生成 Release，避免 PR 或其他分支触发。
- **资产生成**：`.env` 包含动态版本和安全密码，`docker-compose.yml` 直接复用项目文件。
- **权限**：添加 `contents: write` 权限以支持 Release 创建。

**`.github/workflows/version-monitor.yml`**:

- 每天自动检查 Alpine、PHP、Nginx、Composer 版本，更新版本文件，触发 `build-and-push.yml` 进行自动构建。已实现并集成到工作流中，可自动检查更新并触发构建流程。

------

## Git 工作流与变更管理

1. **分支管理**:

   - `main`: 稳定分支。
   - 功能分支: 如 `feat/nginx-gzip`、`fix/php-upload-size`。

2. **Commit 规范**:

   - 使用 Conventional Commits（如 `feat`, `fix`, `docs`）。
   - 示例: `git commit -m "feat(nginx): 开启 Gzip 压缩"`

3. **Pull Request**:

   - 推送功能分支，创建 PR，团队审查后合并，触发 Actions 构建和 Release。

4. **部署**:

   ```bash
   docker-compose pull
   docker-compose up -d
   ```

------

## 自动化部署（推荐）

项目提供了功能强大的 `auto_deploy.sh` 脚本，位于 `deploy/scripts/` 目录下，可以一键完成 WordPress 项目的自动化部署，包括：
- **创建专用部署目录**：避免在系统目录直接部署，提供交互式目录名称设置
- 创建项目内部目录结构
- 获取最新的镜像版本信息
- 生成完整的 `.env` 文件（含数据库信息和8组 WordPress 安全密钥）
- 生成 `docker-compose.yml` 配置文件，使用自定义构建的Nginx镜像
- 下载并解压最新版 WordPress
- 复制或生成必要的配置文件
- 启动所有服务并设置适当的文件权限

### 使用方法

1. **准备环境**:
   - 确保服务器已安装 Docker 和 Docker Compose
   - 克隆仓库并进入项目目录：
   ```bash
   git clone <your-repo-url> wp-docker
   cd wp-docker
   ```

2. **执行自动化部署**:
   ```bash
   chmod +x deploy/scripts/auto_deploy.sh  # Linux/macOS环境
   ./deploy/scripts/auto_deploy.sh
   ```

3. **部署完成后**:
   - 脚本会输出访问信息和所有敏感凭据
   - 浏览器访问 `http://服务器IP` 即可完成 WordPress 安装向导
   - 推荐安装并配置 Redis Object Cache 插件以启用缓存功能

## 传统部署方式（可选）

如果您不需要自动化部署，也可以按以下步骤手动部署：

1. **准备环境**:

   - 确保服务器已安装 Docker 和 Docker Compose。

   - 克隆仓库并进入项目的 deploy 目录:

     ```bash
     git clone <your-repo-url> wp-docker
     cd wp-docker/deploy
     ```

     或从 GitHub Release 下载 

     ```
     .env
     ```

      和 

     ```
     docker-compose.yml
     ```
     文件到部署目录。

2. **下载 WordPress**:

   ```bash
   wget https://wordpress.org/latest.tar.gz
   tar -xvzf latest.tar.gz
   mv wordpress/* html/
   rm -rf wordpress latest.tar.gz
   mkdir -p html/wp-content/uploads
   ```

3. **创建配置目录**:

   ```bash
   mkdir -p configs/nginx/conf.d
   ```

4. **复制或生成配置文件**:

   - 从 build 目录复制 Nginx 配置:
   ```bash
   cp ../build/Dockerfiles/nginx/nginx.conf configs/nginx/
   cp -r ../build/Dockerfiles/nginx/conf.d/* configs/nginx/conf.d/
   ```

   - 或使用默认配置:
   ```bash
   # 创建默认 Nginx 配置文件
   # 这里可以添加创建默认配置的命令
   ```

5. **拉取并启动服务**:

   ```bash
   docker-compose pull
   docker-compose up -d
   ```

6. **设置文件权限**:

## 部署流程

### 使用自动部署脚本（推荐）

```bash
# 在生产服务器上
chmod +x deploy/scripts/auto_deploy.sh
./deploy/scripts/auto_deploy.sh
```

脚本会自动完成所有配置、下载和启动流程，包括创建目录、生成安全密码和密钥、下载WordPress、启动所有服务等。

### 完成安装

- 浏览器访问 `http://服务器IP`，按向导配置数据库
- 安装并配置 "Redis Object Cache" 插件以启用缓存功能

## 总结

本指南提供了一个稳定、高效、可维护的 WordPress 生产环境，集成了最佳实践:

- **动态版本锁定**：避免使用 `:latest` 标签，使用精确版本确保稳定性
- **多阶段构建**：共享基础镜像，优化镜像大小与构建效率
- **CI/CD 自动化**：GitHub Actions 自动构建、测试和部署
- **版本监控**：自动检测依赖版本更新并触发构建
- **自动化部署**：一键部署脚本简化生产环境部署流程

如需更详细的配置说明，请参考项目中的示例配置文件和脚本注释。