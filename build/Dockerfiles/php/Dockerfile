# ============ 构建阶段 ============
ARG PHP_VERSION=8.3
ARG BASE_IMAGE=alpine:3.20
FROM ${BASE_IMAGE} AS base

# 动态 PHP 基础镜像
FROM php:${PHP_VERSION}-fpm-alpine AS builder

# 构建参数
ARG COMPOSER_HASH=""

# 复制 Alpine 源（从 base 镜像）
COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 安装构建依赖
RUN apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        freetype-dev \
        libpng-dev \
        libjpeg-turbo-dev \
        libwebp-dev \
        icu-dev \
        libzip-dev \
        git \
        autoconf \
        g++ \
        libtool \
        make \
    && apk add --no-cache \
        libpng \
        libjpeg-turbo \
        freetype \
        libwebp \
        icu \
        libzip \
        zip \
        unzip

# 配置并安装 PHP 扩展
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mysqli \
        gd \
        exif \
        intl \
        zip \
        opcache

# 安装 Imagick（你测试了）
RUN pecl install imagick \
    && docker-php-ext-enable imagick

# 安装 Composer（使用本地 composer_hash.txt 优先）
COPY build/Dockerfiles/php/composer_hash.txt /tmp/composer_hash.txt 2>/dev/null || true
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
    && EXPECTED_HASH=$(cat /tmp/composer_hash.txt 2>/dev/null || echo "$COMPOSER_HASH" || curl -s https://composer.github.io/installer.sig) \
    && php -r " \
        if (hash_file('sha384', 'composer-setup.php') === '$EXPECTED_HASH') { \
            echo 'Installer verified'; \
        } else { \
            echo 'Installer corrupt'; unlink('composer-setup.php'); exit(1); \
        }; echo PHP_EOL;" \
    && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
    && php -r "unlink('composer-setup.php');" \
    && rm -f /tmp/composer_hash.txt

# 写入 PHP 版本（用于标签）
RUN php -v | head -1 | awk '{print $2}' | cut -d'+' -f1 > /tmp/php_version

# 清理
RUN apk del .build-deps && rm -rf /var/cache/apk/* /tmp/*

# ============ 最终运行阶段 ============
FROM php:${PHP_VERSION}-fpm-alpine AS final

# 复制 Alpine 源
COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 安装运行时依赖（关键！gd/imagick 依赖）
RUN apk add --no-cache \
        libpng \
        libjpeg-turbo \
        freetype \
        libwebp \
        icu \
        libzip \
        imagemagick

# 从 builder 复制扩展和工具
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /tmp/php_version /tmp/php_version

# 启用扩展
RUN docker-php-ext-enable \
        pdo_mysql \
        mysqli \
        gd \
        exif \
        intl \
        zip \
        opcache \
        imagick

# 复制配置文件
COPY build/deploy_configs/php/php.ini /usr/local/etc/php/php.ini

# 创建日志目录
RUN mkdir -p /var/log/php /var/www/html \
    && touch /var/log/php/error.log \
    && chown -R www-data:www-data /var/log/php /var/www/html \
    && chmod -R 755 /var/log/php /var/www/html

# 工作目录
WORKDIR /var/www/html

# 暴露端口
EXPOSE 9000

# 健康检查（可选）
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD php-fpm -t || exit 1