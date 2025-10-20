#!/bin/bash
set -e

# 版本监测脚本 - 检查Alpine、PHP、Nginx和Composer的版本更新
# 此脚本在GitHub Actions中运行，检测到更新时会更新版本文件并触发构建

# 当前版本文件路径 - 使用绝对路径确保在任何目录下都能正确运行
PHP_VERSION_FILE="build/Dockerfiles/php/php_version.txt"
NGINX_VERSION_FILE="build/Dockerfiles/nginx/nginx_version.txt"
COMPOSER_HASH_FILE="build/Dockerfiles/php/composer_hash.txt"
BASE_DOCKERFILE="build/Dockerfiles/base/Dockerfile"
ALPINE_VERSION="3.22"  # 固定minor，监测patch

# 配置日志和输出
WORKSPACE_DIR="${GITHUB_WORKSPACE:-.}"
LOG_FILE="${WORKSPACE_DIR}/check_versions.log"
UPDATED_COMPONENTS_FILE="${WORKSPACE_DIR}/updated_components.txt"

# 函数：记录日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
}

# 函数：检查Alpine最新tag（使用Docker Hub API）
check_alpine() {
    log "检查Alpine最新版本（${ALPINE_VERSION}系列）"
    
    # 使用Docker Hub API查询最新的Alpine标签
    LATEST_ALPINE=$(curl -s "https://hub.docker.com/v2/repositories/library/alpine/tags/?page_size=10" 2>/dev/null | \
                   jq -r '.results[] | select(.name | startswith("'$ALPINE_VERSION'")) | .name' 2>/dev/null | \
                   sort -V | tail -1)
    
    if [ -n "$LATEST_ALPINE" ]; then
        log "成功获取Alpine最新版本: $LATEST_ALPINE"
        # 检查是否有新的patch版本
        if [[ "$LATEST_ALPINE" != "$ALPINE_VERSION" ]]; then
            log "Alpine更新检测到: $ALPINE_VERSION -> $LATEST_ALPINE"
            echo "base" >> "$UPDATED_COMPONENTS_FILE"  # 使用追加方式，避免覆盖
            
            # 如果存在基础Dockerfile，尝试更新版本号
            if [ -f "$BASE_DOCKERFILE" ]; then
                log "更新基础Dockerfile中的Alpine版本"
                sed -i "s/alpine:$ALPINE_VERSION/alpine:$LATEST_ALPINE/g" "$BASE_DOCKERFILE"
            fi
        fi
    else
        log "无法获取Alpine版本信息，跳过版本检查"
    fi
}

# 函数：检查PHP最新版本（8.3系列）
check_php() {
    log "检查PHP最新版本（8.3系列）"
    
    # 获取当前PHP版本
    CURRENT_PHP=$(cat "$PHP_VERSION_FILE" 2>/dev/null || echo "0")
    log "当前PHP版本: $CURRENT_PHP"
    
    # 使用Docker Hub API查询最新的PHP标签
    LATEST_PHP=$(curl -s "https://hub.docker.com/v2/repositories/library/php/tags/?page_size=10" 2>/dev/null | \
                jq -r '.results[] | select(.name | contains("8.3") and contains("fpm-alpine3.22")) | .name' 2>/dev/null | \
                grep -oP '8\.3\.\K\d+' 2>/dev/null | sort -n | tail -1)
    
    if [ -n "$LATEST_PHP" ]; then
        log "成功获取PHP最新版本: $LATEST_PHP"
        # 比较版本
        if [ "$LATEST_PHP" != "$CURRENT_PHP" ]; then
            log "PHP更新检测到: $CURRENT_PHP -> $LATEST_PHP"
            echo "$LATEST_PHP" > "$PHP_VERSION_FILE"
            echo "php" >> "$UPDATED_COMPONENTS_FILE"
        fi
    else
        log "无法获取PHP版本信息，跳过版本检查"
    fi
}

