# MariaDB Dockerfile
# 全局参数声明
ARG BASE_IMAGE=alpine:3.22
ARG MARIADB_VERSION=11.3.2

# 使用Alpine作为基础镜像
FROM ${BASE_IMAGE}

# 标签信息
LABEL maintainer="wp-docker project" \
      description="MariaDB image for WordPress Docker environment" \
      mariadb-version="${MARIADB_VERSION}"

# 设置版本信息环境变量（用于后续引用）
ENV MARIADB_VERSION=${MARIADB_VERSION}

# 安装运行时依赖
RUN apk update --no-cache && \
    apk add --no-cache \
    mariadb mariadb-client \
    bash \
    tzdata \
    && rm -rf /var/cache/apk/*

# 设置时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone

# 创建MySQL用户和组
RUN addgroup -g 81 mysql && \
    adduser -u 81 -G mysql -s /bin/false -D mysql

# 创建必要的目录
RUN mkdir -p /var/lib/mysql /var/run/mysqld /var/log/mysql && \
    chown -R mysql:mysql /var/lib/mysql /var/run/mysqld /var/log/mysql && \
    chmod 777 /var/run/mysqld

# 配置文件
COPY build/deploy_configs/mariadb/my.cnf /etc/my.cnf

# 初始化脚本
COPY build/scripts/mariadb/init.sql /docker-entrypoint-initdb.d/
COPY build/scripts/mariadb/entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh

# 暴露端口
EXPOSE 3306

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD mysqladmin ping -u root -p$MYSQL_ROOT_PASSWORD || exit 1

# 入口点
ENTRYPOINT ["entrypoint.sh"]
CMD ["mysqld"]