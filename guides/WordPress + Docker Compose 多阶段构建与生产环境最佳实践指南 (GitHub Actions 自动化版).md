# WordPress + Docker Compose 多阶段构建与生产环境最佳实践指南 (GitHub Actions 自动化版)

本指南概述现代化 WordPress 部署方案：Docker Compose 编排、多阶段构建、GitHub Actions CI/CD。

## 核心理念

- 确定性：精确版本（非 latest）。
- Alpine 统一基镜。
- 多阶段构建：轻量生产镜像。
- 配置即代码：PR 审查。
- CI/CD：自动构建/测试/推送。
- 版本监控：定期更新触发。

## 项目结构

同 README（精简版）。

## 工作流程

1. **Windows 本地**：代码/配置修改，无需本地 Docker。
2. **Actions 构建**：镜像构建/推送，使用项目配置参考。
3. **Linux 部署**：auto_deploy.sh 生成 .env/docker-compose.yml，拉取镜像启动。

## Docker Compose 配置要点 (docker-compose.yml)

- 服务：mariadb, redis, php, nginx。
- 特点：健康检查、依赖、卷挂载配置、环境变量版本控制。
- 生产：auto_deploy.sh 动态生成。

## 镜像构建要点

- **Base**：Alpine + 时区/工具。
- **PHP**：多阶段，安装 WP 扩展/Redis/Composer，复制配置。
- **Nginx**：复制配置，权限设置。
- **MariaDB/Redis**：基于官方，多阶段复制配置/入口脚本，渐进自定义。

## Nginx 配置要点

- 全局：worker auto, 日志, Gzip。
- WP 站点：静态缓存、安全头、PHP 快CGI、敏感文件禁止、XML-RPC 限流。

## GitHub Actions

同 README（模块化、动态矩阵、Releases 生成 .env/docker-compose.yml）。

## 部署

同 README 一键/手动，从 Releases 下载。

## 跨平台注意

- Redis：auto_deploy.sh 移除容器 sysctl，避免 OCI 错误；宿主机建议 vm.overcommit_memory=1。
- 行尾：.gitattributes + 脚本自动转换 (dos2unix/sed)。
- 权限：部署时 chmod +x，.env 600。
- .env：避免特殊字符，部署时生成。

## 总结

稳定、高效、可维护：动态锁定、多阶段、自动化、跨平台兼容。参考项目文件配置。
---