# WordPress + Docker Compose 多阶段构建与生产环境最佳实践指南 (GitHub Actions 自动化版)

本文档旨在提供一个现代化、稳健、安全且易于团队协作管理的 WordPress 生产环境部署方案。我们使用 Docker Compose 进行服务编排，并结合 Docker 的多阶段构建功能，为 PHP-FPM 和 Nginx 服务创建优化的、自定义的基础镜像，并全面采用 Git 进行版本控制。

**新增：GitHub Actions 自动化构建**  
为了实现 CI/CD 自动化，我们将构建过程集成到 GitHub Actions 中。在推送代码到 `main` 分支时，自动构建自定义 PHP 和 Nginx 镜像，并推送至 Docker Hub（或 GitHub Container Registry）。这确保了镜像的一致性和可重复性，减少手动构建的错误。MariaDB 和 Redis 继续使用官方固定版本镜像，无需自定义构建。

> **目标：** 构建一个现代化、可扩展、安全且自动化的 WordPress 生产部署体系，适配多架构，兼顾本地开发、CI/CD 和线上部署。

**更新内容概览（根据讨论）**  
- ✅ 引入 **build-arg 参数化构建源**：支持构建时动态切换国内 / 官方源；  
- ✅ 明确 **GitHub Actions 仅用于构建**，部署阶段只需拉取镜像；  
- ✅ 引导本地构建时可使用国内源加速；  
- ✅ 拆分构建与部署职责，保证构建镜像的可复用性与生产稳定性；  
- ✅ **动态版本标签提取**：为避免基础镜像标签 "not found" 错误，使用 minor 版本 + Alpine 3.20 的 latest 拉取，构建中提取实际 patch 版本，推送时使用精确标签，确保基于现代 Alpine 3.20 的确定性锁定。

## 核心理念：工程化基石

在开始之前，理解本方案背后的设计哲学至关重要。这关乎于 **“确定性”** 与 **“协作性”** 之间的权衡。

1.  **彻底避免 `:latest` 的不确定性**：  
    在生产环境中，`:latest` 是不稳定性的代名词。`nginx:latest` 可能今天指向 `1.27.2`，下周就变成 `1.28.0`。这种微小的“漂移”足以引发线上故障。**最佳实践是：永远在生产环境中使用具体的版本号。** 为此，我们引入动态提取机制：在构建时使用 minor 版本 latest 拉取基础镜像，提取实际版本后推送精确标签。

2.  **Alpine：现代与高效的基石**：  
    Alpine Linux 因其极致的小体积和高安全性，成为容器化部署的首选。使用统一的 Alpine 版本（如 `alpine3.20`）作为所有服务的基础，可以最大限度地减少底层环境差异带来的兼容性问题，并受益于最新的安全补丁。

3.  **国内源：构建速度的催化剂**：  
    将 Docker 镜像的包管理源切换到国内镜像源（如阿里云），可以显著加快依赖下载速度，优化构建流程。

4.  **多阶段构建：优化最终镜像**：  
    使用多阶段构建分离开发环境（包含编译工具）和运行环境，最终交付一个干净、轻量且仅包含必要组件的生产镜像。

5.  **配置即代码 (Infrastructure as Code)**：  
    **所有配置文件（`docker-compose.yml`, `nginx.conf`, `php.ini`）都必须纳入版本控制系统（如 Git）**。这是确保环境一致性、可追溯性和团队协作的根本。任何环境变更都应通过代码审查流程（Pull Request）完成。

6.  **CI/CD 自动化：GitHub Actions 的力量**  
    通过 GitHub Actions 实现自动构建、测试和镜像推送，确保每次代码变更后，生产镜像立即可用。这与 Git 工作流无缝集成，支持团队协作。动态标签提取进一步提升了构建鲁棒性，避免手动维护标签的痛点。

---

## 准备工作：项目目录结构

一个清晰、结构化的目录是项目可维护性的前提。我们推荐如下结构，并在此基础上进行 Git 初始化。

