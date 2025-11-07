ARG BASE_IMAGE=alpine:3.20
FROM ${BASE_IMAGE}

ARG MARIADB_VERSION=10.11

RUN apk add --no-cache \
        mariadb=${MARIADB_VERSION}-r0 \
        mariadb-client=${MARIADB_VERSION}-r0 \
        tzdata pwgen \
    && mkdir -p /var/lib/mysql /var/run/mysqld \
    && chown mysql:mysql /var/lib/mysql /var/run/mysqld

# 官方 entrypoint
COPY --from=mariadb:${MARIADB_VERSION} /usr/local/bin/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME /var/lib/mysql
EXPOSE 3306
HEALTHCHECK CMD mysqladmin ping -h localhost || exit 1
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["mariadbd"]