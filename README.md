# WordPress + Docker Compose 项目 (GitHub Actions 自动化版)
---
本项目使用 Docker Compose 部署 WordPress 生产环境，采用多阶段构建优化镜像，并集成 GitHub Actions 实现 CI/CD 自动化，确保环境一致性、稳定性和部署效率。

**注意**: 详细指南文档已移至 `guides/` 目录，包含从介绍到部署的完整步骤说明。

**主要特性**: 动态版本锁定、共享Base镜像、配置即代码、自动化部署脚本、安全实践集成
---
## 项目结构

```
wp-docker/
├── .gitignore                     # Git 忽略规则
├── README.md                      # 项目说明文档
├── .env.example                   # 环境变量配置模板
├── docker-compose.yml             # 服务编排核心定义
├── guides/                        # 详细指南文档目录
│   ├── 01. 介绍与核心理念.md           # 项目介绍与设计理念
│   ├── 02. 项目目录结构与Git初始化.md     # 目录结构与初始化步骤
│   ├── 03. Docker Compose配置.md      # Docker Compose 配置说明
│   ├── 04. Base镜像构建.md           # Base 镜像构建指南
│   ├── 05. PHP镜像构建.md            # PHP 镜像构建指南
│   ├── 06. Nginx镜像构建.md          # Nginx 镜像构建指南
│   ├── 07. GitHub Actions自动化构建.md # CI/CD 工作流配置
│   ├── 08. Git工作流与变更管理.md      # Git 工作流规范
│   ├── 09. 部署与验证.md             # 部署流程与验证步骤
│   └── 10. 无构建部署阶段.md          # 生产环境无构建部署
├── .github/                       # GitHub Actions 工作流目录
│   └── workflows/
│       └── build-and-push.yml     # 自动化构建工作流
├── configs/                       # 所有服务的配置文件统一存放
│   ├── nginx/                     # Nginx 配置
│   │   ├── nginx.conf             # Nginx 主配置
│   │   └── conf.d/
│   │       └── default.conf       # 站点配置
│   └── php/                       # PHP 配置
│       └── php.ini                # PHP 配置文件
├── Dockerfiles/                   # 各服务的 Dockerfile 目录
│   ├── base/                      # 共享 Alpine Base 镜像
│   │   └── Dockerfile             # Base 镜像构建定义
│   ├── php/                       # PHP-FPM Dockerfile
│   │   └── Dockerfile             # PHP 镜像构建定义
│   └── nginx/                     # Nginx Dockerfile
│       └── Dockerfile             # Nginx 镜像构建定义
├── scripts/                       # 辅助脚本目录
│   ├── deploy.sh                  # 部署脚本（生成.env文件）
│   └── check_versions.sh          # 版本监控脚本（测试中）
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

3. **下载 WordPress**
   ```bash
   wget https://wordpress.org/latest.tar.gz
   tar -xvzf latest.tar.gz
   mv wordpress/* html/
   rm -rf wordpress latest.tar.gz
   ```

4. **配置环境**
   - 对于开发环境，取消注释 `docker-compose.yml` 中 PHP 和 Nginx 服务的 `build` 部分，注释掉 `image` 部分
   - 根据需要调整 `configs/nginx/` 和 `configs/php/` 下的配置文件

5. **生成环境配置**
   ```bash
   chmod +x scripts/deploy.sh
   ./scripts/deploy.sh
   ```

6. **启动服务**
   ```bash
   docker-compose up -d --build
   ```

5. **完成 WordPress 安装**
   - 访问 `http://localhost` 完成安装向导

### 生产环境

1. **准备工作**
   - 在 GitHub 仓库设置中配置 Docker Hub 凭据：`DOCKERHUB_USERNAME` 和 `DOCKERHUB_TOKEN`
   - 将代码推送到 GitHub 仓库的 `main` 分支，触发 GitHub Actions 自动构建镜像

2. **部署**
   ```bash
   # 在生产服务器上
   git clone <仓库地址> wp-docker
   cd wp-docker
   # 下载 WordPress
   wget https://wordpress.org/latest.tar.gz
   tar -xvzf latest.tar.gz
   mv wordpress/* html/
   rm -rf wordpress latest.tar.gz
   # 生成环境配置
   chmod +x scripts/deploy.sh
   ./scripts/deploy.sh
   # 拉取并启动服务
   docker-compose pull
   docker-compose up -d
   ```

3. **完成 WordPress 安装**
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
   git add configs/nginx/conf.d/default.conf
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
     - 测试镜像可用性
   - 生产部署：`docker-compose pull && docker-compose up -d`

## 注意事项

- **安全实践**: 生产环境请确保使用部署脚本生成安全的密码和密钥，不要使用默认值
- **定期备份**: 定期备份数据库和重要文件
- **版本管理**: 遵循文档中的最佳实践进行环境管理，使用精确版本号而非 `latest` 标签
- **故障排除**: 如遇到镜像拉取失败，检查 `.env` 文件中的版本号是否正确
- **配置参考**: 所有环境变量配置可参考 `.env.example` 文件

## 已实现的高级功能

1. **动态版本管理**
   - 自动提取并使用精确的 PHP 和 Nginx 版本
   - 避免使用不稳定的 `latest` 标签

2. **多阶段构建优化**
   - 使用共享 Alpine Base 镜像减少重复依赖下载
   - 分离构建和运行环境，减小最终镜像体积

3. **安全增强**
   - 部署脚本自动生成 WordPress 安全密钥
   - 生成不含特殊字符的随机用户名和强密码
   - 容器内文件权限严格控制

4. **版本监控（测试中）**
   - `scripts/check_versions.sh` 脚本可检查依赖版本更新
   - 支持多平台构建检测

## 未来优化方向

- 全面测试版本监控功能并集成到 CI/CD 流程
- 添加数据库自动备份功能
- 实现 HTTPS 证书自动获取和更新
- 添加更多性能优化配置