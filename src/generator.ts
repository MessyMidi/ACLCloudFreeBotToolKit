import { CLIENT_FINGERPRINTS, TESTED_VERSIONS } from './constants';
import type { MonitorConfig, ProxyConfig, ValidationResult } from './types';

function hasControlCharacters(value: string): boolean {
  return [...value].some((character) => {
    const code = character.charCodeAt(0);
    return code <= 31 || code === 127;
  });
}

export function shellQuote(value: string): string {
  if (hasControlCharacters(value)) throw new Error('配置值不能包含换行或控制字符');
  return `'${value.replaceAll("'", "'\\''")}'`;
}

export function validateProxy(config: ProxyConfig): ValidationResult {
  const errors: ValidationResult['errors'] = {};
  if (!config.sni.trim()) errors.sni = '请填写 REALITY SNI';
  else if (!/^[A-Za-z0-9._-]+$/.test(config.sni)) errors.sni = 'SNI 只能包含域名常用字符';

  if (!config.destination.trim()) errors.destination = '请填写 REALITY Destination';
  else {
    const match = config.destination.match(/^(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):([0-9]{1,5})$/);
    const port = match ? Number(match[1]) : 0;
    if (!match || port < 1 || port > 65535) errors.destination = '请使用 host:port 格式，并填写有效端口';
  }

  if (!CLIENT_FINGERPRINTS.some((fingerprint) => fingerprint === config.fingerprint)) {
    errors.fingerprint = '请选择 Mihomo 与 VLESS 共同支持的 Fingerprint';
  }
  if (!config.remark.trim()) errors.remark = '请填写节点备注';
  else if (!/^[A-Za-z0-9._-]+$/.test(config.remark)) errors.remark = '备注只支持字母、数字、点、下划线和连字符';
  return { errors, valid: Object.keys(errors).length === 0 };
}

export function generateEnv(monitor?: MonitorConfig, proxy?: ProxyConfig): string {
  if (!monitor && !proxy) throw new Error('至少启用一个服务');

  const lines = [
    '# ACLClouds Free Bot · generated locally in your browser',
    '# Do not set SERVER_IP / SERVER_PORT; ACLClouds injects them.',
    '',
    '# ---------------- Monitor ----------------',
    `MONITOR_ENABLED=${shellQuote(monitor ? '1' : '0')}`
  ];

  if (monitor) {
    const monitorVersion = TESTED_VERSIONS[monitor.type];
    lines.push(
      `MONITOR_TYPE=${shellQuote(monitor.type)}`,
      `MONITOR_ENDPOINT=${shellQuote(monitor.endpoint)}`,
      `MONITOR_TOKEN=${shellQuote(monitor.token)}`,
      `MONITOR_REMOTE_CONTROL=${shellQuote(String(monitor.remoteControl))}`,
      `MONITOR_VERSION=${shellQuote(monitorVersion.version)}`,
      `MONITOR_URL=${shellQuote(monitorVersion.url)}`,
      `MONITOR_SHA256=${shellQuote(monitorVersion.sha256)}`
    );
  }

  lines.push(
    '',
    '# ---------------- Mihomo ----------------',
    `MIHOMO_ENABLED=${shellQuote(proxy ? '1' : '0')}`
  );

  if (proxy) {
    lines.push(
      `MIHOMO_VERSION=${shellQuote(TESTED_VERSIONS.mihomo.version)}`,
      `MIHOMO_URL=${shellQuote(TESTED_VERSIONS.mihomo.url)}`,
      `MIHOMO_FALLBACK_URL=${shellQuote(TESTED_VERSIONS.mihomo.fallbackUrl)}`,
      `MIHOMO_LOGLEVEL=${shellQuote('info')}`,
      `MIHOMO_REMARK=${shellQuote(proxy.remark)}`,
      '',
      '# ---------------- VLESS + REALITY ----------------',
      `REALITY_DEST=${shellQuote(proxy.destination)}`,
      `REALITY_SNI=${shellQuote(proxy.sni)}`,
      `CLIENT_FINGERPRINT=${shellQuote(proxy.fingerprint)}`,
      `VLESS_FLOW=${shellQuote('xtls-rprx-vision')}`
    );
  }

  lines.push('');
  return lines.join('\n');
}

export function generateStartupCommand(launcherUrl: string): string {
  const quotedUrl = shellQuote(launcherUrl);
  return `LAUNCHER_URL=${quotedUrl}; if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 -o launcher.sh "$LAUNCHER_URL"; else wget -O launcher.sh "$LAUNCHER_URL"; fi && chmod +x launcher.sh && exec bash launcher.sh`;
}
