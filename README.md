- # WordPress + Docker Compose 项目 (GitHub Actions 自动化版)

  本项目使用 Docker Compose 部署 WordPress 生产环境，结合官方/自定义镜像，集成 GitHub Actions 实现 CI/CD 自动化，确保一致性与效率。详细指南见 guides/ 目录。

  ## 项目结构

  text

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