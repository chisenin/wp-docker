FROM alpine:3.22

# 使用 Alpine 3.22 作为基础镜像
FROM alpine:3.22

# 配置 Alpine 源
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories

# 更新包索引
RUN apk update --no-cache

# 清理缓存（增强鲁棒性，忽略空目录错误）
RUN rm -rf /var/cache/apk/* 2>/dev/null || true