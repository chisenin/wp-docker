#!/bin/bash

# Redis修复验证脚本
echo "=================================================="
echo "Redis服务修复验证脚本"
echo "=================================================="

# 确保在正确的目录下
cd "$(dirname "$0")/.."

# 检查docker-compose文件是否存在
if [ ! -f "docker-compose.yml" ]; then
    echo "错误: 未找到docker-compose.yml文件。请先运行auto_deploy.sh。"
    exit 1
fi

# 停止可能正在运行的Redis容器
echo "停止现有Redis容器（如果存在）..."
docker-compose stop redis || true

# 移除现有Redis容器
echo "移除现有Redis容器（如果存在）..."
docker-compose rm -f redis || true

# 启动Redis容器
echo "启动修复后的Redis服务..."
docker-compose up -d redis

# 检查容器状态
echo "检查Redis容器状态..."
if docker-compose ps redis | grep -q "Up"; then
    echo "✓ Redis容器已成功启动！"
    
    # 等待几秒让Redis完全初始化
    echo "等待Redis服务初始化..."
    sleep 5
    
    # 尝试连接Redis
    echo "尝试连接到Redis服务..."
    REDIS_PASSWORD=$(grep REDIS_PASSWORD .env | cut -d'=' -f2)
    if docker-compose exec -T redis redis-cli -a "$REDIS_PASSWORD" ping | grep -q "PONG"; then
        echo "✓ 成功连接到Redis服务！修复验证通过。"
        echo "=================================================="
        echo "修复验证完成，Redis服务现在可以正常工作。"
        echo "=================================================="
        exit 0
    else
        echo "✗ 连接Redis服务失败。请检查密码或服务状态。"
        echo "容器日志:"
        docker-compose logs redis | tail -20
        exit 1
    fi
else
    echo "✗ Redis容器启动失败！"
    echo "容器日志:"
    docker-compose logs redis | tail -20
    exit 1
fi