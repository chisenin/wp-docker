# --- 构建阶段 ---
FROM php:8.3-fpm-alpine3.20 AS builder

# 定义 ARG
ARG COMPOSER_HASH=""
ARG USE_CN_MIRROR=false

# 配置 Alpine 源
RUN if [ "$USE_CN_MIRROR" = "true" ]; then \
      echo "http://mirrors.aliyun.com/alpine/v3.20/main/" > /etc/apk/repositories && \
      echo "http://mirrors.aliyun.com/alpine/v3.20/community/" >> /etc/apk/repositories ; \
    else \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories ; \
    fi

# 更新包索引并安装依赖（包括Composer）
RUN apk update --no-cache && \
    apk add --no-cache \
        libzip-dev freetype-dev libpng-dev libjpeg-turbo-dev icu-dev libwebp-dev git \
        zip unzip autoconf g++ libtool composer

# 配置 GD 扩展
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp

# 安装 PHP 扩展
RUN docker-php-ext-install -j$(nproc) pdo_mysql mysqli gd exif intl zip opcache

# 验证 Composer 安装
RUN composer --version && \
    which composer && \
    ls -l /usr/local/bin/composer || { echo "Composer not found"; exit 1; }

# 清理缓存
RUN rm -rf /var/cache/apk/* 2>/dev/null || true

# 提取 PHP 版本
RUN php -v | head -1 | cut -d' ' -f2 | cut -d'-' -f1 > /tmp/php_version || echo "8.3" > /tmp/php_version

# --- 最终运行阶段 ---
FROM php:8.3-fpm-alpine3.20 AS final

# 复制扩展和 Composer
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /tmp/php_version /tmp/php_version

# 启用扩展并验证 Composer
RUN docker-php-ext-enable pdo_mysql mysqli gd exif intl zip opcache && \
    composer --version && \
    rm -rf /var/cache/apk/* 2>/dev/null || true

WORKDIR /var/www/html