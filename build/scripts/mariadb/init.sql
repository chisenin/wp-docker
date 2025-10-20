-- MariaDB初始化脚本

-- 创建WordPress数据库（如果不存在）
CREATE DATABASE IF NOT EXISTS wordpress DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- 创建WordPress用户（如果不存在）
CREATE USER IF NOT EXISTS 'wordpress'@'%' IDENTIFIED BY 'wordpress_password';

-- 授予用户权限
GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'%';

-- 创建测试数据库（用于开发环境）
CREATE DATABASE IF NOT EXISTS wordpress_test DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- 授予测试用户权限
GRANT ALL PRIVILEGES ON wordpress_test.* TO 'wordpress'@'%';

-- 刷新权限
FLUSH PRIVILEGES;

-- 优化设置
SET GLOBAL innodb_stats_on_metadata = 0;
SET GLOBAL max_connections = 150;
SET GLOBAL wait_timeout = 300;

-- 创建性能监控用户（可选）
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'monitor_password';
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'monitor'@'%';

-- 刷新权限
FLUSH PRIVILEGES;