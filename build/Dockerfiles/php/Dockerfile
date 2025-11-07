# ============ 全局参数 ============
ARG PHP_VERSION=8.3
ARG BASE_IMAGE=alpine:3.20

# ============ 基础镜像 ============
FROM ${BASE_IMAGE} AS base

# ============ 构建阶段 ============
FROM php:${PHP_VERSION}-fpm-alpine AS php-builder

# 复制 Alpine 源
COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 安装构建依赖
RUN apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        freetype-dev libpng-dev libjpeg-turbo-dev libwebp-dev \
        icu-dev libzip-dev git autoconf g++ libtool make \
    && apk add --no-cache \
        libpng libjpeg-turbo freetype libwebp icu libzip zip unzip

# 配置 GD
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) pdo_mysql mysqli gd exif intl zip opcache

# 安装 Imagick
RUN pecl install imagick && docker-php-ext-enable imagick

# 安装 Composer（优先本地 hash）
COPY build/Dockerfiles/php/composer_hash.txt /tmp/composer_hash.txt 2>/dev/null || true
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
    && HASH=$(cat /tmp/composer_hash.txt 2>/dev/null || curl -s https://composer.github.io/installer.sig) \
    && php -r "if (hash_file('sha384', 'composer-setup.php') !== '$HASH') { echo 'ERROR'; exit 1; }" \
    && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
    && rm -f composer-setup.php /tmp/composer_hash.txt

# 写入版本
RUN php -v | head -1 | awk '{print $2}' | cut -d'+' -f1 > /tmp/php_version

# 清理
RUN apk del .build-deps && rm -rf /var/cache/apk/*

# ============ 最终阶段 ============
FROM php:${PHP_VERSION}-fpm-alpine AS final

COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 运行时依赖
RUN apk add --no-cache \
        libpng libjpeg-turbo freetype libwebp icu libzip imagemagick

# 复制扩展和工具
COPY --from=php-builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=php-builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=php-builder /tmp/php_version /tmp/php_version

# 启用扩展
RUN docker-php-ext-enable pdo_mysql mysqli gd exif intl zip opcache imagick

# 配置文件
COPY build/deploy_configs/php/php.ini /usr/local/etc/php/php.ini

# 日志与权限
RUN mkdir -p /var/log/php /var/www/html \
    && touch /var/log/php/error.log \
    && chown -R www-data:www-data /var/log/php /var/www/html \
    && chmod -R 755 /var/log/php /var/www/html

WORKDIR /var/www/html
EXPOSE 9000