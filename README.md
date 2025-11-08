- # WordPress + Docker Compose 项目 (GitHub Actions 自动化版)

  本项目使用 Docker Compose 部署 WordPress 生产环境，结合官方/自定义镜像，集成 GitHub Actions 实现 CI/CD 自动化，确保一致性与效率。详细指南见 guides/ 目录。

  ## 项目结构

## 项目结构
```
wp-docker/
├── .gitignore
├── README.md
├── README.release
├── .env.example
├── docker-compose.yml  # 构建参考（非本地运行必需）
├── guides/             # 完整指南
├── .github/workflows/  # 模块化工作流
│   ├── module-base.yml
│   ├── module-mariadb.yml
│   ├── module-nginx.yml
│   ├── module-php.yml
│   ├── module-redis.yml
│   └── orchestrate-all.yml
├── build/
│   ├── Dockerfiles/    # 各服务 Dockerfile 及版本文件 (*_version.txt)
│   │   ├── base/
│   │   ├── mariadb/
│   │   ├── nginx/
│   │   ├── php/
│   │   └── redis/
│   ├── deploy_configs/ # 配置目录 (php, nginx, mariadb, redis)
│   └── scripts/        # check_versions.sh 等脚本
├── deploy/
│   ├── .env.example
│   ├── configs/
│   └── scripts/auto_deploy.sh  # 自动化部署
└── html/               # WordPress 源码
## 快速开始

### 实际工作流程说明

重要说明 ：本项目采用 Windows 本地开发、GitHub Actions 构建、Linux 远程部署的工作流。

* 本地 Windows 环境 ：

  - 不需要 `.env` 和 `docker-compose.yml` 文件用于本地运行
  - 这些文件主要用于构建配置和 GitHub Actions 工作流
  - 本地开发主要关注代码修改和提交
* 初始化项目
  git clone <仓库地址> wp-docker
  cd wp-docker

* 代码开发与提交

  * 修改源代码和配置文件
  * 提交到 GitHub，触发 GitHub Actions 构建

### 配置文件说明

* 核心配置文件 （ `docker-compose.yml` 和 `.env.example` ）：

  + 这些文件在 Windows 本地环境中 不需要用于运行服务
  + 它们的主要用途是为 GitHub Actions 构建过程提供配置参考
  + 生产环境的实际配置会由 `auto_deploy.sh` 脚本根据目标 Linux 服务器环境动态生成
* 服务配置文件 ：

  - Nginx 配置位于 `build/deploy_configs/nginx/` 目录
  - PHP 配置位于 `build/deploy_configs/php/php.ini` 文件
  - MariaDB 和 Redis 配置：现使用官方镜像，配置通过环境变量传递

这些配置文件会被 GitHub Actions 用于构建镜像，并在生产环境中通过 `auto_deploy.sh` 脚本自动应用。在 Windows 本地开发环境中，您只需关注代码修改和配置文件的编辑，无需本地运行 Docker 容器。

### 生产环境

0. 准备工作

  * 在 GitHub 仓库设置中配置 Docker Hub 凭据： `DOCKERHUB_USERNAME` 和 `DOCKERHUB_TOKEN`
  * 将代码推送到 GitHub 仓库的 `main` 分支，触发 GitHub Actions 自动构建镜像
1. 使用自动部署脚本（推荐）

在生产服务器上（推荐：从 GitHub Releases 下载最新部署脚本）
1. 下载最新 auto_deploy.sh
```
curl -L -o auto_deploy.sh 
https://github.com/chisenin/wp-docker/releases/latest/download/auto_deploy.sh
```
2. 添加执行权限并运行
  ```
  chmod +x auto_deploy.sh
  ./auto_deploy.sh
  ```

  脚本特性：

  * 自动创建专用部署目录，避免在系统目录直接部署
  * 提供交互式目录名称设置（默认：wordpress-docker）
  * 使用自定义构建的Nginx镜像代替官方镜像
  * 自动生成安全的密码和WordPress密钥
  * 一键完成所有配置、下载和启动流程
2. 增强的自动部署脚本

  - 自动检测操作系统环境（支持CentOS、Debian、Ubuntu、Alpine）
  - 智能收集系统参数并优化Docker资源配置
  - 自动设置数据库备份（每日3点备份，保留7天）
  - 磁盘空间监控与自动清理功能（80%使用率触发）
  - 自动安装缺失依赖并创建必要目录结构
  - 优化的Nginx和PHP配置，支持高并发环境
3. 完成 WordPress 安装

  * 访问服务器 IP 地址完成安装向导
  * 推荐安装并配置 Redis Object Cache 插件以启用缓存功能

## 开发工作流

0) 创建和管理分支

  * `main` 分支：永远保持稳定、可部署的状态
  * 功能分支：每次开发新功能或修复 Bug，都从 `main` 分支创建一个新分支
  * 分支命名示例： `feat/nginx-gzip`、 `fix/php-upload-size`
1) 编写有意义的 Commit Message 遵循 Conventional Commits 规范：
>>>>>>> c74805e0cfc63c40a9094bd020783828dafbea7c

  ```
  wp-docker/
  ├── .gitignore
  ├── README.md
  ├── README.release
  ├── .env.example
  ├── docker-compose.yml  # 构建参考（非本地运行必需）
  ├── guides/             # 完整指南
  ├── .github/workflows/  # 模块化工作流
  │   ├── module-*.yml
  │   └── orchestrate-all.yml
  ├── build/
  │   ├── Dockerfiles/    # 各服务 Dockerfile 及版本文件 (*_version.txt)
  │   ├── deploy_configs/ # 配置目录 (php, nginx, mariadb, redis)
  │   └── scripts/        # check_versions.sh, test-build.sh 等
  ├── deploy/
  │   ├── .env.example
  │   ├── configs/
  │   └── scripts/auto_deploy.sh  # 自动化部署
  └── html/               # WordPress 源码
  ```

  ## GitHub Actions 工作流（模块化 + 动态版本）

  **设计理念**：模块化、动态读取版本（从 build/Dockerfiles/*/*_version.txt）、自动重构、部署零感知、手动调试支持。

  ### 5 个模块化工作流

  | 文件               | 职责                  | 镜像                | 手动触发 |
  | ------------------ | --------------------- | ------------------- | -------- |
  | module-base.yml    | Alpine Base           | chisenin/wp-base    | 是       |
  | module-php.yml     | PHP-FPM               | chisenin/wp-php     | 是       |
  | module-nginx.yml   | Nginx                 | chisenin/wp-nginx   | 是       |
  | module-mariadb.yml | 拉取/保存官方 MariaDB | chisenin/wp-mariadb | 是       |
  | module-redis.yml   | 拉取/保存官方 Redis   | chisenin/wp-redis   | 是       |

  ### 统一编排 (orchestrate-all.yml)

  - **触发**：workflow_dispatch、每日 3 点、main 分支版本文件变更。
  - **流程**：动态读取版本 → 生成矩阵 → 并行调用模块工作流。
  - **自动重构**：上游更新 → check_versions.sh 检测 → 更新版本文件 → PR 合并 → 构建/推送。

  ### 镜像命名规范

  text

  ```
  chisenin/wp-base:alpine-<version>
  chisenin/wp-php:<version>-fpm
  chisenin/wp-nginx:<version>
  chisenin/wp-mariadb:<version>
  chisenin/wp-redis:<version>
  ```

  auto_deploy.sh 无需修改，直接拉取。

  ### 手动测试

  GitHub Actions → 选择模块 → Run workflow → 输入参数（如 php_version）。

  ### 版本管理

  - 文件：build/Dockerfiles/*/*_version.txt。
  - 更新：手动/PR 或 check_versions.sh 自动检测。

  ### 已弃用

  build-images.yml 等，移至 _deprecated/。

  ## 快速开始（Windows 本地开发 → Linux 部署）

  - **本地**：修改代码/配置 → 提交 → 触发 Actions 构建。
  - **部署**：无需克隆，从 Releases 下载最新包。

  ### 一键部署

  bash

  ```
  curl -L https://github.com/chisenin/wp-docker/releases/latest/download/auto_deploy.sh | bash
  ```

  ### 手动部署

  bash

<<<<<<< HEAD
  ```
  mkdir -p ~/wp && cd ~/wp
  curl -L -o .env https://github.com/chisenin/wp-docker/releases/latest/download/.env
  curl -L -o docker-compose.yml https://github.com/chisenin/wp-docker/releases/latest/download/docker-compose.yml
  docker compose up -d
  ```

  访问 http://IP 完成安装，启用 Redis Object Cache。

  ## 开发工作流

  1. 分支：main (稳定)，feat/fix 分支。
  2. Commit：Conventional Commits。
  3. PR：审查 → 合并 → Actions 构建/推送/Release。

  ## MariaDB/Redis 策略（渐进收敛）

  | 场景      | 行为       | 镜像来源 | 说明         |
  | --------- | ---------- | -------- | ------------ |
  | Base 更新 | 强制重建   | 自定义   | 同步安全补丁 |
  | 配置变更  | 自定义构建 | 自定义   | 测试优化     |
  | 无变更    | 跳过       | 官方     | 零开销       |

  auto_deploy.sh 优先自定义，无则官方。

  ## 注意事项

  - 安全：auto_deploy.sh 生成随机密码/密钥。
  - 备份：定期 db/html。
  - 配置：环境变量动态调整，参考 .env.example。
  - 故障：检查 Actions 日志或 .env 版本。

  ## 已实现功能

  - 动态版本锁定。
  - 多阶段构建（共享 Alpine Base）。
  - 全栈自定义配置（WP 优化）。
  - 安全增强（权限、头、密钥）。
  - 自动版本监控/构建。
  - 高级部署（自适应、备份、清理）。
  - 性能优化（OPcache、缓存、压缩）。

  ## 未来方向

  - HTTPS 自动证书。
  - 监控/告警。
  - 负载均衡/蓝绿部署。
  - 集成 check_versions.sh 到 Actions。
  - 多架构/安全扫描。
=======
- 实现 HTTPS 证书自动获取和更新
- 完善监控和告警体系
- 添加负载均衡支持
- 实现蓝绿部署功能
>>>>>>> c74805e0cfc63c40a9094bd020783828dafbea7c
