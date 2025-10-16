# WordPress + Docker Compose 多阶段构建与生产环境最佳实践指南 (GitHub Actions 自动化版)

本指南提供了一个现代化、稳健、安全且便于团队协作的 WordPress 生产环境部署方案，使用 Docker Compose 编排服务，结合多阶段构建优化 PHP-FPM 和 Nginx 镜像，并通过 GitHub Actions 实现 CI/CD 自动化。所有构建在云端完成，无需本地硬件。新版本增加了 **GitHub Releases 功能**，在构建完成后自动生成 `.env` 和 `docker-compose.yml` 作为发布资产，简化部署流程。

------

## 核心理念

1. **确定性**：避免使用 `:latest` 标签，动态提取精确版本（如 PHP 8.3.26、Nginx 1.27.2），确保生产稳定。
2. **Alpine 基石**：统一使用 `alpine:3.22`，兼顾小体积与安全性。
3. **国内源加速**：支持切换国内镜像源（如阿里云）以加快构建（Actions 默认官方源）。
4. **多阶段构建**：分离开发与运行环境，生成轻量生产镜像。
5. **配置即代码**：所有配置（如 `docker-compose.yml`、`nginx.conf`、`php.ini`）纳入 Git，变更通过 Pull Request 审查。
6. **CI/CD 自动化**：GitHub Actions 自动构建、测试、推送镜像，并生成 Release 资产。

------

## 项目目录结构

