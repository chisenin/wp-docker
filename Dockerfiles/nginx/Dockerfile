FROM nginx:1.25.4-alpine3.20
FROM nginx:1.27-alpine3.20

# 提取实际 Nginx 版本（写入 /tmp/nginx_version，用于动态标签）
RUN nginx -v 2>&1 | cut -d'/' -f2 | cut -d' ' -f1 > /tmp/nginx_version || echo "1.27" > /tmp/nginx_version

ARG USE_CN_MIRROR=false

# 配置 Alpine 源
RUN if [ "$USE_CN_MIRROR" = "true" ]; then \
      echo "http://mirrors.aliyun.com/alpine/v3.20/main/" > /etc/apk/repositories && \
      echo "http://mirrors.aliyun.com/alpine/v3.20/community/" >> /etc/apk/repositories ; \
    else \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories ; \
    fi && apk update --no-cache

# 安装调试工具
RUN apk add --no-cache vim bash curl wget

# 确保目录存在并设置权限
RUN mkdir -p /var/cache/nginx /var/log/nginx
RUN chown -R nginx:nginx /var/cache/nginx /var/log/nginx
RUN chmod -R 755 /var/cache/nginx /var/log/nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d /etc/nginx/conf.d

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]