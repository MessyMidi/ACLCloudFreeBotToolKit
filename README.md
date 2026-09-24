[English](README.md) | [简体中文](README.zh-CN.md)

<img width="2172" height="724" alt="ACLCloudFreeBotToolKit" src="https://github.com/user-attachments/assets/f6caea1c-3be7-432b-9c20-b0cd9151036b" />

# ACLCloudFreeBotToolKit

A configuration generator and runtime toolkit for ACLClouds Free Bot. It generates a `config.env` file and Startup Command in the browser, then runs Mihomo, Lite/Komari, and optional renewal checks in a non-root container.

[Releases](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases) · [Issues](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/issues)

## Features

- Runs Mihomo with VLESS REALITY and persists connection details after the first start.
- Connects a Lite or Komari monitoring agent.
- Optionally renews the current ACLClouds service, with CAPTCHA handling and Telegram notifications.
- Downloads, verifies, and updates runtime files while keeping the local version available if an update fails.
- Lets Mihomo, monitoring, and renewal run independently.

Current release assets target Linux AMD64.

## Quick start

Run the configuration generator locally:

```bash
npm install
npm run dev
```

Open the page, enable the modules you need, and follow the deployment steps shown there:

1. In the ACLClouds Bot file manager, create a file named `config` with the type `Env (.env)`, then paste the generated `config.env` content.
2. Paste the generated Startup Command into the Startup page.
3. Start or restart the container.

ACLClouds injects `SERVER_IP` and `SERVER_PORT`; do not add them to the configuration. The first start requires access to GitHub Releases to download the runtime files.

## Configuration and data

The generator has no backend. Form data is stored in the current site's browser `localStorage`, is not written to the URL, and can be cleared from the page.

When automatic renewal is enabled, account credentials are written to `config.env`. Keep this file private and do not save the configuration on a shared device. Runtime authentication data and logs are stored in the container's `data/` and `logs/` directories.

## Development

```bash
npm test
npm run lint
npm run typecheck
npm run build
```

Build output is written to `dist/`.

## License

This project is licensed under [GNU AGPL v3.0 only](LICENSE) with [additional terms](ADDITIONAL_TERMS.md). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party components and licenses.
