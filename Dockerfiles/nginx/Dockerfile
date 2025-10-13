# 使用ARG参数支持动态传入base镜像地址，默认为alpine:3.22作为回退
# 全局参数声明 - 必须在所有FROM指令之前
ARG NGINX_VERSION=1.26.2
ARG BASE_IMAGE=alpine:3.22

# --- 基础阶段 ---
FROM ${BASE_IMAGE} AS base

# --- 构建阶段 ---
FROM nginx:${NGINX_VERSION} AS builder

# 提取实际 Nginx 版本（写入 /tmp/nginx_version，用于动态标签）
RUN nginx -v 2>&1 | cut -d'/' -f2 | cut -d' ' -f1 > /tmp/nginx_version || echo "stable" > /tmp/nginx_version

COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 更新包索引
RUN apk update --no-cache

# 安装调试工具
RUN apk add --no-cache vim bash curl wget

# 下载 WordPress 常见文件类型的 MIME 类型配置（可选优化）
RUN mkdir -p /tmp/nginx-configs

# --- 最终运行阶段 ---
FROM nginx:${NGINX_VERSION} AS final

# 从 builder 阶段复制版本信息和调试工具
COPY --from=builder /tmp/nginx_version /tmp/nginx_version
COPY --from=builder /bin/bash /bin/bash
COPY --from=builder /usr/bin/vim /usr/bin/vim
COPY --from=builder /usr/bin/curl /usr/bin/curl
COPY --from=builder /usr/bin/wget /usr/bin/wget

# 复制配置文件，使用正确的相对路径
COPY ./configs/nginx/nginx.conf /etc/nginx/nginx.conf
COPY ./configs/nginx/conf.d /etc/nginx/conf.d

# 创建日志目录并设置权限（更稳健的方法）
RUN set -x && \
    # 检查nginx用户是否存在
    id nginx || echo "nginx user does not exist, using default user" && \
    # 创建日志目录
    mkdir -p /var/log/nginx && \
    # 创建日志文件
    touch /var/log/nginx/error.log && \
    touch /var/log/nginx/access.log && \
    # 检查缓存目录是否存在，不存在则创建
    [ -d /var/cache/nginx ] || mkdir -p /var/cache/nginx && \
    # 尝试使用nginx用户，如果失败则使用当前用户
    if id nginx >/dev/null 2>&1; then \
        chown -R nginx:nginx /var/cache/nginx /var/log/nginx; \
    else \
        # 回退方案：使用当前用户
        chown -R $(whoami):$(whoami) /var/cache/nginx /var/log/nginx; \
    fi && \
    # 设置权限
    chmod -R 755 /var/log/nginx

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]