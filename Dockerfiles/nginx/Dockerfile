FROM nginx:1.25.4-alpine3.20

# 配置国内源
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories && \
    echo "http://mirrors.aliyun.com/alpine/v3.20/main/" >> /etc/apk/repositories && \
    echo "http://mirrors.aliyun.com/alpine/v3.20/community/" >> /etc/apk/repositories && \
    apk update --no-cache

# 安装调试工具
RUN apk add --no-cache vim bash curl wget

COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d /etc/nginx/conf.d

RUN chown -R www-data:www-data /var/cache/nginx /var/log/nginx

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]