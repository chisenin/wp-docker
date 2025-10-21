# WordPress + Docker Compose 项目 (GitHub Actions 自动化版)
---
本项目使用 Docker Compose 部署 WordPress 生产环境，采用多阶段构建优化镜像，并集成 GitHub Actions 实现 CI/CD 自动化，确保环境一致性、稳定性和部署效率。

**注意**: 详细指南文档已移至 `guides/` 目录，包含从介绍到部署的完整步骤说明。

**主要特性**: 动态版本锁定、共享Base镜像、配置即代码、全栈自定义、自动版本监控与构建、自动化部署脚本、安全实践集成
---
## 项目结构

```
wp-docker/
├── .gitignore                     # Git 忽略规则
├── README.md                      # 项目说明文档
├── README.release                 # 发布说明文档
├── .env                           # 环境变量配置（本地开发）
├── .env.example                   # 环境变量配置模板
├── docker-compose.yml             # 服务编排核心定义（开发环境）
├── guides/                        # 详细指南文档目录
│   └── WordPress + Docker Compose 多阶段构建与生产环境最佳实践指南 (GitHub Actions 自动化版).md # 完整集成指南
├── .github/                       # GitHub Actions 工作流目录
│   ├── version-monitor-and-build.yml # 版本监控与自动构建工作流（包含build-and-push.yml的所有功能）
│   ├── version-monitor.yml        # 版本监控工作流
│   └── verify-only.yml            # 配置验证工作流
├── build/                         # 构建相关文件
│   ├── Dockerfiles/               # 各服务的 Dockerfile 目录
│   │   ├── base/                  # 共享 Alpine Base 镜像
│   │   ├── php/                   # PHP-FPM Dockerfile
│   │   ├── nginx/                 # Nginx Dockerfile
│   │   ├── mariadb/               # MariaDB Dockerfile
│   │   └── redis/                 # Redis Dockerfile
│   ├── deploy_configs/            # 部署配置目录
│   │   ├── php/                   # PHP 配置
│   │   ├── nginx/                 # Nginx 配置
│   │   ├── mariadb/               # MariaDB 配置
│   │   └── redis/                 # Redis 配置
│   └── scripts/                   # 构建脚本目录
│       ├── check_versions.sh      # 版本检查脚本
│       ├── mariadb/               # MariaDB 脚本
│       ├── redis/                 # Redis 脚本
│       └── test-build.sh          # 构建测试脚本
├── deploy/                        # 部署相关文件
│   ├── .env.example               # 部署环境变量模板
│   ├── docker-compose.yml         # 生产环境服务编排配置
│   ├── configs/                   # 配置文件目录
│   └── scripts/                   # 部署脚本目录
│       └── auto_deploy.sh         # 自动化部署脚本
└── html/                          # WordPress 源码目录
```

## 快速开始

### 开发环境

1. **安装依赖**
   - 确保已安装 Docker 和 Docker Compose

2. **初始化项目**
   ```bash
   git clone <仓库地址> wp-docker
   cd wp-docker
   ```

3. **配置环境**
   - 开发环境默认使用本地构建，可以直接修改 `docker-compose.yml` 文件中的配置
   - Nginx 配置位于 `build/deploy_configs/nginx/` 目录
   - PHP 配置位于 `build/deploy_configs/php/php.ini` 文件
   - MariaDB 配置位于 `build/deploy_configs/mariadb/my.cnf` 文件
   - Redis 配置位于 `build/deploy_configs/redis/redis.conf` 文件

4. **启动服务**
   ```bash
   docker-compose up -d --build
   ```

5. **完成 WordPress 安装**
   - 访问 `http://localhost` 完成安装向导

### 生产环境

1. **准备工作**
   - 在 GitHub 仓库设置中配置 Docker Hub 凭据：`DOCKERHUB_USERNAME` 和 `DOCKERHUB_TOKEN`
   - 将代码推送到 GitHub 仓库的 `main` 分支，触发 GitHub Actions 自动构建镜像

2. **使用自动部署脚本（推荐）**
   ```bash
   # 在生产服务器上
   git clone <仓库地址> wp-docker
   cd wp-docker
   chmod +x deploy/scripts/auto_deploy.sh
   ./deploy/scripts/auto_deploy.sh
   ```
   
   脚本特性：
   - 自动创建专用部署目录，避免在系统目录直接部署
   - 提供交互式目录名称设置（默认：wordpress-docker）
   - 使用自定义构建的Nginx镜像代替官方镜像
   - 自动生成安全的密码和WordPress密钥
   - 一键完成所有配置、下载和启动流程

3. **手动部署（可选）**
   ```bash
   # 在生产服务器上
   git clone <仓库地址> wp-docker
   cd wp-docker/deploy
   # 下载 WordPress
   wget https://wordpress.org/latest.tar.gz
   tar -xvzf latest.tar.gz
   mv wordpress/* html/
   rm -rf wordpress latest.tar.gz
   # 拉取并启动服务
   docker-compose pull
   docker-compose up -d
   ```

