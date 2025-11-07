ARG BASE_IMAGE=alpine:3.20
FROM ${BASE_IMAGE}

ARG REDIS_VERSION=7.2

RUN apk add --no-cache redis=${REDIS_VERSION}-r0 tzdata \
    && addgroup -S redis && adduser -S -G redis redis \
    && mkdir /data && chown redis:redis /data

COPY --from=redis:${REDIS_VERSION}-alpine /etc/redis.conf /etc/redis.conf
RUN sed -i 's/bind 127.0.0.1/bind 0.0.0.0/' /etc/redis.conf \
    && echo "dir /data" >> /etc/redis.conf

EXPOSE 6379
HEALTHCHECK CMD redis-cli ping || exit 1
USER redis
ENTRYPOINT ["redis-server", "/etc/redis.conf"]