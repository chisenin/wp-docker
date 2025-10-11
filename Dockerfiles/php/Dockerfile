# --- 构建阶段 ---
FROM php:8.3-fpm-alpine3.20 AS builder

# 定义 ARG 以支持动态哈希传入（默认为空，回退时可硬编码）
ARG COMPOSER_HASH=""

# 提取实际 PHP 版本（写入 /tmp/php_version，用于动态标签）
RUN php -v | head -1 | cut -d' ' -f2 | cut -d'-' -f1 > /tmp/php_version || echo "8.3" > /tmp/php_version

ARG USE_CN_MIRROR=false

# 配置 Alpine 源
RUN if [ "$USE_CN_MIRROR" = "true" ]; then \n      echo "http://mirrors.aliyun.com/alpine/v3.20/main/" > /etc/apk/repositories && \n      echo "http://mirrors.aliyun.com/alpine/v3.20/community/" >> /etc/apk/repositories ; \n    else \n      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \n      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories ; \n    fi

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