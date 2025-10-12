#!/bin/bash
set -e

# WordPress Docker部署脚本
# 此脚本用于生成.env文件和处理docker-compose.yml配置
# 生成随机用户名和不含特殊字符的强密码

# 配置项
ENV_EXAMPLE=".env.example"
ENV_FILE=".env"
DOCKER_COMPOSE_FILE="docker-compose.yml"

# 生成随机字符串函数（不含特殊字符的强密码）
generate_secure_password() {
    local length=${1:-20}
    # 使用A-Z, a-z, 0-9生成随机密码，不含特殊字符
    local password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c $length)
    echo "$password"
}

# 生成随机用户名函数
generate_username() {
    local base_name=${1:-"wpuser"}
    local random_suffix=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
    echo "${base_name}${random_suffix}"
}

# 生成WordPress安全密钥
generate_wp_salts() {
    # 尝试从WordPress API获取安全密钥，如果失败则使用本地生成的随机值
    local salts
    salts=$(curl -s --retry 3 https://api.wordpress.org/secret-key/1.1/salt/ || true)
    
    if [ -z "$salts" ]; then
        echo "警告：无法连接到WordPress API，使用本地生成的随机安全密钥"
        # 本地生成8组随机安全密钥
        local keys=(
            "WORDPRESS_AUTH_KEY"
            "WORDPRESS_SECURE_AUTH_KEY"
            "WORDPRESS_LOGGED_IN_KEY"
            "WORDPRESS_NONCE_KEY"
            "WORDPRESS_AUTH_SALT"
            "WORDPRESS_SECURE_AUTH_SALT"
            "WORDPRESS_LOGGED_IN_SALT"
            "WORDPRESS_NONCE_SALT"
        )
        
        salts=""
        for key in "${keys[@]}"; do
            local value=$(generate_secure_password 64)
            salts="${salts}${key}='$value'\n"
        done
    fi
    
    echo "$salts"
}

# 主函数
main() {
    echo "开始WordPress Docker部署配置..."
    
    # 检查.env.example文件是否存在
    if [ ! -f "$ENV_EXAMPLE" ]; then
        echo "错误：找不到$ENV_EXAMPLE文件"
        exit 1
    fi
    
    # 生成随机值
    echo "生成随机配置..."
    local dockerhub_username="$(generate_username "docker")"
    local mysql_root_password="$(generate_secure_password 24)"
    local mysql_user="$(generate_username "wpdb")"
    local mysql_password="$(generate_secure_password 24)"
    local wp_salts="$(generate_wp_salts)"
    
    # 备份已存在的.env文件
    if [ -f "$ENV_FILE" ]; then
        local timestamp=$(date +%Y%m%d%H%M%S)
        echo "备份已存在的$ENV_FILE到$ENV_FILE.$timestamp"
        cp "$ENV_FILE" "$ENV_FILE.$timestamp"
    fi
    
    # 从.env.example生成.env文件
    echo "创建$ENV_FILE文件..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    
    # 替换.env文件中的占位符
    sed -i "s/your_dockerhub_username/$dockerhub_username/g" "$ENV_FILE"
    sed -i "s/your_root_password/$mysql_root_password/g" "$ENV_FILE"
    sed -i "s/your_wordpress_password/$mysql_password/g" "$ENV_FILE"
    
    # 替换数据库用户名（如果需要）
    # sed -i "s/MYSQL_USER=wordpress/MYSQL_USER=$mysql_user/g" "$ENV_FILE"
    
    # 替换WordPress安全密钥
    # 首先删除示例中的密钥行
    sed -i "/WORDPRESS_AUTH_KEY/d" "$ENV_FILE"
    sed -i "/WORDPRESS_SECURE_AUTH_KEY/d" "$ENV_FILE"
    sed -i "/WORDPRESS_LOGGED_IN_KEY/d" "$ENV_FILE"
    sed -i "/WORDPRESS_NONCE_KEY/d" "$ENV_FILE"
    sed -i "/WORDPRESS_AUTH_SALT/d" "$ENV_FILE"
    sed -i "/WORDPRESS_SECURE_AUTH_SALT/d" "$ENV_FILE"
    sed -i "/WORDPRESS_LOGGED_IN_SALT/d" "$ENV_FILE"
    sed -i "/WORDPRESS_NONCE_SALT/d" "$ENV_FILE"
    
    # 添加生成的安全密钥到.env文件末尾
    echo -e "\n$wp_salts" >> "$ENV_FILE"
    
    # 更新docker-compose.yml（如果需要）
    # 检查docker-compose.yml是否存在
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        echo "验证$DOCKER_COMPOSE_FILE文件..."
        # 这里可以根据需要添加对docker-compose.yml的修改
        # 例如，更新镜像版本或调整服务配置
    fi
    
    # 设置文件权限（确保.env文件只有当前用户可读）
    chmod 600 "$ENV_FILE"
    
    echo "部署配置完成！"
    echo "\n重要信息："
    echo "- Docker Hub用户名: $dockerhub_username"
    echo "- MySQL root密码: $mysql_root_password"
    echo "- MySQL数据库用户: $mysql_user"
    echo "- MySQL数据库密码: $mysql_password"
    echo "\n请妥善保存这些凭据，它们已保存在$ENV_FILE文件中。"
    echo "\n下一步：运行 'docker-compose up -d' 启动服务。"
}

# 运行主函数
main