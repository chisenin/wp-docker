# WordPress + Docker Compose 项目

本项目使用 Docker Compose 部署 WordPress 生产环境，采用多阶段构建优化镜像，确保环境一致性和稳定性。

## 项目结构

```
wp-docker/
├── .gitignore                     # Git 忽略规则
├── README.md                      # 项目说明文档
├── docker-compose.yml             # 服务编排核心定义
├── configs/                       # 所有服务的配置文件统一存放
│   ├── nginx/                     # Nginx 配置
│   └── php/                       # PHP 配置
├── Dockerfiles/                   # 各服务的 Dockerfile 目录
│   ├── php/                       # PHP-FPM Dockerfile
│   └── nginx/                     # Nginx Dockerfile
└── html/                          # WordPress 源码目录
```

## 快速开始

1. **安装依赖**
   - 确保已安装 Docker 和 Docker Compose

2. **初始化项目**
   ```bash
   git clone <仓库地址> wp-docker
   cd wp-docker
   ```

3. **配置环境**
   - 修改 `docker-compose.yml` 中的数据库密码等敏感信息
   - 根据需要调整 `configs/nginx/` 和 `configs/php/` 下的配置文件

4. **启动服务**
   ```bash
   docker-compose up -d --build
   ```

5. **完成 WordPress 安装**
   - 访问 `http://localhost` 完成安装向导

## 开发工作流

1. 从 `main` 分支创建功能分支
2. 进行开发和修改
3. 创建 Pull Request 请求代码审查
4. 审查通过后合并到 `main` 分支
5. 部署更新：`git pull origin main && docker-compose up -d --build`

## 注意事项

- 生产环境请确保修改所有默认密码
- 定期备份数据库和重要文件
- 遵循文档中的最佳实践进行环境管理