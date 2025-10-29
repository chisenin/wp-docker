# WordPress + Docker Compose 项目 (GitHub Actions 自动化版)
---
本项目使用 Docker Compose 部署 WordPress 生产环境，结合官方数据库镜像与自定义应用镜像，并集成 GitHub Actions 实现 CI/CD 自动化，确保环境一致性、稳定性和部署效率。

**注意**: 详细指南文档已移至 `guides/` 目录，包含从介绍到部署的完整步骤说明。

**主要特性**: 动态版本锁定、共享Base镜像、配置即代码、混合镜像策略（官方+自定义）、自动版本监控与构建、自动化部署脚本、安全实践集成
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
│   └── version-monitor-and-build.yml # 版本监控与自动构建工作流
├── build/                         # 构建相关文件
│   ├── Dockerfiles/               # 各服务的 Dockerfile 目录
│   │   ├── base/                  # 共享 Alpine Base 镜像
│   │   ├── php/                   # PHP-FPM Dockerfile
│   │   ├── nginx/                 # Nginx Dockerfile
│   │   ├── mariadb/               # MariaDB Dockerfile（已弃用，现使用官方镜像）
│   │   └── redis/                 # Redis Dockerfile（已弃用，现使用官方镜像）
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
│   ├── configs/                   # 配置文件目录
│   └── scripts/                   # 部署脚本目录
│       └── auto_deploy.sh         # 自动化部署脚本（增强版）
└── html/                          # WordPress 源码目录
```

## 快速开始

### 实际工作流程说明

**重要说明**：本项目采用 Windows 本地开发、GitHub Actions 构建、Linux 远程部署的工作流。

- **本地 Windows 环境**：
  - 不需要 `.env` 和 `docker-compose.yml` 文件用于本地运行
  - 这些文件主要用于构建配置和 GitHub Actions 工作流
  - 本地开发主要关注代码修改和提交

- **初始化项目**
  ```bash
  git clone <仓库地址> wp-docker
  cd wp-docker
  ```

- **代码开发与提交**
  - 修改源代码和配置文件
  - 提交到 GitHub，触发 GitHub Actions 构建

### 配置文件说明

- **核心配置文件**（`docker-compose.yml` 和 `.env.example`）：
  - 这些文件在 Windows 本地环境中**不需要用于运行服务**
  - 它们的主要用途是为 GitHub Actions 构建过程提供配置参考
  - 生产环境的实际配置会由 `auto_deploy.sh` 脚本根据目标 Linux 服务器环境动态生成

- **服务配置文件**：
  - Nginx 配置位于 `build/deploy_configs/nginx/` 目录
  - PHP 配置位于 `build/deploy_configs/php/php.ini` 文件
  - MariaDB 和 Redis 配置：现使用官方镜像，配置通过环境变量传递

这些配置文件会被 GitHub Actions 用于构建镜像，并在生产环境中通过 `auto_deploy.sh` 脚本自动应用。在 Windows 本地开发环境中，您只需关注代码修改和配置文件的编辑，无需本地运行 Docker 容器。

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

3. **增强的自动部署脚本**
   - 自动检测操作系统环境（支持CentOS、Debian、Ubuntu、Alpine）
   - 智能收集系统参数并优化Docker资源配置
   - 自动设置数据库备份（每日3点备份，保留7天）
   - 磁盘空间监控与自动清理功能（80%使用率触发）
   - 自动安装缺失依赖并创建必要目录结构
   - 优化的Nginx和PHP配置，支持高并发环境

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
   - 生产部署：在目标服务器上运行 `./deploy/scripts/auto_deploy.sh` 自动化脚本

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

6. **高级自动化部署**
   - 增强版 `auto_deploy.sh` 脚本集成完整部署和维护流程
   - 环境自适应：自动检测并适配不同Linux发行版
   - 系统资源智能优化：根据主机配置自动调整Docker资源参数
   - 自动数据库备份：每日定时备份，智能保留策略
   - 磁盘空间管理：监控使用率并自动清理Docker资源
   - 自动安装缺失依赖并创建必要目录结构

7. **性能优化**
   - 数据库连接池和查询缓存配置
   - Redis 内存优化和淘汰策略
   - PHP OPcache 优化配置
   - Nginx 静态文件缓存和压缩

## 未来优化方向

- 实现 HTTPS 证书自动获取和更新
- 完善监控和告警体系
- 添加负载均衡支持
- 实现蓝绿部署功能