# 使用确定性版本的Nginx Alpine镜像
FROM nginx:1.27.2-alpine AS final

# 配置Alpine源
RUN echo 'https://dl-cdn.alpinelinux.org/alpine/v3.22/main' > /etc/apk/repositories && \
    echo 'https://dl-cdn.alpinelinux.org/alpine/v3.22/community' >> /etc/apk/repositories

# 以root用户创建必要目录并设置权限
USER root
RUN mkdir -p /var/log/nginx /var/cache/nginx && \
    chown -R nginx:nginx /var/log/nginx /var/cache/nginx /etc/nginx

# 更新包管理器并安装必要工具
RUN apk update --no-cache && \
    apk add --no-cache bash curl wget

# 切换回nginx用户以提高安全性
USER nginx

# 暴露端口
EXPOSE 80

# 启动命令
CMD ["nginx", "-g", "daemon off;"]