```
wordpress-project/
├── .git/                                  # Git 仓库 (由 git init 生成)
├── .gitignore                             # Git 忽略规则 (至关重要)
├── README.md                              # 项目说明文档 (强烈建议创建)
├── docker-compose.yml                     # 服务编排核心定义
├── .github/                               # GitHub Actions 工作流目录
│   └── workflows/
│       └── build-and-push.yml             # 自动化构建工作流
├── configs/                               # 所有服务的配置文件统一存放
│   ├── nginx/
│   │   ├── nginx.conf                     # Nginx 主配置
│   │   └── conf.d/
│   │       └── default.conf              # WordPress 站点配置
│   └── php/
│       └── php.ini                        # 自定义 PHP 配置
├── Dockerfiles/                           # 各服务的 Dockerfile 目录
│   ├── php/
│   │   └── Dockerfile
│   └── nginx/
│       └── Dockerfile
└── html/                                  # WordPress 源码将放置在这里
```

### **重要步骤：初始化 Git 并创建 .gitignore**

1.  **初始化仓库**：
    ```bash
    # 在 wordpress-project/ 目录下执行
    git init
    ```

2.  **创建 .gitignore 文件**：
    这个文件是防止“配置漂移”的第一道防线，它明确告诉 Git 什么应该被忽略。

    ```bash
    # 在 wordpress-project/ 目录下执行
    cat >> .gitignore << EOF
    # --- Docker 相关 ---
    # 忽略所有容器、镜像、网络、数据卷这些“环境”产物
    .dockerignore
    *.log
    
    # --- WordPress 相关 ---
    # WordPress 自动生成的核心配置文件
    html/wp-config.php
    # 忽略 wp-content 下的插件和主题，除非它们是项目的一部分
    # html/wp-content/plugins/
    # html/wp-content/themes/
    # html/wp-content/uploads/ (如果上传内容需要备份，可以通过卷挂载并单独备份)
    
    # --- 敏感信息 ---
    # 绝对不要将密码、API Key 等敏感信息提交到代码库！
    .env
    *.key
    *.pem
    
    # --- IDE 文件 ---
    .vscode/
    .idea/
    *.swp
    EOF
    ```

3.  **初始提交**：
    ```bash
    # 添加所有文件并提交，建立“基础线”
    git add .
    git commit -m "feat: 初始化 WordPress 项目，包含基础 Docker 配置、目录结构和 Git 初始化"
    ```

4.  **配置 GitHub Secrets（用于自动化构建）**：
    - 在 GitHub 仓库设置中，添加 Secrets：
      - `DOCKERHUB_USERNAME`：你的 Docker Hub 用户名。
      - `DOCKERHUB_TOKEN`：Docker Hub 访问令牌（在 Docker Hub > Account Settings > Security 中生成）。
    - 这确保了镜像推送的安全性。

---

## 步骤一：创建 Docker Compose 配置 (`docker-compose.yml`)

这是整个架构的“剧本”，定义了各个服务如何协同工作。  
**注意**：在生产环境中，将 `build` 部分替换为 `image` 以使用从 Docker Hub 拉取的自定义镜像。为了避免硬编码用户名，可以使用环境变量 `${DOCKERHUB_USERNAME}`，例如 `${DOCKERHUB_USERNAME:-chisenin}/wordpress-php:8.3` 和 `${DOCKERHUB_USERNAME:-chisenin}/wordpress-nginx:1.27`（动态提取的实际 patch 版本）。

**文件: `wordpress-project/docker-compose.yml`**

```yaml
version: '3.8'

services:
  # --- MariaDB 数据库服务 ---
  db:
    image: mariadb:10.11.6 # 使用固定的稳定版本号
    container_name: wp_db
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      - db_data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: your_strong_root_password
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wp_user
      MYSQL_PASSWORD: your_strong_user_password
    expose:
      - "3306"

  # --- Redis 缓存服务 ---
  redis:
    image: redis:7.2.4-alpine3.20 # 使用固定版本号，并注明基础系统版本
    container_name: wp_redis
    restart: unless-stopped
    networks:
      - app-network
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    expose:
      - "6379"

  # --- PHP-FPM 服务 ---
  wp:
    image: ${DOCKERHUB_USERNAME:-chisenin}/wordpress-php:8.3  # <--- 从 Docker Hub 拉取自定义镜像（使用环境变量，默认值为chisenin；实际标签为动态提取的 8.3.x）
    # build:  # 开发时启用
    #   context: ./Dockerfiles/php
    #   dockerfile: Dockerfile
    container_name: wp_fpm
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      # 注意：宿主机 html 目录挂载到容器内 /var/www/html
      - ../html:/var/www/html
    expose:
      - "9000"
    depends_on:
      - db
      - redis
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_USER: wp_user
      WORDPRESS_DB_PASSWORD: your_strong_user_password
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_REDIS_HOST: redis
      WORDPRESS_REDIS_PORT: 6379

  # --- Nginx 服务 ---
  nginx:
    image: ${DOCKERHUB_USERNAME:-chisenin}/wordpress-nginx:1.27  # <--- 从 Docker Hub 拉取自定义镜像（使用环境变量，默认值为chisenin；实际标签为动态提取的 1.27.x）
    # build:  # 开发时启用
    #   context: ./Dockerfiles/nginx
    #   dockerfile: Dockerfile
    container_name: wp_nginx
    restart: unless-stopped
    networks:
      - app-network
    volumes:
      # 挂载自定义配置文件，使用统一的 configs 目录
      - ./configs/nginx/nginx.conf:/etc/nginx/nginx.conf
      - ./configs/nginx/conf.d:/etc/nginx/conf.d
      - ../html:/var/www/html
    ports:
      - "80:80"
    depends_on:
      - wp

networks:
  app-network:
    driver: bridge

volumes:
  db_data:
  redis_data:
```

