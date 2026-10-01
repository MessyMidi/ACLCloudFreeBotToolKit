[English](README.md) | [简体中文](README.zh-CN.md)

<img width="2172" height="724" alt="ACLCloudFreeBotToolKit" src="https://github.com/user-attachments/assets/f6caea1c-3be7-432b-9c20-b0cd9151036b" />

# ACLCloudFreeBotToolKit

面向 ACLClouds Free Bot 的配置生成器和运行工具。通过 Web 生成 config.env 与 Startup Command，在非 root 容器中运行 Mihomo、Lite、Komari、CF Server Monitor 和自动延期任务。

**[在线配置生成器](https://acftoolkit.otokonoko.de/)** · [GitHub Pages](https://messymidi.github.io/ACLCloudFreeBotToolKit/) · [Releases](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases) · [Issues](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/issues)

---

## 快速开始

1. 打开 [在线配置生成器](https://acftoolkit.otokonoko.de/)。
2. 选择需要的功能并填写配置。
3. 在 ACLClouds Bot 的文件管理器中新建文件：
   - 文件名：`config`
   - 类型：`Env (.env)`
4. 粘贴页面生成的 `config.env`。
5. 将生成的 Startup Command 粘贴到 ACLClouds 的 **Startup** 页面。
6. 启动或重启 Bot。

`SERVER_IP` 和 `SERVER_PORT` 会由 ACLClouds 自动注入，不需要手动填写。

第一次启动会下载所需的运行文件。之后生成的 VLESS 参数、认证状态等数据都会保存在容器内，请妥善保管，**不要与非可信赖个体分享这些账号或凭据**。

---

## 能力

### Mihomo + VLESS REALITY

首次启动自动生成 UUID、REALITY Key 和 Short ID，并保存到容器中。启动后可以直接在 Console 中查看生成的 VLESS 链接。
注：默认会阻止代理客户端通过节点访问本机、内网和链路本地地址。

### Lite / Komari / CF Server Monitor

支持[Lite](https://github.com/nuomiiiii/Lite)、[Komari](https://github.com/komari-monitor/komari)、[CF Server Monitor](https://github.com/huilang-me/CF-Server-Monitor)，直接将探针安装命令粘贴到生成器中即可解析 Endpoint、Token / Secret 等参数。

探针可以和 Mihomo 一起运行，也可以单独部署。

### ACLClouds 自动延期

可选的自动延期任务会定期检查当前 ACLClouds 服务，在进入可延期状态后自动完成延期。延期任务负责判断是否可以延期，并处理验证和失败重试；Telegram 通知可按需开启。
不需要额外运行 GitHub Actions 或另一台服务器，延期程序直接运行在当前 Bot 中。

### 自动更新

默认情况下，Toolkit 会自动跟随 GitHub 上发布的稳定版本。
更新时会下载对应 Release 中的运行文件，并使用同一 Release 提供的 `SHA256SUMS` 进行校验。
如果新版本在切换或启动阶段出现问题，会自动恢复到之前可以正常运行的版本，而不是让整个 Bot 因为一次坏更新直接下线。
如果不希望自动更新，可在配置生成器中关闭，或将 Startup Command 中的 `--AUTO_UPDATE=enable` 改为 `--AUTO_UPDATE=disable`，然后重启 Bot。

### Console

启动完成后，可以直接在 ACLClouds Console 中使用菜单查看：当前服务状态、Mihomo/探针/自动延期日志等

---

## 数据与隐私

配置生成器无后端，配置不会提交到本项目的服务器。

为了刷新页面后保留填写进度，部分表单内容会保存在浏览器的本地存储中。ACLClouds 密码、Telegram Token 等敏感内容只有在主动选择“记住”时才会保存在浏览器中。

Monitor 安装命令（包含 Token / Secret）会与其他表单内容一起保存。在公共或共享浏览器中使用后，请清除已保存的配置。

生成的 `config.env` 可能包含：

- Lite / Komari Token
- CF Server Monitor Secret
- ACLClouds 用户名和密码
- Telegram Bot Token / Chat ID

请妥善保管 `config.env` ，**不要与非可信赖个体分享这些账号或凭据**。

容器运行产生的数据主要保存在：

```text
data/    持久化状态、认证信息、生成的连接参数
logs/    Mihomo、Monitor、自动延期日志
bin/     运行时二进制
```

---

## License

本项目使用 **GNU AGPL v3.0 only**许可证，并受 [ADDITIONAL_TERMS.md](ADDITIONAL_TERMS.md) 中的附加条款约束。

第三方组件及许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
