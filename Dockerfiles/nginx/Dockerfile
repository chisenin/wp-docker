FROM local/base:3.22 AS base

# --- 构建阶段 --- 
FROM nginx:1.27-alpine3.22 AS builder

# 提取实际 Nginx 版本（写入 /tmp/nginx_version，用于动态标签）
RUN nginx -v 2>&1 | cut -d'/' -f2 | cut -d' ' -f1 > /tmp/nginx_version || echo "1.27" > /tmp/nginx_version

COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 更新包索引
RUN apk update --no-cache

# 安装调试工具
RUN apk add --no-cache vim bash curl wget

# 下载 WordPress 常见文件类型的 MIME 类型配置（可选优化）
RUN mkdir -p /tmp/nginx-configs

# --- 最终运行阶段 --- 
FROM nginx:1.27-alpine3.22 AS final

COPY --from=base /etc/apk/repositories /etc/apk/repositories

# 从 builder 阶段复制版本信息和调试工具
COPY --from=builder /tmp/nginx_version /tmp/nginx_version
COPY --from=builder /usr/bin/vim /usr/bin/vim
COPY --from=builder /usr/bin/bash /usr/bin/bash
COPY --from=builder /usr/bin/curl /usr/bin/curl
COPY --from=builder /usr/bin/wget /usr/bin/wget

# 复制配置文件，使用正确的相对路径
COPY ./configs/nginx/nginx.conf /etc/nginx/nginx.conf
COPY ./configs/nginx/conf.d /etc/nginx/conf.d

# 创建日志目录并设置权限
RUN mkdir -p /var/log/nginx && \
    touch /var/log/nginx/error.log && \
    touch /var/log/nginx/access.log && \
    chown -R www-data:www-data /var/cache/nginx /var/log/nginx && \
    chmod -R 755 /var/log/nginx

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]