4. **完成 WordPress 安装**
    - 访问服务器 IP 地址完成安装向导
    - 推荐安装并配置 Redis Object Cache 插件以启用缓存功能

## 开发工作流

1. **创建和管理分支**
   - `main` 分支：永远保持稳定、可部署的状态
   - 功能分支：每次开发新功能或修复 Bug，都从 `main` 分支创建一个新分支
   - 分支命名示例：`feat/nginx-gzip`、`fix/php-upload-size`

2. **编写有意义的 Commit Message**
   遵循 Conventional Commits 规范：
   ```bash
   git add build/Dockerfiles/nginx/conf.d/default.conf
   git commit -m "feat(nginx): 开启 Gzip 压缩以提高页面加载速度"
   ```

3. **Pull Request 和代码审查**
   - 将功能分支推送到远程仓库
   - 创建 Pull Request，目标分支为 `main`
   - 邀请团队成员进行代码审查
   - 审查通过后合并到 `main` 分支

4. **自动化构建和部署**
   - 合并到 `main` 分支后，GitHub Actions 会自动触发：
     - 构建多阶段 PHP 和 Nginx 镜像
     - 推送镜像到 Docker Hub
     - 更新版本锁定文件
     - 测试镜像可用性
   - 生产部署：在目标服务器上运行 `./deploy/scripts/auto_deploy.sh` 或在 `deploy` 目录中执行 `docker-compose pull && docker-compose up -d`

## 注意事项

- **安全实践**: 生产环境请确保使用 `deploy/scripts/auto_deploy.sh` 脚本生成安全的密码和密钥，不要使用默认值
- **定期备份**: 定期备份数据库和重要文件，特别是 `html` 目录下的内容和数据库
- **版本管理**: 遵循文档中的最佳实践进行环境管理，使用精确版本号而非 `latest` 标签，版本信息存储在 `build/Dockerfiles/*/*_version.txt` 文件中
- **配置管理**: 
  - Nginx 配置位于 `build/deploy_configs/nginx/` 目录
  - PHP 配置位于 `build/deploy_configs/php/php.ini` 文件
  - MariaDB 配置位于 `build/deploy_configs/mariadb/my.cnf` 文件
  - Redis 配置位于 `build/deploy_configs/redis/redis.conf` 文件
  - 所有配置均支持通过环境变量进行动态调整
- **故障排除**: 如遇到镜像拉取失败，检查 `.env` 文件中的版本号是否正确或查看 GitHub Actions 构建日志
- **环境变量**: 所有环境变量配置可参考 `.env.example` 文件

## 已实现的高级功能

1. **动态版本管理**
   - 自动提取并使用精确的 PHP、Nginx、MariaDB 和 Redis 版本
   - 避免使用不稳定的 `latest` 标签
   - 版本信息存储在专用的版本锁定文件中

2. **多阶段构建优化**
   - 使用共享 Alpine Base 镜像减少重复依赖下载
   - 分离构建和运行环境，减小最终镜像体积
   - 所有组件（PHP、Nginx、MariaDB、Redis）均采用多阶段构建

3. **全栈自定义配置**
   - WordPress 专用的 MariaDB 数据库配置，优化查询性能
   - 高性能 Redis 缓存配置，支持对象缓存和会话管理
   - 针对 WordPress 优化的 PHP-FPM 配置，启用所有必要扩展
   - 安全且高性能的 Nginx 配置，包含 Gzip、缓存控制和安全头

4. **安全增强**
   - 部署脚本自动生成 WordPress 安全密钥
   - 生成不含特殊字符的随机用户名和强密码
   - 容器内文件权限严格控制
   - 自动禁止访问敏感文件和目录
   - 支持 Redis 密码认证

5. **自动版本监控与构建**
   - GitHub Actions 工作流 `version-monitor-and-build.yml` 定期自动检查所有依赖版本更新
   - 检测到新版本时自动触发构建和发布
   - 支持自定义检查频率和通知配置
   - 自动生成详细的版本更新日志

6. **自动化部署**
   - `scripts/auto_deploy.sh` 脚本集成完整部署流程
   - 支持开发环境和生产环境快速部署
   - 自动创建目录、下载 WordPress、生成配置、启动服务
   - 集成服务健康检查，确保部署成功

7. **性能优化**
   - 数据库连接池和查询缓存配置
   - Redis 内存优化和淘汰策略
   - PHP OPcache 优化配置
   - Nginx 静态文件缓存和压缩

## 未来优化方向

- 添加数据库自动备份功能
- 实现 HTTPS 证书自动获取和更新
- 添加更多性能优化配置
- 完善监控和告警体系