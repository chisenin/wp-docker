# --- 构建阶段 ---
# 使用ARG参数支持动态传入base镜像地址，默认为alpine:3.22作为回退
ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE} AS base

FROM php:8.3-fpm-alpine3.22 AS builder

# 定义 ARG 以支持动态哈希传入（默认为空，回退时硬编码）
ARG COMPOSER_HASH=""

# 提取实际 PHP 版本（写入 /tmp/php_version，用于动态标签）
RUN php -v | head -1 | cut -d' ' -f2 | cut -d'-' -f1 > /tmp/php_version || echo "8.3" > /tmp/php_version

COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 更新包索引
RUN apk update --no-cache

# 安装依赖和编译工具
RUN apk add --no-cache \
        libzip-dev freetype-dev libpng-dev libjpeg-turbo-dev icu-dev libwebp-dev git \
        zip unzip autoconf g++ libtool

# 配置 GD 扩展
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp

# 安装 PHP 扩展
RUN docker-php-ext-install -j$(nproc) pdo_mysql mysqli gd exif intl zip opcache

# 安装 Composer（使用动态 COMPOSER_HASH 参数验证安装器；如果为空，使用硬编码回退）
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    EXPECTED_HASH=$( [ -n "$COMPOSER_HASH" ] && echo "$COMPOSER_HASH" || curl -s https://composer.github.io/installer.sig ) && \
    php -r "if (hash_file('sha384', 'composer-setup.php') === '$EXPECTED_HASH') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); exit(1); }; echo PHP_EOL;" && \
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
    php -r "unlink('composer-setup.php');"

# 清理缓存（增强鲁棒性，忽略空目录错误）
RUN rm -rf /var/cache/apk/* 2>/dev/null || true

# --- 最终运行阶段 ---
FROM php:8.3-fpm-alpine3.22 AS final

COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 从 builder 阶段复制编译好的扩展、工具和版本文件
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /tmp/php_version /tmp/php_version

RUN docker-php-ext-enable pdo_mysql mysqli gd exif intl zip opcache && rm -rf /var/cache/apk/* 2>/dev/null || true

COPY build/deploy_configs/php/php.ini /usr/local/etc/php/php.ini

# 创建日志目录并设置权限
RUN mkdir -p /var/log/php && \
    touch /var/log/php/error.log && \
    chown -R www-data:www-data /var/log/php /var/www/html && \
    chmod -R 755 /var/log/php /var/www/html

WORKDIR /var/www/html