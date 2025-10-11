# --- 构建阶段 ---
FROM php:8.3-fpm-alpine3.20 AS builder

# 定义 ARG
ARG COMPOSER_HASH=""
ARG USE_CN_MIRROR=false

# 配置 Alpine 源
RUN set -eux; \
    if [ "$USE_CN_MIRROR" = "true" ]; then \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories ; \
    else \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories ; \
    fi

# 更新包索引并安装依赖
RUN set -eux; \
    apk update --no-cache && \
    apk add --no-cache \
        libzip-dev freetype-dev libpng-dev libjpeg-turbo-dev icu-dev libwebp-dev git \
        zip unzip autoconf g++ libtool

# 手动安装 Composer（作为更可靠的替代方案）
RUN set -eux; \
    wget -O composer-setup.php https://getcomposer.org/installer && \
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
    rm composer-setup.php

# 配置 GD 扩展
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp

# 安装 PHP 扩展
RUN set -eux; \
    docker-php-ext-install -j$(nproc) pdo_mysql mysqli gd exif intl zip opcache

# 分离验证命令，逐一检查 Composer 安装
RUN set -eux; \
    echo "验证 Composer 版本..." && \
    composer --version || { echo "Composer version check failed"; exit 1; }

RUN set -eux; \
    echo "检查 Composer 路径..." && \
    which composer || { echo "Composer not found in PATH"; exit 1; }

RUN set -eux; \
    echo "检查 Composer 二进制文件..." && \
    ls -l /usr/local/bin/composer || { echo "Composer binary not found"; exit 1; }

# 确保 Composer 具有可执行权限
RUN set -eux; \
    chmod +x /usr/local/bin/composer

# 清理缓存
RUN set -eux; \
    rm -rf /var/cache/apk/* 2>/dev/null || true

# 提取 PHP 版本
RUN set -eux; \
    php -v | head -1 | cut -d' ' -f2 | cut -d'-' -f1 > /tmp/php_version || echo "8.3" > /tmp/php_version

# --- 最终运行阶段 ---
FROM php:8.3-fpm-alpine3.20 AS final

# 复制扩展和 Composer
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /tmp/php_version /tmp/php_version

# 启用扩展
RUN set -eux; \
    docker-php-ext-enable pdo_mysql mysqli gd exif intl zip opcache

# 在 final 阶段分离验证 Composer
RUN set -eux; \
    echo "Final stage - 验证 Composer 版本..." && \
    composer --version || { echo "Composer version check failed in final stage"; exit 1; }

RUN set -eux; \
    echo "Final stage - 检查 Composer 路径..." && \
    which composer || { echo "Composer not found in PATH in final stage"; exit 1; }

RUN set -eux; \
    echo "Final stage - 检查 Composer 二进制文件..." && \
    ls -l /usr/local/bin/composer || { echo "Composer binary not found in final stage"; exit 1; }

# 确保 final 阶段的 Composer 具有可执行权限
RUN set -eux; \
    chmod +x /usr/local/bin/composer

# 清理缓存
RUN set -eux; \
    rm -rf /var/cache/apk/* 2>/dev/null || true

WORKDIR /var/www/html