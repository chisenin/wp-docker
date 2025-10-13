#!/bin/bash

# 测试脚本：验证Docker镜像构建流程

echo "开始测试Docker镜像构建流程..."

# 清理旧镜像（可选）
echo "清理旧的测试镜像..."
docker rmi -f wordpress-php:test wordpress-nginx:test 2>/dev/null || true

# 测试PHP镜像构建
echo "\n测试构建PHP镜像..."
docker buildx build --platform linux/amd64 \
  --build-arg BASE_IMAGE=alpine:3.22 \
  --build-arg COMPOSER_HASH=ed0feb545ba87161262f2d45a633e34f591ebb3381f2e0063c345ebea4d228dd0043083717770234ec00c5a9f9593792 \
  -f ./Dockerfiles/php/Dockerfile \
  -t wordpress-php:test .

if [ $? -ne 0 ]; then
  echo "\n❌ PHP镜像构建失败！"
  exit 1
fi

echo "\n✅ PHP镜像构建成功！"

# 测试Nginx镜像构建
echo "\n测试构建Nginx镜像..."
docker buildx build --platform linux/amd64 \
  --build-arg BASE_IMAGE=alpine:3.22 \
  --build-arg NGINX_VERSION=1.27.2 \
  -f ./Dockerfiles/nginx/Dockerfile \
  -t wordpress-nginx:test .

if [ $? -ne 0 ]; then
  echo "\n❌ Nginx镜像构建失败！"
  exit 1
fi

echo "\n✅ Nginx镜像构建成功！"

echo "\n🎉 所有构建测试通过！GitHub Actions工作流的修改应该能解决镜像构建失败的问题。"