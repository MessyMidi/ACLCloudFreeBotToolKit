
[English](README.md) | [简体中文](README.zh-CN.md)

<img width="2172" height="724" alt="ACLCloudFreeBotToolKit" src="https://github.com/user-attachments/assets/f6caea1c-3be7-432b-9c20-b0cd9151036b" />

# ACLCloudFreeBotToolKit

A configuration generator and runtime helper for ACLClouds Free Bot. Use the Web generator to create `config.env` and a Startup Command for running Mihomo, Lite, Komari, CF Server Monitor, and automatic renewal jobs in a non-root container.

**[Online Config Generator](https://messymidi.github.io/ACLCloudFreeBotToolKit/)** · [Releases](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases) · [Issues](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/issues)

---

## Quick Start

1. Open the [Online Config Generator](https://messymidi.github.io/ACLCloudFreeBotToolKit/).
2. Enable the features you need and fill in their settings.
3. In the ACLClouds Bot file manager, create a new file:
   - Name: `config`
   - Type: `Env (.env)`
4. Paste the generated `config.env` into the file.
5. Paste the generated Startup Command into the **Startup** page.
6. Start or restart the Bot.

`SERVER_IP` and `SERVER_PORT` are provided automatically by ACLClouds and do not need to be entered manually.

The required runtime files are downloaded on first start. Generated VLESS parameters, authentication state, and other runtime data are then kept inside the container. Keep them private and **do not share accounts or credentials with anyone you do not trust**.

---

## Features

### Mihomo + VLESS REALITY

UUID, REALITY Key, and Short ID are generated on first start and saved in the container. The generated VLESS link can be viewed directly from the Console after startup.

Note: proxy clients are blocked from accessing the host, private networks, and link-local addresses through the node by default.

### Lite / Komari / CF Server Monitor

Supports [Lite](https://github.com/nuomiiiii/Lite), [Komari](https://github.com/komari-monitor/komari), and [CF Server Monitor](https://github.com/huilang-me/CF-Server-Monitor). Paste the agent install command into the generator to parse its Endpoint, Token / Secret, and other settings.

The monitor can run alongside Mihomo or on its own.

### ACLClouds Automatic Renewal

The optional renewal job checks the current ACLClouds service periodically and renews it once renewal becomes available. It determines whether renewal is currently allowed, handles the verification flow, and retries after failures. Telegram notifications can be enabled if needed.

No separate GitHub Actions workflow or extra server is required. The renewal helper runs directly inside the current Bot.

### Automatic Updates

By default, Toolkit follows stable releases published on GitHub.

Runtime files are downloaded from the corresponding Release and verified against the `SHA256SUMS` included with that Release.

If a new version fails while switching over or starting up, Toolkit restores the previous working version instead of leaving the Bot offline.

Automatic updates can be disabled from the config generator or by changing `--AUTO_UPDATE=enable` to `--AUTO_UPDATE=disable` in the Startup Command, then restarting the Bot.

### Console

After startup, the ACLClouds Console menu can be used to check service status and view Mihomo, monitor, and automatic renewal logs.

---

## Data and Privacy

The config generator has no backend. Your configuration is not submitted to a server operated by this project.

Some form data is saved in the browser's local storage so it survives a page refresh. Sensitive values such as the ACLClouds password and Telegram Token are stored in the browser only if you explicitly choose to remember them.

The Monitor install command, including its Token / Secret, is saved with the other form data. Clear the saved configuration after using a shared browser.

The generated `config.env` may contain:

- Lite / Komari Token
- CF Server Monitor Secret
- ACLClouds username and password
- Telegram Bot Token / Chat ID

Keep `config.env` private and **do not share these accounts or credentials with anyone you do not trust**.

Runtime data is mainly stored in:

```text
data/    Persistent state, authentication data, and generated connection parameters
logs/    Mihomo, Monitor, and automatic renewal logs
bin/     Runtime binaries
```

---

## License

This project is licensed under **GNU AGPL v3.0 only**, with the additional terms in [ADDITIONAL_TERMS.md](ADDITIONAL_TERMS.md).

Third-party components and their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
