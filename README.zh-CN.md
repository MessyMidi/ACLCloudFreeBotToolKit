[English](README.md) | [简体中文](README.zh-CN.md)

<img width="2172" height="724" alt="ACLCloudFreeBotToolKit" src="https://github.com/user-attachments/assets/f6caea1c-3be7-432b-9c20-b0cd9151036b" />

# ACLCloudFreeBotToolKit

面向 ACLClouds Free Bot 的配置生成器和运行工具。通过浏览器生成 `config.env` 与 Startup Command，在非 root 容器中运行 Mihomo、Lite、Komari、CF Server Monitor 和自动延期任务。

[Releases](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases) · [Issues](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/issues)

## 功能

- 部署 Mihomo + VLESS REALITY，首次启动时生成并保存连接参数；代理用户无法通过节点访问内网和本机地址。
- 接入 Lite、Komari 或 CF Server Monitor 探针，可单独启用监控。
- 可选的 ACLClouds 自动延期，支持 CAPTCHA 处理和 Telegram 通知；检查失败会在 30 分钟后重试，并逐次拉长间隔。
- 自动下载、校验并更新运行文件；更新失败时继续使用本地版本。新版本无法启动或启动时崩溃会自动回滚，7 天内不再安装同一版本，除非发布了更新的版本。
- Mihomo 和 Monitor 异常退出后按指数退避自动拉起，连续五次失败后在 Console 明确提示并停止自动重试。
- Mihomo、监控与自动延期可以独立启用；服务日志会限制大小。
- 生成器页面和 Console 菜单支持中文与英文。

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

生成器没有后端。表单内容保存在当前站点的浏览器 `localStorage` 中，不会写入 URL；页面内可以清除已保存的配置。自动延期的账号密码、Telegram Bot Token 和 Chat ID 属于密钥，只有勾选自动延期模块中的“在此浏览器记住密码和 Token 等”后才会保存。Monitor 安装命令（含探针 Token）与其他表单字段一样，会随配置一起保存。

启用自动延期后，账号信息会写入 `config.env`。请勿公开该文件，也不要在公共设备上保存配置。launcher 不会把这些凭据传给 Mihomo 或监控探针。运行时认证缓存和日志保存在容器的 `data/` 与 `logs/` 目录中。

`config.env` 可选设置：

| 设置 | 默认值 | 作用 |
| --- | --- | --- |
| `CONSOLE_LANG` | `zh` | Console 菜单语言，`zh` 或 `en`。生成器会写入当前页面语言。 |
| `MIHOMO_BLOCK_PRIVATE_NETWORKS` | `1` | 设为 `0` 时允许代理用户访问内网、本机和链路本地地址。 |
| `LOG_MAX_BYTES` | `5242880` | `logs/mihomo.log` 与 `logs/monitor.log` 超过该大小时只保留最新部分。 |
| `WATCHDOG_MAX_RESTARTS` | `5` | 看门狗放弃前的崩溃重启次数（1–10）。 |

## 更新安全

自动更新会校验下载的文件与同一个 GitHub Release 中的 `SHA256SUMS` 一致。这能发现损坏或不完整的下载，但无法证明发布者身份：一旦有人控制了本仓库的 Release，就能发布可以通过校验的文件，开启自动更新的容器会在约 6 小时内安装它们。而启用自动延期时，这些容器中保存着 ACLClouds 账号凭据。

由 Release 工作流创建的版本在 GitHub Actions 中从打了标签的提交构建，可以用下面的命令核验构建来源：

```bash
gh attestation verify acl-renew-linux-amd64 --repo MessyMidi/ACLCloudFreeBotToolKit
```

如果希望在运行前审查每个版本，请在生成器中关闭自动更新，Startup Command 会改为传入 `--AUTO_UPDATE=disable`。

## 开发

```bash
npm test
npm run lint
npm run typecheck
npm run build
```

构建结果位于 `dist/`。Shell 生命周期测试通过 `bash tests/bootstrap.test.sh` 和 `bash tests/launcher-modes.test.sh` 运行。

延期助手使用当前的 Cap.js v2 `hashwx` 工作量证明流程。官方 `@cap.js/wasm` v0.0.8 内核已嵌入 Go 二进制，并由 wazero 执行，运行时不会下载代码。版本、来源与许可证信息见 `THIRD_PARTY_NOTICES.md`。

发布新版本时运行 `npm version <版本号>`（会同时更新运行脚本中的版本号），再推送提交和标签。Release 工作流会测试并构建该标签，然后创建草稿 Release；检查无误后手动发布。

## 许可证

本项目采用 [GNU AGPL v3.0 only](LICENSE) 许可证，并受 [附加条款](ADDITIONAL_TERMS.md) 约束。第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
