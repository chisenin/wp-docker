# --- 构建阶段 ---
FROM php:8.2.12-fpm-alpine AS builder

ARG USE_CN_MIRROR=false

RUN if [ "$USE_CN_MIRROR" = "true" ]; then \
      echo "http://mirrors.aliyun.com/alpine/v3.18/main/" > /etc/apk/repositories && \
      echo "http://mirrors.aliyun.com/alpine/v3.18/community/" >> /etc/apk/repositories ; \
    else \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.18/main" > /etc/apk/repositories && \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.18/community" >> /etc/apk/repositories ; \
    fi && apk update --no-cache

# 安装依赖和编译工具
RUN apk add --no-cache \
        libzip-dev freetype-dev libpng-dev libjpeg-turbo-dev icu-dev libwebp-dev git \
        zip unzip autoconf g++ libtool \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) pdo_mysql mysqli gd exif intl zip opcache \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && rm -r /var/cache/apk/*

# --- 最终运行阶段 ---
FROM php:8.2.12-fpm-alpine AS final

# 从 builder 阶段复制编译好的扩展和工具
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer

RUN docker-php-ext-enable pdo_mysql mysqli gd exif intl zip opcache && rm -r /var/cache/apk/*

WORKDIR /var/www/html