## 步骤二：构建自定义 PHP-FPM 镜像

**文件: `wordpress-project/Dockerfiles/php/Dockerfile`**

```dockerfile
FROM php:8.3-fpm-alpine3.20 AS builder

# 定义 ARG 以支持动态哈希传入（默认为空，回退时可硬编码）
ARG COMPOSER_HASH=""

# 提取实际 PHP 版本（写入 /tmp/php_version，用于动态标签）
RUN php -v | head -1 | cut -d' ' -f2 | cut -d'-' -f1 > /tmp/php_version || echo "8.3" > /tmp/php_version

ARG USE_CN_MIRROR=false

# 配置 Alpine 源
RUN if [ "$USE_CN_MIRROR" = "true" ]; then 
      echo "http://mirrors.aliyun.com/alpine/v3.20/main/" > /etc/apk/repositories && 
      echo "http://mirrors.aliyun.com/alpine/v3.20/community/" >> /etc/apk/repositories ; 
    else 
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && 
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories ; 
    fi

# 更新包索引
RUN apk update --no-cache

# 安装依赖和编译工具
RUN apk add --no-cache \
        libzip-dev freetype-dev libpng-dev libjpeg-turbo-dev icu-dev libwebp-dev git \
        zip unzip autoconf g++ libtool

# 配置 GD 扩展
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp-dir=/usr

# 安装 PHP 扩展
RUN docker-php-ext-install -j$(nproc) pdo_mysql mysqli gd exif intl zip opcache

# 安装 Composer（使用动态 COMPOSER_HASH 参数验证安装器；如果为空，使用硬编码回退）
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    EXPECTED_HASH=$( [ -n "$COMPOSER_HASH" ] && echo "$COMPOSER_HASH" || echo "ed0feb545ba87161262f2d45a633e34f591ebb3381f2e0063c345ebea4d228dd0043083717770234ec00c5a9f9593792" ) && \
    php -r "if (hash_file('sha384', 'composer-setup.php') === getenv('EXPECTED_HASH')) { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); exit(1); }; echo PHP_EOL;" && \
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
    php -r "unlink('composer-setup.php');"

# 清理缓存（增强鲁棒性，忽略空目录错误）
RUN rm -rf /var/cache/apk/* 2>/dev/null || true

# --- 最终运行阶段 ---
FROM php:8.3-fpm-alpine3.20 AS final

# 从 builder 阶段复制编译好的扩展、工具和版本文件
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /tmp/php_version /tmp/php_version

RUN docker-php-ext-enable pdo_mysql mysqli gd exif intl zip opcache && rm -rf /var/cache/apk/* 2>/dev/null || true

WORKDIR /var/www/html
```

**重要更新说明**：

1. **基础镜像更新**：切换到 `php:8.3-fpm-alpine3.20`（支持 Alpine 3.20 的最新稳定 PHP 系列），避免旧版本标签不匹配问题。

2. **Alpine 源版本更新**：统一为 `v3.20`，确保包兼容性和安全补丁。

3. **动态版本提取**：添加 `RUN` 指令提取实际 PHP 版本（e.g., 8.3.14），存储在 `/tmp/php_version`，供 Actions 后续标签使用。这实现了“拉取 latest minor，推送精确 patch”的机制。

