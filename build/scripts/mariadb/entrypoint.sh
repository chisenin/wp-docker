#!/bin/bash

set -e

# 初始化MariaDB数据目录
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Initializing MariaDB data directory..."
    mysql_install_db --user=mysql --datadir=/var/lib/mysql --rpm
fi

# 启动MariaDB临时实例进行配置
mysqld --user=mysql --datadir=/var/lib/mysql --skip-networking &
MYSQLD_PID=$!

# 等待MariaDB启动
while ! mysqladmin ping --silent; do
    sleep 1
    if ! kill -0 $MYSQLD_PID 2>/dev/null; then
        echo "MariaDB initialization failed"
        exit 1
    fi
done

# 设置root密码
if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
    mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD' WITH GRANT OPTION;"
    mysql -e "FLUSH PRIVILEGES;"
fi

# 创建WordPress数据库和用户
if [ -n "$MYSQL_DATABASE" ]; then
    mysql -e "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE;"
    
    if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
        mysql -e "CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';"
        mysql -e "GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'%';"
        mysql -e "FLUSH PRIVILEGES;"
    fi
fi

# 运行初始化SQL脚本
if [ -d "/docker-entrypoint-initdb.d" ]; then
    echo "Running initialization scripts..."
    for f in /docker-entrypoint-initdb.d/*.sql; do
        [ -f "$f" ] && echo "Executing $f" && mysql < "$f"
    done
done

# 停止临时实例
mysqladmin shutdown
wait $MYSQLD_PID

# 启动MariaDB主实例
echo "Starting MariaDB..."
exec mysqld --user=mysql --datadir=/var/lib/mysql