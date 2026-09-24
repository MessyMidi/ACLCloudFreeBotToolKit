[English](README.md) | [简体中文](README.zh-CN.md)

<img width="2172" height="724" alt="ACLCloudFreeBotToolKit" src="https://github.com/user-attachments/assets/f6caea1c-3be7-432b-9c20-b0cd9151036b" />

# ACLCloudFreeBotToolKit

面向 ACLClouds Free Bot 的配置生成器和运行工具。通过浏览器生成 `config.env` 与 Startup Command，在非 root 容器中运行 Mihomo、Lite/Komari 和自动延期任务。

[Releases](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases) · [Issues](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/issues)

## 功能

- 部署 Mihomo + VLESS REALITY，首次启动时生成并保存连接参数。
- 接入 Lite 或 Komari 探针，可单独启用监控。
- 可选的 ACLClouds 自动延期，支持 CAPTCHA 处理和 Telegram 通知。
- 自动下载、校验并更新运行文件；更新失败时继续使用本地版本。
- Mihomo、监控与自动延期可以独立启用。

当前发布资源适用于 Linux AMD64。

## 快速开始

在本地启动配置生成器：

```bash
npm install
npm run dev
```

打开页面并选择需要的模块，然后按页面提示完成部署：

1. 在 ACLClouds Bot 的文件管理器中创建名为 `config`、类型为 `Env (.env)` 的文件，粘贴生成的 `config.env`。
2. 在 Startup 页面粘贴生成的 Startup Command。
3. 启动或重启容器。

`SERVER_IP` 与 `SERVER_PORT` 由 ACLClouds 注入，无需写入配置。首次启动需要连接 GitHub Releases 下载运行文件。

## 配置与数据

生成器没有后端。表单内容保存在当前站点的浏览器 `localStorage` 中，不会写入 URL；页面内可以清除已保存的配置。

启用自动延期后，账号信息会写入 `config.env`。请勿公开该文件，也不要在公共设备上保存配置。运行时认证缓存和日志保存在容器的 `data/` 与 `logs/` 目录中。

## 开发

```bash
npm test
npm run lint
npm run typecheck
npm run build
```

构建结果位于 `dist/`。

## 许可证

本项目采用 [GNU AGPL v3.0 only](LICENSE) 许可证，并受 [附加条款](ADDITIONAL_TERMS.md) 约束。第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
