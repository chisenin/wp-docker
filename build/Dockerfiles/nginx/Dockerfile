# 使用ARG参数支持动态传入base镜像地址，默认为alpine:3.22作为回退
# 全局参数声明 - 必须在所有FROM指令之前
ARG NGINX_VERSION=1.27.2-alpine
ARG BASE_IMAGE=alpine:3.22

# --- 构建阶段 ---
FROM nginx:${NGINX_VERSION} AS builder

# 配置Alpine仓库，确保使用正确的镜像源
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/testing" >> /etc/apk/repositories

# 提取实际 Nginx 版本（写入 /tmp/nginx_version，用于动态标签）
RUN set -x && \
    # 输出Nginx版本信息，便于调试
    nginx -v 2>&1 && \
    # 提取版本号
    nginx -v 2>&1 | cut -d'/' -f2 | cut -d' ' -f1 > /tmp/nginx_version || echo "stable" > /tmp/nginx_version

# 确保使用Alpine的包管理工具并安装必要的调试工具
RUN set -x && \
    # 更新包索引并安装工具
    apk update --no-cache && \
    apk add --no-cache vim bash curl wget

# 确保创建必要的目录
RUN mkdir -p /tmp/nginx-configs

# --- 最终运行阶段 ---
FROM nginx:${NGINX_VERSION} AS final

# 配置Alpine仓库，确保与构建阶段一致
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories

# 从 builder 阶段复制版本信息和调试工具
COPY --from=builder /tmp/nginx_version /tmp/nginx_version
COPY --from=builder /bin/bash /bin/bash
COPY --from=builder /usr/bin/vim /usr/bin/vim
COPY --from=builder /usr/bin/curl /usr/bin/curl
COPY --from=builder /usr/bin/wget /usr/bin/wget

# 从当前目录复制Nginx配置文件（相对于Dockerfile的位置）
COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d /etc/nginx/conf.d

# 确保Nginx日志目录存在
RUN mkdir -p /var/log/nginx /var/cache/nginx

# 确保正确的权限设置
RUN chown -R nginx:nginx /var/log/nginx /var/cache/nginx /etc/nginx

# 暴露端口
EXPOSE 80

# 使用exec形式，直接运行nginx，更符合Alpine镜像的推荐用法，确保正确处理信号
CMD ["nginx", "-g", "daemon off;"]