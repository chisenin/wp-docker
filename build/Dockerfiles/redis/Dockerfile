# Redis Dockerfile
# 全局参数声明
ARG BASE_IMAGE=alpine:3.22
ARG REDIS_VERSION=7.4.0

# 使用Alpine作为基础镜像
FROM ${BASE_IMAGE}

# 标签信息
LABEL maintainer="wp-docker project" \
      description="Redis image for WordPress Docker environment" \
      redis-version="7.4.0"

# 直接设置版本号，避免变量未定义问题
ENV REDIS_VERSION=7.4.0

# 安装Redis预编译包
RUN apk update --no-cache && \
    apk add --no-cache \
    redis \
    && rm -rf /var/cache/apk/*

# 安装额外运行时依赖
RUN apk add --no-cache \
    bash \
    tzdata \
    && rm -rf /var/cache/apk/*

# 设置时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone

# 检查并创建Redis用户和组，避免重复创建错误
RUN if ! grep -q "redis" /etc/group; then \
        addgroup -g 1000 redis; \
    fi && \
    if ! grep -q "redis" /etc/passwd; then \
        adduser -u 1000 -G redis -s /bin/false -D redis; \
    fi

# 创建必要的目录
RUN mkdir -p /data /etc/redis && \
    chown -R redis:redis /data /etc/redis

# 配置文件
COPY build/deploy_configs/redis/redis.conf /etc/redis/redis.conf

# 初始化脚本
COPY build/scripts/redis/entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh

# 暴露端口
EXPOSE 6379

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD redis-cli ping || exit 1

# 设置工作目录
WORKDIR /data

# 入口点
ENTRYPOINT ["entrypoint.sh"]
CMD ["redis-server", "/etc/redis/redis.conf"]