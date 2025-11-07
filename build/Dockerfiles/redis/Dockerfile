# ============ 基础镜像 ============
ARG BASE_IMAGE=alpine:3.20
FROM ${BASE_IMAGE} AS base

# ============ 构建阶段 ============
FROM base AS builder

ARG REDIS_VERSION=7.2

# 安装 Redis 服务器 + 客户端
RUN apk add --no-cache \
        redis=${REDIS_VERSION}-r0 \
        tzdata

# 创建 redis 用户与目录
RUN addgroup -S redis && adduser -S -G redis redis \
    && mkdir -p /data /var/run/redis \
    && chown redis:redis /data /var/run/redis \
    && chmod 755 /data /var/run/redis

# 默认配置文件（官方默认已足够，可自行覆盖）
COPY --from=redis:${REDIS_VERSION}-alpine /etc/redis.conf /etc/redis.conf
RUN sed -i 's/^# bind 127.0.0.1/bind 0.0.0.0/' /etc/redis.conf \
    && echo "dir /data" >> /etc/redis.conf \
    && echo "pidfile /var/run/redis/redis.pid" >> /etc/redis.conf

# ============ 最终运行阶段 ============
FROM base AS final

ARG REDIS_VERSION=7.2

RUN apk add --no-cache \
        redis=${REDIS_VERSION}-r0 \
        tzdata

# 复制运行目录与配置文件
COPY --from=builder /data /data
COPY --from=builder /var/run/redis /var/run/redis
COPY --from=builder /etc/redis.conf /etc/redis.conf

# 权限
RUN chown -R redis:redis /data /var/run/redis /etc/redis.conf

# 环境变量
ENV REDIS_PASSWORD=

# 暴露端口
EXPOSE 6379

# 健康检查
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD redis-cli -h 127.0.0.1 ${REDIS_PASSWORD:+-a $REDIS_PASSWORD} ping || exit 1

# 入口点（官方自带）
ENTRYPOINT ["redis-server", "/etc/redis.conf"]