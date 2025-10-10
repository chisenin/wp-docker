FROM nginx:1.25.4-alpine3.20
FROM nginx:1.25.4-alpine3.18

ARG USE_CN_MIRROR=false

RUN if [ "$USE_CN_MIRROR" = "true" ]; then \
      echo "http://mirrors.aliyun.com/alpine/v3.18/main/" > /etc/apk/repositories && \
      echo "http://mirrors.aliyun.com/alpine/v3.18/community/" >> /etc/apk/repositories ; \
    else \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.18/main" > /etc/apk/repositories && \
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.18/community" >> /etc/apk/repositories ; \
    fi && apk update --no-cache

# 安装调试工具
RUN apk add --no-cache vim bash curl wget

COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d /etc/nginx/conf.d

RUN chown -R www-data:www-data /var/cache/nginx /var/log/nginx

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]