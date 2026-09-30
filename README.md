[English](README.md) | [简体中文](README.zh-CN.md)

<img width="2172" height="724" alt="ACLCloudFreeBotToolKit" src="https://github.com/user-attachments/assets/f6caea1c-3be7-432b-9c20-b0cd9151036b" />

# ACLCloudFreeBotToolKit

A configuration generator and runtime toolkit for ACLClouds Free Bot. It generates a `config.env` file and Startup Command in the browser, then runs Mihomo, Lite, Komari, CF Server Monitor, and optional renewal checks in a non-root container.

[Releases](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases) · [Issues](https://github.com/MessyMidi/ACLCloudFreeBotToolKit/issues)

## Features

- Runs Mihomo with VLESS REALITY and persists connection details after the first start. Proxy users cannot reach private or loopback networks through the node.
- Connects a Lite, Komari, or CF Server Monitor agent.
- Optionally renews the current ACLClouds service, with CAPTCHA handling and Telegram notifications. A failed check is retried after 30 minutes, with a growing delay.
- Downloads, verifies, and updates runtime files while keeping the local version available if an update fails. An update that fails to start, or crashes, is rolled back and not installed again for 7 days unless a newer release appears.
- Restarts crashed Mihomo and Monitor processes with exponential backoff, then reports and stops after five consecutive retries.
- Lets Mihomo, monitoring, and renewal run independently, and keeps service logs below a size limit.
- The generator and the Console menu are available in Chinese and English.

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

The generator has no backend. Form data is stored in the current site's browser `localStorage` and is never written to the URL; it can be cleared from the page. The renewal username and password and the Telegram Bot Token and Chat ID are credentials: they are saved only when “Remember the password and tokens in this browser” is ticked inside the renewal module. The Monitor install command, which also carries the agent token, is saved with the rest of the form data.

When automatic renewal is enabled, account credentials are written to `config.env`. Keep this file private and do not save the configuration on a shared device. The launcher does not pass these credentials on to Mihomo or the monitor agent. Runtime authentication data and logs are stored in the container's `data/` and `logs/` directories.

Optional `config.env` settings:

| Setting | Default | Purpose |
| --- | --- | --- |
| `CONSOLE_LANG` | `zh` | Console menu language, `zh` or `en`. The generator writes the page language. |
| `MIHOMO_BLOCK_PRIVATE_NETWORKS` | `1` | Set to `0` to let proxy users reach private, loopback, and link-local addresses. |
| `LOG_MAX_BYTES` | `5242880` | Size at which `logs/mihomo.log` and `logs/monitor.log` are trimmed to their newest part. |
| `WATCHDOG_MAX_RESTARTS` | `5` | Crash restarts before the watchdog gives up (1–10). |

## Update security

Automatic updates check that the downloaded files match the `SHA256SUMS` file of the same GitHub Release. This detects damaged or incomplete downloads, but it does not prove who published the release: anyone who gains control of this repository's releases could publish files that pass the check, and containers with automatic updates enabled would install them within about six hours. Those containers hold the ACLClouds credentials when automatic renewal is enabled.

Releases created by the Release workflow are built by GitHub Actions from a tagged commit, and their build provenance can be checked with:

```bash
gh attestation verify acl-renew-linux-amd64 --repo MessyMidi/ACLCloudFreeBotToolKit
```

If you prefer to review each release before running it, turn off automatic updates in the generator; the Startup Command then passes `--AUTO_UPDATE=disable`.

## Development

```bash
npm test
npm run lint
npm run typecheck
npm run build
```

Build output is written to `dist/`. The shell lifecycle tests run with `bash tests/bootstrap.test.sh` and `bash tests/launcher-modes.test.sh`.

The renewal helper uses the current Cap.js v2 `hashwx` proof-of-work flow. The official `@cap.js/wasm` v0.0.8 kernel is embedded in the Go binary and executed with wazero; it is never downloaded at runtime. See `THIRD_PARTY_NOTICES.md` for versions, provenance, and licensing.

To publish a release, run `npm version <version>` (it also updates the version in the runtime scripts) and push the commit with its tag. The Release workflow tests and builds the tag and creates a draft Release; review it and publish it by hand.

## License

This project is licensed under [GNU AGPL v3.0 only](LICENSE) with [additional terms](ADDITIONAL_TERMS.md). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party components and licenses.
