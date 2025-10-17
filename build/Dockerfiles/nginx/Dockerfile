# 使用ARG参数支持动态传入base镜像地址，默认为alpine:3.22作为回退
# 全局参数声明 - 必须在所有FROM指令之前
ARG NGINX_VERSION=1.27.2
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

# 复制配置文件，从构建上下文根目录开始引用
COPY build/deploy_configs/nginx/nginx.conf /etc/nginx/nginx.conf
COPY build/deploy_configs/nginx/conf.d /etc/nginx/conf.d

# Official Nginx image already has proper directory structure and permissions
# No need to create or modify these directories
# Logs and cache will be handled by Nginx automatically

EXPOSE 80
# 使用shell形式，但明确指定使用bash执行，避免解析问题
CMD ["bash", "-c", "nginx -g 'daemon off;' "]