```
wordpress-project/
├── .git/                             # Git 仓库
├── .gitignore                        # 忽略规则
├── README.md                         # 项目说明
├── docker-compose.yml                # 服务编排（开发环境）
├── .env.example                      # 环境变量模板
├── .github/workflows/                # GitHub Actions 工作流
│   ├── build-and-push.yml            # 构建与推送
│   ├── version-monitor.yml           # 版本监控（已实现并集成）
│   └── verify-only.yml               # 配置验证工作流
├── build/                            # 构建相关文件
│   └── Dockerfiles/                  # Dockerfile 目录
│       ├── base/Dockerfile           # 共享 Alpine base
│       ├── php/                      # PHP-FPM 相关文件
│       │   ├── Dockerfile            # PHP-FPM 镜像构建定义
│       │   └── php_version.txt       # PHP 版本锁定文件
│       └── nginx/                    # Nginx 相关文件
│           ├── Dockerfile            # Nginx 镜像构建定义
│           ├── nginx.conf            # Nginx 主配置
│           ├── conf.d/               # 站点配置目录
│           │   └── default.conf      # 默认站点配置
│           └── nginx_version.txt     # Nginx 版本锁定文件
├── deploy/                           # 部署相关文件
│   ├── docker-compose.yml            # 生产环境服务编排配置
│   ├── configs/                      # 配置文件目录
│   │   └── php.ini                   # PHP 配置文件
│   └── scripts/                      # 部署脚本目录
│       └── auto_deploy.sh            # 自动化部署脚本（一键部署）
└── html/                             # WordPress 源码
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

### 开发环境配置示例

```yaml
services:
  mariadb:
    image: mariadb:10.11.14
    container_name: wp-mariadb
    restart: unless-stopped
    networks: [wordpress-network]
    volumes: [db_data:/var/lib/mysql]
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    expose: ["3306"]

  redis:
    image: redis:8.2.2-alpine3.22
    container_name: wp-redis
    restart: unless-stopped
    networks: [wordpress-network]
    command: redis-server --appendonly yes
    volumes: [redis_data:/data]
    expose: ["6379"]

  php:
    build:
      context: ./build/Dockerfiles/php
      dockerfile: Dockerfile
    container_name: wp-php
    restart: unless-stopped
    networks: [wordpress-network]
    volumes:
      - ./html:/var/www/html
      - ./deploy/configs/php.ini:/usr/local/etc/php/php.ini:ro
    expose: ["9000"]
    depends_on: [mariadb, redis]
    environment:
      WORDPRESS_DB_HOST: mariadb:3306
      WORDPRESS_DB_USER: ${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
      WORDPRESS_REDIS_HOST: redis
      WORDPRESS_REDIS_PORT: 6379

  nginx:
    build:
      context: ./build/Dockerfiles/nginx
      dockerfile: Dockerfile
    container_name: wp-nginx
    restart: unless-stopped
    networks: [wordpress-network]
    volumes:
      - ./build/Dockerfiles/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./build/Dockerfiles/nginx/conf.d:/etc/nginx/conf.d:ro
      - ./html:/var/www/html
    ports: ["80:80"]
    depends_on: [php]

networks:
  wordpress-network:
    driver: bridge

volumes:
  db_data:
  redis_data:
```

**注意**:

- 使用环境变量（如 `${DOCKERHUB_USERNAME}`）避免硬编码。
- 默认值确保即使无 `.env` 文件也能运行。

------

## 构建共享 Alpine Base 镜像

**`Dockerfiles/base/Dockerfile`**:

```dockerfile
FROM alpine:3.22
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories && \
    apk update --no-cache && \
    rm -rf /var/cache/apk/* 2>/dev/null || true
```

------

## 构建自定义 PHP-FPM 镜像

**`Dockerfiles/php/Dockerfile`**:

```dockerfile
ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE} AS base

FROM php:8.3-fpm-alpine3.22 AS builder
ARG COMPOSER_HASH=""
RUN php -v | head -1 | cut -d' ' -f2 | cut -d'-' -f1 > /tmp/php_version || echo "8.3" > /tmp/php_version
COPY --from=base /etc/apk/repositories /etc/apk/repositories
RUN apk update --no-cache && \
    apk add --no-cache libzip-dev freetype-dev libpng-dev libjpeg-turbo-dev icu-dev libwebp-dev git zip unzip autoconf g++ libtool && \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp && \
    docker-php-ext-install -j$(nproc) pdo_mysql mysqli gd exif intl zip opcache
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    EXPECTED_HASH=$( [ -n "$COMPOSER_HASH" ] && echo "$COMPOSER_HASH" || echo "ed0feb545ba87161262f2d45a633e34f591ebb3381f2e0063c345ebea4d228dd0043083717770234ec00c5a9f9593792" ) && \
    php -r "if (hash_file('sha384', 'composer-setup.php') === '$EXPECTED_HASH') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); exit(1); }; echo PHP_EOL;" && \
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
    php -r "unlink('composer-setup.php');"
RUN rm -rf /var/cache/apk/* 2>/dev/null || true

FROM php:8.3-fpm-alpine3.22 AS final
COPY --from=base /etc/apk/repositories /etc/apk/repositories
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /tmp/php_version /tmp/php_version
RUN docker-php-ext-enable pdo_mysql mysqli gd exif intl zip opcache && \
    rm -rf /var/cache/apk/* 2>/dev/null || true
COPY ./configs/php/php.ini /usr/local/etc/php/php.ini
RUN mkdir -p /var/log/php && \
    chown -R www-data:www-data /var/log/php /var/www/html && \
    chmod -R 755 /var/log/php /var/www/html
```

**`configs/php/php.ini`**:

```ini
[PHP]
display_errors = Off
log_errors = On
error_log = /var/log/php/error.log
memory_limit = 256M
max_execution_time = 300
max_input_vars = 3000
max_input_time = 60
upload_max_filesize = 64M
post_max_size = 64M
date.timezone = "Asia/Shanghai"
[opcache]
opcache.enable=1
opcache.memory_consumption=128
opcache.max_accelerated_files=4000
opcache.revalidate_freq=2
```

------

## 构建自定义 Nginx 镜像

**`Dockerfiles/nginx/Dockerfile`**:

```dockerfile
ARG NGINX_VERSION=1.26.2
ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE} AS base
FROM nginx:${NGINX_VERSION} AS builder
RUN nginx -v 2>&1 | cut -d'/' -f2 | cut -d' ' -f1 > /tmp/nginx_version || echo "stable" > /tmp/nginx_version
COPY --from=base /etc/apk/repositories /etc/apk/repositories
RUN apk update --no-cache && apk add --no-cache vim bash curl wget
FROM nginx:${NGINX_VERSION} AS final
COPY --from=builder /tmp/nginx_version /tmp/nginx_version
COPY --from=builder /bin/bash /bin/bash
COPY --from=builder /usr/bin/vim /usr/bin/vim
COPY --from=builder /usr/bin/curl /usr/bin/curl
COPY --from=builder /usr/bin/wget /usr/bin/wget
COPY ./configs/nginx/nginx.conf /etc/nginx/nginx.conf
COPY ./configs/nginx/conf.d /etc/nginx/conf.d
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

**`configs/nginx/nginx.conf`**:

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

**`configs/nginx/conf.d/default.conf`**:

```nginx
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
    index index.php index.html index.htm;
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \.php$ {
        fastcgi_pass wp:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\.ht { deny all; }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
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

   ```bash
   WP_CONTAINER_ID=$(docker-compose ps -q wp)
   if [ -n "$WP_CONTAINER_ID" ]; then
       docker exec -it $WP_CONTAINER_ID chown -R www-data:www-data /var/www/html
   fi
   ```

2. **使用 Release 资产或生成 `.env`**:

   - 如果使用 Release 资产，直接使用下载的 `.env` 和 `docker-compose.yml`。

   - 否则运行部署脚本:

     ```bash
     chmod +x scripts/deploy.sh
     ./scripts/deploy.sh
     ```

     或手动创建 

     ```
     .env
     ```

     :

     ```
     DOCKERHUB_USERNAME=your_dockerhub_username
     PHP_VERSION=8.3.26
     NGINX_VERSION=1.27.2
     MYSQL_ROOT_PASSWORD=your_strong_root_password
     MYSQL_PASSWORD=your_strong_user_password
     ```

3. **下载 WordPress**:

   ```bash
   wget https://wordpress.org/latest.tar.gz
   tar -xvzf latest.tar.gz
   mv wordpress/* html/
   rm -rf wordpress latest.tar.gz
   ```

4. **启动服务**:

   ```bash
   docker-compose pull
   docker-compose up -d
   ```

5. **完成安装**:

   - 浏览器访问 `http://服务器IP`，按向导配置数据库。
   - 安装 "Redis Object Cache" 插件，启用缓存。

------

## 加速器配置

**`/etc/docker/daemon.json`**:

```json
{
  "registry-mirrors": ["https://mirror.ccs.tencentyun.com"]
}
sudo systemctl daemon-reload
sudo systemctl restart docker
```

------

## 总结与故障排除

- **动态版本锁定**：提取精确版本（如 `:8.3.26`），避免 `:latest`。

- **多阶段构建**：共享 base 镜像，优化大小与效率。

- **CI/CD 与 Releases**：Actions 构建、推送镜像并生成 Release 资产，生产仅需拉取或使用资产。

- **版本监控**：`scripts/check_versions.sh` 和 `version-monitor.yml` 自动检查版本并触发构建，已集成到工作流中。

- **自动化部署**：通过 `auto_deploy.sh` 脚本实现一键部署，支持创建工作目录、生成配置文件、下载 WordPress、启动服务等全流程自动化。

- 故障排除

  :

  - **镜像找不到**：检查 Actions 日志或 Release 资产，确保镜像和版本正确。
  - **版本更新**：使用 Release 的 `.env` 或运行 `deploy.sh` 更新。
  - **环境变量问题**：参考 `.env.example` 或 Release 的 `.env` 检查格式。
  - **部署脚本问题**：检查 `auto_deploy.sh` 的执行权限，确保 Docker 和 Docker Compose 已正确安装。

本指南提供了一个稳定、高效、可维护的 WordPress 生产环境，Releases 功能进一步简化部署流程。