4. **构建指令优化**：
   - 将原单个超长 RUN 命令链拆分为独立指令，便于隔离和调试构建失败点
   - 单独执行 `apk update` 命令，确保包索引是最新的
   - 优化 GD 扩展配置，添加 `--with-webp-dir=/usr` 参数以确保 webp 支持正常工作

5. **Composer 安装改进**：采用 PHP copy+哈希验证的 2025 年推荐方法，增强安装安全性和可靠性，避免因网络或缓存问题导致的安装失败。哈希对应 v2.8.12（定期验证）。

6. **CI/CD 友好**：这些变更确保了 GitHub Actions 等 CI/CD 环境下的构建稳定性，避免了常见的 exit code: 1 构建错误。动态提取减少手动标签维护负担。

7. **清理命令鲁棒性**：所有清理缓存的命令都添加了 `-rf`、`2>/dev/null` 和 `|| true` 参数，确保在缓存目录为空或不存在的情况下，命令不会失败退出，提高构建的稳定性和可靠性。

8. **动态 Composer 哈希获取优化**：集成 GitHub Actions 动态提取最新哈希，避免硬编码；添加验证回退机制，确保构建在网络波动下稳定。当前哈希（2025-10-11）：ed0feb545ba87161262f2d45a633e34f591ebb3381f2e0063c345ebea4d228dd0043083717770234ec00c5a9f9593792。

**文件: `wordpress-project/configs/php/php.ini`**

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
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=2
opcache.fast_shutdown=1
```

## 步骤三：构建自定义 Nginx 镜像

**文件: `wordpress-project/Dockerfiles/nginx/Dockerfile`**

```dockerfile
FROM nginx:1.27-alpine3.20

# 提取实际 Nginx 版本（写入 /tmp/nginx_version，用于动态标签）
RUN nginx -v 2>&1 | cut -d'/' -f2 | cut -d' ' -f1 > /tmp/nginx_version || echo "1.27" > /tmp/nginx_version

ARG USE_CN_MIRROR=false

# 配置 Alpine 源
RUN if [ "$USE_CN_MIRROR" = "true" ]; then \
      echo "http://mirrors.aliyun.com/alpine/v3.20/main/" > /etc/apk/repositories && \
      echo "http://mirrors.aliyun.com/alpine/v3.20/community/" >> /etc/apk/repositories ; \
    else \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories ; \
    fi

# 更新包索引
RUN apk update --no-cache

# 安装调试工具
RUN apk add --no-cache vim bash curl wget

COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d /etc/nginx/conf.d

RUN chown -R www-data:www-data /var/cache/nginx /var/log/nginx

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

**重要更新说明**：
- **基础镜像更新**：切换到 `nginx:1.27-alpine3.20`（支持 Alpine 3.20 的最新稳定 Nginx 系列）。
- **Alpine 源版本**：统一为 `v3.20`。
- **动态版本提取**：提取实际版本（e.g., 1.27.2），存储在 `/tmp/nginx_version`。

**文件: `wordpress-project/configs/nginx/nginx.conf`**

```nginx
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    keepalive_timeout  65;

    include /etc/nginx/conf.d/*.conf;
}
```

**文件: `wordpress-project/configs/nginx/conf.d/default.conf`**

