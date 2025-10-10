# WordPress + Docker Compose 项目 (GitHub Actions 自动化版)

本项目使用 Docker Compose 部署 WordPress 生产环境，采用多阶段构建优化镜像，并集成 GitHub Actions 实现 CI/CD 自动化，确保环境一致性、稳定性和部署效率。

## 项目结构

```
wp-docker/
├── .gitignore                     # Git 忽略规则
├── README.md                      # 项目说明文档
├── docker-compose.yml             # 服务编排核心定义
├── .github/                       # GitHub Actions 工作流目录
│   └── workflows/
│       └── build-and-push.yml     # 自动化构建工作流
├── configs/                       # 所有服务的配置文件统一存放
│   ├── nginx/                     # Nginx 配置
│   └── php/                       # PHP 配置
├── Dockerfiles/                   # 各服务的 Dockerfile 目录
│   ├── php/                       # PHP-FPM Dockerfile
│   └── nginx/                     # Nginx Dockerfile
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
   - 修改 `docker-compose.yml` 中的数据库密码等敏感信息
   - 对于开发环境，取消注释 PHP 和 Nginx 服务的 `build` 部分，注释掉 `image` 部分
   - 根据需要调整 `configs/nginx/` 和 `configs/php/` 下的配置文件

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

2. **部署**
   ```bash
   # 在生产服务器上
   git clone <仓库地址> wp-docker
   cd wp-docker
   # 确保使用的是 image 配置而非 build 配置
   docker-compose pull
   docker-compose up -d
   ```

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

- 生产环境请确保修改所有默认密码
- 定期备份数据库和重要文件
- 遵循文档中的最佳实践进行环境管理