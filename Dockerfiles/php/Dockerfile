# --- 构建阶段 ---
FROM php:8.3-fpm-alpine3.20 AS builder

# 提取实际 PHP 版本（写入 /tmp/php_version，用于动态标签）
RUN php -v | head -1 | cut -d' ' -f2 | cut -d'-' -f1 > /tmp/php_version || echo "8.3" > /tmp/php_version

ARG USE_CN_MIRROR=false
ARG COMPOSER_HASH

# 配置 Alpine 源
RUN if [ "$USE_CN_MIRROR" = "true" ]; then \
      echo "http://mirrors.aliyun.com/alpine/v3.20/main/" > /etc/apk/repositories && \
      echo "http://mirrors.aliyun.com/alpine/v3.20/community/" >> /etc/apk/repositories ; \
    else \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories ; \
    fi && apk update --no-cache

# 拆分：独立安装依赖（添加 update 以防缓存过期）
RUN apk update --no-cache && \
    apk add --no-cache \
        libzip-dev freetype-dev libpng-dev libjpeg-turbo-dev icu-dev libwebp-dev git \
        zip unzip autoconf g++ libtool

# 拆分：配置 GD（添加 --with-webp-dir=/usr 以明确路径，防 configure 失败）
RUN docker-php-ext-configure gd \
        --with-freetype --with-jpeg --with-webp=/usr

# 拆分：安装 PHP 扩展
RUN docker-php-ext-install -j$(nproc) pdo_mysql mysqli gd exif intl zip opcache

# 拆分：安装 Composer（使用传入的 COMPOSER_HASH 参数验证安装器，无需手动更新哈希）
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    php -r "if (hash_file('sha384', 'composer-setup.php') === getenv('COMPOSER_HASH')) { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); exit(1); }; echo PHP_EOL;" && \
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
    php -r "unlink('composer-setup.php');"

# 拆分：清理（可选，但保持；添加错误忽略以处理空目录）
RUN rm -rf /var/cache/apk/* 2>/dev/null || true

# --- 最终运行阶段 ---
FROM php:8.3-fpm-alpine3.20 AS final

# 从 builder 阶段复制编译好的扩展、工具和版本文件
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer
COPY --from=builder /tmp/php_version /tmp/php_version

RUN docker-php-ext-enable pdo_mysql mysqli gd exif intl zip opcache && rm -rf /var/cache/apk/* 2>/dev/null || true

WORKDIR /var/www/html