# 函数：检查Nginx最新版本（1.27系列）
check_nginx() {
    log "检查Nginx最新版本（1.27系列）"
    
    # 获取当前Nginx版本
    CURRENT_NGINX=$(cat "$NGINX_VERSION_FILE" 2>/dev/null || echo "stable-alpine")
    log "当前Nginx版本: $CURRENT_NGINX"
    
    # 使用Docker Hub API查询最新的Nginx标签
    LATEST_NGINX_TAG=$(curl -s "https://hub.docker.com/v2/repositories/library/nginx/tags/?page_size=10" 2>/dev/null | \
                     jq -r '.results[] | select(.name | contains("1.27") and contains("alpine")) | .name' 2>/dev/null | \
                     head -1)
    
    if [ -n "$LATEST_NGINX_TAG" ]; then
        log "成功获取Nginx最新标签: $LATEST_NGINX_TAG"
        # 提取版本号
        LATEST_NGINX_VERSION=$(echo "$LATEST_NGINX_TAG" | grep -oP '1\.27\.\K\d+' 2>/dev/null || echo "stable-alpine")
        
        # 如果是新版本或标签发生变化
        if [ "$LATEST_NGINX_VERSION" != "$CURRENT_NGINX" ]; then
            log "Nginx更新检测到: $CURRENT_NGINX -> $LATEST_NGINX_TAG"
            echo "$LATEST_NGINX_VERSION" > "$NGINX_VERSION_FILE"
            echo "nginx" >> "$UPDATED_COMPONENTS_FILE"
        fi
    else
        log "无法获取Nginx版本信息，跳过版本检查"
    fi
}

