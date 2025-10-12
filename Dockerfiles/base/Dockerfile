FROM alpine:3.22

ARG USE_CN_MIRROR=false

# 配置 Alpine 源
RUN if [ "$USE_CN_MIRROR" = "true" ]; then \ 
      echo "http://mirrors.aliyun.com/alpine/v3.22/main/" > /etc/apk/repositories && \ 
      echo "http://mirrors.aliyun.com/alpine/v3.22/community/" >> /etc/apk/repositories ; \ 
    else \ 
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/main" > /etc/apk/repositories && \ 
      echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories ; \ 
    fi

# 更新包索引
RUN apk update --no-cache

# 清理缓存（增强鲁棒性，忽略空目录错误）
RUN rm -rf /var/cache/apk/* 2>/dev/null || true