```nginx
server {
    listen 80;
    server_name localhost;

    root /var/www/html;
    index index.php index.html index.htm;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        fastcgi_pass wp:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

## 步骤四：GitHub Actions 自动化构建工作流

**文件: `wordpress-project/.github/workflows/build-and-push.yml`**  
这个工作流在推送至 `main` 分支时触发：检出代码、登录 Docker Hub、先构建临时镜像、提取实际版本、重新标签并推送。为了增强安全性，我们使用了 GitHub Secrets 中的 `${{ secrets.DOCKERHUB_USERNAME }}` 变量来动态生成镜像标签，避免硬编码用户名。支持多平台构建（linux/amd64, linux/arm64）以兼容不同环境。

```yaml
name: Build and Push Docker Images

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to Docker Hub
      uses: docker/login-action@v3
      with:
        username: ${{ secrets.DOCKERHUB_USERNAME }}
        password: ${{ secrets.DOCKERHUB_TOKEN }}

    - name: Fetch latest Composer hash
      id: composer-hash
      run: |
        echo "::group::Composer Hash Verification"
        echo "Fetching latest Composer installer hash..."
        HASH=$(curl -s https://composer.github.io/installer.sig)
        if [ -z "$HASH" ] || [ ${#HASH} -ne 96 ]; then 
          echo "Error: Invalid Composer hash (length: ${#HASH})"
          exit 1
        fi
        echo "Fetched Composer hash: $HASH"
        echo "composer_hash=${HASH}" >> $GITHUB_OUTPUT
        echo "::endgroup::"

    - name: Build and push PHP temp (multi-platform)
      id: php-build
      uses: docker/build-push-action@v6
      with:
        context: ./Dockerfiles/php
        file: ./Dockerfiles/php/Dockerfile
        push: true
        tags: ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:temp
        platforms: linux/amd64,linux/arm64
        build-args: |
          USE_CN_MIRROR=false
          COMPOSER_HASH=${{ steps.composer-hash.outputs.composer_hash }}
        cache-from: type=gha
        cache-to: type=gha,mode=max

    - name: Pull amd64 variant and extract PHP version
      run: |
        docker pull --platform linux/amd64 ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:temp
        ACTUAL_PHP_VERSION=$(docker run --rm --platform linux/amd64 ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:temp cat /tmp/php_version)
        docker tag ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:temp ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:${ACTUAL_PHP_VERSION}
        docker tag ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:temp ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:latest
        docker push ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:${ACTUAL_PHP_VERSION}
        docker push ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-php:latest
        echo "php_version=${ACTUAL_PHP_VERSION}" >> $GITHUB_OUTPUT

    - name: Verify Nginx base image exists
      run: docker pull nginx:1.27-alpine3.20

    - name: Build and push Nginx temp (multi-platform)
      id: nginx-build
      uses: docker/build-push-action@v6
      with:
        context: ./Dockerfiles/nginx
        file: ./Dockerfiles/nginx/Dockerfile
        push: true
        tags: ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:temp
        platforms: linux/amd64,linux/arm64
        build-args: |
          USE_CN_MIRROR=false
        cache-from: type=gha
        cache-to: type=gha,mode=max

    - name: Pull amd64 variant and extract Nginx version
      run: |
        docker pull --platform linux/amd64 ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:temp
        ACTUAL_NGINX_VERSION=$(docker run --rm --platform linux/amd64 ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:temp cat /tmp/nginx_version)
        docker tag ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:temp ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:${ACTUAL_NGINX_VERSION}
        docker tag ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:temp ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:latest
        docker push ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:${ACTUAL_NGINX_VERSION}
        docker push ${{ secrets.DOCKERHUB_USERNAME }}/wordpress-nginx:latest
        echo "nginx_version=${ACTUAL_NGINX_VERSION}" >> $GITHUB_OUTPUT

    - name: Run docker-compose for validation (optional)
      run: |
        docker-compose up -d --build
        sleep 10
        curl -f http://localhost || exit 1
        docker-compose down
```

**说明**：
- **触发器**：推送或 PR 到 `main` 分支。
- **构建优化**：使用 Buildx 支持多阶段和多平台；缓存加速后续构建。动态提取步骤确保推送精确版本标签（e.g., :8.3.14），而拉取使用 minor latest 避免 not found。
- **验证**：可选运行 docker-compose 测试连通性（本地模拟）。
- **标签**：动态精确版本标签 + `latest`（仅用于便利，非生产推荐）。
- **扩展**：若需部署到服务器，可添加部署步骤（如使用 SSH 拉取镜像并重启服务）。

## 步骤五：Git 工作流与变更管理 (核心实践)

这是确保团队稳定协作、环境可控的关键。

1.  **创建和管理分支**：
    *   **`main` 分支**：永远保持稳定、可部署的状态。
    *   **功能分支**：每次开发新功能或修复 Bug，都从 `main` 分支创建一个新分支。命名示例：`feat/nginx-gzip`、`fix/php-upload-size`。

2.  **编写有意义的 Commit Message**：
    遵循 **Conventional Commits** 规范，让 Git 日志清晰可读。
    *   `feat`: 新功能
    *   `fix`: 修复 Bug
    *   `docs`: 文档变更
    *   `style`: 代码格式化
    *   `refactor`: 重构
    *   `chore`: 构建/工具变动
    *   **示例**:
        ```bash
        git add configs/nginx/conf.d/default.conf
        git commit -m "feat(nginx): 开启 Gzip 压缩以提高页面加载速度"
        ```

3.  **通过 Pull Request (PR) 审查并合并**：
    *   开发完成，推送功能分支到远程仓库（如 GitHub）。
    *   在代码托管平台创建一个 Pull Request，目标分支是 `main`。
    *   在 PR 描述中说明修改内容和原因，邀请团队成员进行**代码审查**。
    *   审查通过后，将 PR 合并到 `main` 分支。这个过程会被记录在 Git 历史中，并自动触发 GitHub Actions 构建新镜像（包括动态标签提取）。

4.  **部署**：
    当 `main` 分支更新后（镜像已推送），部署到任何环境都变得简单、可重复：
    ```bash
    # 在目标服务器上，拉取最新镜像
    docker-compose pull
    docker-compose up -d
    ```

## 步骤六：部署与验证

1.  **下载 WordPress**:
    ```bash
    # 在 wordpress-project/ 目录下执行
    wget https://wordpress.org/latest.tar.gz
    tar -xvzf latest.tar.gz
    mv html/* html/
    rm -rf html/wp-content/ # 移除默认内容，便于后续管理
    ```

2.  **构建并启动服务**（开发时）:
    ```bash
    docker-compose up -d --build
    ```

3.  **生产部署**：使用 `docker-compose pull && docker-compose up -d` 拉取自动化构建的镜像（精确版本标签）。

4.  **完成安装**:
    浏览器访问 `http://你的服务器IP`，按照向导完成数据库配置。

5.  **配置 Redis 缓存**:
    在 WordPress 后台安装并启用 "Redis Object Cache" 插件，它会自动连接到容器。

## 🧪 本地构建（使用国内源）

```bash
# PHP 镜像构建
docker build \
  -f ./Dockerfiles/php/Dockerfile \
  --build-arg USE_CN_MIRROR=true \
  -t ${DOCKERHUB_USERNAME:-chisenin}/wordpress-php:dev \
  ./Dockerfiles/php

# Nginx 镜像构建
docker build \
  -f ./Dockerfiles/nginx/Dockerfile \
  --build-arg USE_CN_MIRROR=true \
  -t ${DOCKERHUB_USERNAME:-chisenin}/wordpress-nginx:dev \
  ./Dockerfiles/nginx
```

## 🚀 部署阶段（无构建，仅拉取）

```bash
docker-compose pull    # 拉取 GitHub Actions 推送的镜像
docker-compose up -d   # 启动服务
```

## 🧩 加速器配置建议（生产环境）

**文件：`/etc/docker/daemon.json`**

```json
{
  "registry-mirrors": ["https://mirror.ccs.tencentyun.com"]
}
sudo systemctl daemon-reexec
sudo systemctl restart docker
```

---

## 总结

这份 GitHub Actions 自动化版指南不仅提供了一个技术上先进的 WordPress 部署方案，更重要的是，它融入了 **DevOps 的工程化思维**。

通过：
*   **动态版本锁定** 消除了环境不确定性，同时基于 Alpine 3.20 受益于现代基础。
*   **多阶段构建** 优化了镜像大小和安全。
*   **配置文件外部化与 Git 管理** 确保了环境的一致性和变更的可追溯性。
*   **GitHub Actions 自动化** 实现了无摩擦的 CI/CD 管道，每次 PR 合并即构建、提取版本并推送精确镜像。

遵循此指南，您将能够构建一个**稳定、高效、可维护、团队友好**的 WordPress 生产环境，从容应对未来的业务增长和团队协作挑战。动态机制特别解决了标签不匹配的常见痛点，确保构建鲁棒。

| 阶段           | 是否构建 | 是否用国内源   | 镜像处理方式                   |
| -------------- | -------- | -------------- | ------------------------------ |
| GitHub Actions | ✅ 是     | ❌ 否（官方源） | ✅ 构建、动态提取版本并推送镜像 |
| 本地开发       | ✅ 可选   | ✅ 推荐使用     | 构建 dev 标签镜像              |
| 生产部署服务器 | ❌ 不构建 | ✅ 拉取加速     | 仅 `pull + up` 操作            |
| </DOCUMENT>    |          |                |                                |

|      |      |      |      |
| ---- | ---- | ---- | ---- |
|      |      |      |      |
|      |      |      |      |
|      |      |      |      |