# 函数：检查Composer hash（从官网获取）
check_composer() {
    log "检查Composer最新版本"
    
    # 获取当前Composer哈希
    CURRENT_HASH=$(cat "$COMPOSER_HASH_FILE" 2>/dev/null || echo "")
    
    # 获取最新的Composer安装器哈希
    LATEST_HASH=$(curl -s --retry 3 https://composer.github.io/installer.sig 2>/dev/null || echo "")
    
    if [ -n "$LATEST_HASH" ]; then
        log "成功获取最新Composer哈希"
        # 比较哈希
        if [ "$LATEST_HASH" != "$CURRENT_HASH" ]; then
            log "Composer更新检测到"
            echo "$LATEST_HASH" > "$COMPOSER_HASH_FILE"
            echo "php" >> "$UPDATED_COMPONENTS_FILE"  # Composer更新触发PHP重建
        fi
    else
        log "无法获取Composer哈希，跳过版本检查"
    fi
}

# 函数：检查MariaDB最新版本（11.3系列）
check_mariadb() {
    log "检查MariaDB最新版本（11.3系列）"
    
    # 获取当前MariaDB版本
    CURRENT_MARIADB=$(cat "$MARIADB_VERSION_FILE" 2>/dev/null || echo "0")
    log "当前MariaDB版本: $CURRENT_MARIADB"
    
    # 使用Docker Hub API查询最新的MariaDB标签
    LATEST_MARIADB=$(curl -s "https://hub.docker.com/v2/repositories/library/mariadb/tags/?page_size=10" 2>/dev/null | \
                   jq -r '.results[] | select(.name | contains("11.3") and (.name | test("^11\\.3\\.\\d+$") )) | .name' 2>/dev/null | \
                   sort -V | tail -1)
    
    if [ -n "$LATEST_MARIADB" ]; then
        log "成功获取MariaDB最新版本: $LATEST_MARIADB"
        # 比较版本
        if [ "$LATEST_MARIADB" != "$CURRENT_MARIADB" ]; then
            log "MariaDB更新检测到: $CURRENT_MARIADB -> $LATEST_MARIADB"
            echo "$LATEST_MARIADB" > "$MARIADB_VERSION_FILE"
            echo "mariadb" >> "$UPDATED_COMPONENTS_FILE"
        fi
    else
        log "无法获取MariaDB版本信息，跳过版本检查"
    fi
}

# 函数：检查Redis最新版本（7.4系列）
check_redis() {
    log "检查Redis最新版本（7.4系列）"
    
    # 获取当前Redis版本
    CURRENT_REDIS=$(cat "$REDIS_VERSION_FILE" 2>/dev/null || echo "0")
    log "当前Redis版本: $CURRENT_REDIS"
    
    # 使用Docker Hub API查询最新的Redis标签
    LATEST_REDIS=$(curl -s "https://hub.docker.com/v2/repositories/library/redis/tags/?page_size=10" 2>/dev/null | \
                 jq -r '.results[] | select(.name | contains("7.4") and (.name | test("^7\\.4\\.\\d+$") )) | .name' 2>/dev/null | \
                 sort -V | tail -1)
    
    if [ -n "$LATEST_REDIS" ]; then
        log "成功获取Redis最新版本: $LATEST_REDIS"
        # 比较版本
        if [ "$LATEST_REDIS" != "$CURRENT_REDIS" ]; then
            log "Redis更新检测到: $CURRENT_REDIS -> $LATEST_REDIS"
            echo "$LATEST_REDIS" > "$REDIS_VERSION_FILE"
            echo "redis" >> "$UPDATED_COMPONENTS_FILE"
        fi
    else
        log "无法获取Redis版本信息，跳过版本检查"
    fi
}

# 主函数
main() {
    log "开始版本监测检查"
    
    # 确保必要的目录存在
    mkdir -p "$(dirname "$PHP_VERSION_FILE")"
    mkdir -p "$(dirname "$NGINX_VERSION_FILE")"
    mkdir -p "$(dirname "$COMPOSER_HASH_FILE")"
    mkdir -p "$(dirname "$BASE_DOCKERFILE")"
    
    # 清理旧的更新文件
    rm -f "$UPDATED_COMPONENTS_FILE"
    touch "$LOG_FILE"
    
    # 检查各个组件的版本
    check_alpine
    check_php
    check_nginx
    check_composer
    
    # 去重并清理更新组件文件
    if [ -f "$UPDATED_COMPONENTS_FILE" ]; then
        # 确保文件不为空
        if [ -s "$UPDATED_COMPONENTS_FILE" ]; then
            sort -u "$UPDATED_COMPONENTS_FILE" -o "$UPDATED_COMPONENTS_FILE"
            log "检测到更新，需要重建的组件: $(cat "$UPDATED_COMPONENTS_FILE" | tr '\n' ', ' | sed 's/,$//')"
            
            # 处理基础镜像依赖关系：如果base被标记为更新，确保php和nginx也被包含
            if grep -q "base" "$UPDATED_COMPONENTS_FILE"; then
                log "基础镜像需要更新，将确保php和nginx也被包含在更新列表中"
                echo "php" >> "$UPDATED_COMPONENTS_FILE"
                echo "nginx" >> "$UPDATED_COMPONENTS_FILE"
                sort -u "$UPDATED_COMPONENTS_FILE" -o "$UPDATED_COMPONENTS_FILE"
            fi
            
            # 输出结果供GitHub Actions使用
            if [ -n "$GITHUB_OUTPUT" ]; then
                echo "updated=true" >> "$GITHUB_OUTPUT"
                echo "components=$(cat "$UPDATED_COMPONENTS_FILE" | tr '\n' ', ' | sed 's/,$//')" >> "$GITHUB_OUTPUT"
            fi
            exit 0  # 有更新
        else
            # 文件存在但为空
            log "未检测到更新"
            rm -f "$UPDATED_COMPONENTS_FILE"  # 删除空文件
        fi
    fi
    
    # 无更新情况
    log "未检测到更新"
    # 创建空文件，确保在工作流中能够读取到文件
    touch "$UPDATED_COMPONENTS_FILE"
    
    if [ -n "$GITHUB_OUTPUT" ]; then
        echo "updated=false" >> "$GITHUB_OUTPUT"
    fi
    exit 1  # 无更新
}

# 运行主函数
main