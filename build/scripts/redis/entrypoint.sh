#!/bin/bash

set -e

# 确保数据目录权限正确
chown -R redis:redis /data

# 修改Redis配置文件（如果需要）
if [ -n "$REDIS_PASSWORD" ]; then
    echo "设置Redis密码"
    sed -i "s/# requirepass foobared/requirepass $REDIS_PASSWORD/" /etc/redis/redis.conf
fi

# 调整最大内存设置
if [ -n "$REDIS_MAXMEMORY" ]; then
    echo "设置最大内存为 $REDIS_MAXMEMORY"
    sed -i "s/maxmemory 256mb/maxmemory $REDIS_MAXMEMORY/" /etc/redis/redis.conf
fi

# 启动Redis
echo "Starting Redis..."
exec redis-server /etc/redis/redis.conf