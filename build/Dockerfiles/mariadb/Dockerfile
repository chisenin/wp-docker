# ============ 基础镜像 ============
ARG BASE_IMAGE=alpine:3.20
FROM ${BASE_IMAGE} AS base

# ============ 构建阶段 ============
FROM base AS builder

ARG MARIADB_VERSION=10.11

# 安装 MariaDB 服务器 + 客户端（以及常用工具）
RUN apk add --no-cache \
        mariadb=${MARIADB_VERSION}-r0 \
        mariadb-client=${MARIADB_VERSION}-r0 \
        mariadb-common=${MARIADB_VERSION}-r0 \
        tzdata \
        pwgen \
    && mkdir -p /var/lib/mysql /var/run/mysqld \
    && chown mysql:mysql /var/lib/mysql /var/run/mysqld \
    && chmod 755 /var/lib/mysql /var/run/mysqld

# 初始化数据库（官方推荐的 entrypoint 会自动执行）
RUN mysql_install_db --user=mysql --datadir=/var/lib/mysql --skip-test-db

# ============ 最终运行阶段 ============
FROM base AS final

ARG MARIADB_VERSION=10.11

# 只保留运行时需要的包
RUN apk add --no-cache \
        mariadb=${MARIADB_VERSION}-r0 \
        mariadb-client=${MARIADB_VERSION}-r0 \
        mariadb-common=${MARIADB_VERSION}-r0 \
        tzdata \
        pwgen

# 复制数据目录与运行目录（已初始化）
COPY --from=builder /var/lib/mysql /var/lib/mysql
COPY --from=builder /var/run/mysqld /var/run/mysqld

# 官方 entrypoint 脚本（来自 mariadb 官方镜像）
COPY --from=mariadb:${MARIADB_VERSION} /usr/local/bin/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 环境变量（可被 docker-compose 覆盖）
ENV MYSQL_ROOT_PASSWORD=
ENV MYSQL_DATABASE=
ENV MYSQL_USER=
ENV MYSQL_PASSWORD=

# 暴露端口
EXPOSE 3306

# 健康检查
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
    CMD mysqladmin ping -h localhost -u root ${MYSQL_ROOT_PASSWORD:+-p$MYSQL_ROOT_PASSWORD} || exit 1

# 入口点
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["mariadbd", "--user=mysql", "--datadir=/var/lib/mysql"]