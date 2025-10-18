# 使用ARG指令支持动态设置base镜像地址，默认为alpine:3.22，便于替换
# 全局参数设置 - 必须放在FROM指令之前
ARG NGINX_VERSION=1.27.2-alpine
ARG BASE_IMAGE=alpine:3.22

# --- 构建阶段 ---
FROM nginx:1.27.2-alpine AS builder

# 配置Alpine源，确保使用正确的软件源
RUN echo 'https://dl-cdn.alpinelinux.org/alpine/v3.22/main' > /etc/apk/repositories && \
    echo 'https://dl-cdn.alpinelinux.org/alpine/v3.22/community' >> /etc/apk/repositories

# 获取实际 Nginx 版本并写入 /tmp/nginx_version，用于动态打标签
RUN set -x && \
    # 输出Nginx版本信息到控制台
    nginx -v 2>&1 && \
    # 提取版本号
    nginx -v 2>&1 | cut -d'/' -f2 | cut -d' ' -f1 > /tmp/nginx_version || echo "stable" > /tmp/nginx_version

# 确保使用Alpine的包管理器正确安装所需的辅助工具
RUN set -x && \
    # 更新包管理器索引
    apk update --no-cache && \
    apk add --no-cache vim bash curl wget

# 确保创建需要的目录
RUN mkdir -p /tmp/nginx-configs

# --- 最终构建阶段 ---
FROM nginx:1.27.2-alpine AS final

# 配置Alpine源，确保和构建阶段一致
RUN echo 'https://dl-cdn.alpinelinux.org/alpine/v3.22/main' > /etc/apk/repositories && \
    echo 'https://dl-cdn.alpinelinux.org/alpine/v3.22/community' >> /etc/apk/repositories

# 从 builder 阶段复制版本信息和辅助工具
COPY --from=builder /tmp/nginx_version /tmp/nginx_version
COPY --from=builder /bin/bash /bin/bash
COPY --from=builder /usr/bin/vim /usr/bin/vim
COPY --from=builder /usr/bin/curl /usr/bin/curl
COPY --from=builder /usr/bin/wget /usr/bin/wget

# 复制目标配置文件和Nginx配置模板到指定位置
COPY build/Dockerfiles/nginx/nginx.conf /etc/nginx/nginx.conf
COPY build/Dockerfiles/nginx/conf.d /etc/nginx/conf.d

# 确保Nginx日志目录存在（先以root用户创建目录）
USER root
RUN mkdir -p /var/log/nginx /var/cache/nginx

# 确保正确的权限设置
RUN chown -R nginx:nginx /var/log/nginx /var/cache/nginx /etc/nginx

# 切换回nginx用户以提高安全性
USER nginx

# 暴露端口
EXPOSE 80

# 使用exec格式直接运行nginx进程，符合Alpine容器最佳实践，可以正确响应信号
CMD ["nginx", "-g", "daemon off;"]