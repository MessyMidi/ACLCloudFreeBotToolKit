/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import { CLIENT_FINGERPRINTS, TESTED_VERSIONS } from './constants';
import type { MonitorConfig, ProxyConfig, RenewalConfig, RenewalValidationResult, ValidationResult } from './types';

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

export function validateRenewal(config: RenewalConfig): RenewalValidationResult {
  const errors: RenewalValidationResult['errors'] = {};
  if (!config.username.trim()) errors.username = '请填写 ACLClouds 登录邮箱或用户名';
  else if (hasControlCharacters(config.username)) errors.username = '账号不能包含换行或控制字符';
  if (!config.password) errors.password = '请填写 ACLClouds 登录密码';
  else if (hasControlCharacters(config.password)) errors.password = '密码不能包含换行或控制字符';
  if (config.serverId && !/^[A-Za-z0-9-]+$/.test(config.serverId)) errors.serverId = 'Service ID 只支持字母、数字和连字符';
  const telegramBotToken = config.telegramBotToken.trim();
  const telegramChatId = config.telegramChatId.trim();
  if (telegramBotToken && !/^\d+:[A-Za-z0-9_-]+$/.test(telegramBotToken)) errors.telegramBotToken = 'Telegram Bot Token 格式异常';
  if (telegramChatId && !/^-?\d+$/.test(telegramChatId)) errors.telegramChatId = 'Telegram Chat ID 应为数字';
  if (telegramBotToken && !telegramChatId) errors.telegramChatId = '填写 Bot Token 后还需要 Chat ID';
  if (!telegramBotToken && telegramChatId) errors.telegramBotToken = '填写 Chat ID 后还需要 Bot Token';
  return { errors, valid: Object.keys(errors).length === 0 };
}

export function generateEnv(monitor?: MonitorConfig, proxy?: ProxyConfig, renewal?: RenewalConfig): string {
  if (!monitor && !proxy && !renewal) throw new Error('至少启用 Monitor、Mihomo 或自动延期中的一个');

  const lines = [
    '# ACLClouds Free Bot · generated locally in your browser',
    '# Do not set SERVER_IP / SERVER_PORT; ACLClouds injects them.',
    '',
    `CONFIG_SCHEMA_VERSION=${shellQuote('2')}`,
    '',
    '# ---------------- ACLClouds automatic renewal ----------------',
    `AUTO_RENEW_ENABLED=${shellQuote(renewal ? '1' : '0')}`
  ];

  if (renewal) {
    lines.push(
      `ACL_USERNAME=${shellQuote(renewal.username)}`,
      `ACL_PASSWORD=${shellQuote(renewal.password)}`,
      `ACL_SERVER_ID=${shellQuote(renewal.serverId)}`,
      `TELEGRAM_BOT_TOKEN=${shellQuote(renewal.telegramBotToken)}`,
      `TELEGRAM_CHAT_ID=${shellQuote(renewal.telegramChatId)}`
    );
  }

  lines.push(
    '',
    '# ---------------- Monitor ----------------',
    `MONITOR_ENABLED=${shellQuote(monitor ? '1' : '0')}`
  );

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
    if (monitor.type === 'cfsm') {
      lines.push(
        `MONITOR_AGENT_ID=${shellQuote(monitor.agentId)}`,
        `CFSM_COLLECT_INTERVAL=${shellQuote(String(monitor.options.collectInterval))}`,
        `CFSM_REPORT_INTERVAL=${shellQuote(String(monitor.options.reportInterval))}`,
        `CFSM_CONNECTION_MODE=${shellQuote(monitor.options.connectionMode)}`,
        `CFSM_PING_MODE=${shellQuote(monitor.options.pingMode)}`,
        `CFSM_RESET_DAY=${shellQuote(String(monitor.options.resetDay))}`,
        `CFSM_DEBUG=${shellQuote(monitor.options.debug ? '1' : '0')}`,
        `CFSM_CT_NODE=${shellQuote(monitor.options.ctNode)}`,
        `CFSM_CU_NODE=${shellQuote(monitor.options.cuNode)}`,
        `CFSM_CM_NODE=${shellQuote(monitor.options.cmNode)}`,
        `CFSM_BD_NODE=${shellQuote(monitor.options.bdNode)}`,
        `CFSM_NODE_1=${shellQuote(monitor.options.node1)}`,
        `CFSM_NODE_2=${shellQuote(monitor.options.node2)}`,
        `CFSM_NODE_3=${shellQuote(monitor.options.node3)}`,
        `CFSM_NODE_4=${shellQuote(monitor.options.node4)}`,
        `CFSM_INTERFACE=${shellQuote(monitor.options.networkInterface)}`
      );
    }
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
      `MIHOMO_SHA256=${shellQuote(TESTED_VERSIONS.mihomo.sha256)}`,
      `MIHOMO_FALLBACK_URL=${shellQuote(TESTED_VERSIONS.mihomo.fallbackUrl)}`,
      `MIHOMO_FALLBACK_SHA256=${shellQuote(TESTED_VERSIONS.mihomo.fallbackSha256)}`,
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

export function generateStartupCommand(bootstrapUrl: string, autoUpdate: boolean): string {
  const quotedUrl = shellQuote(bootstrapUrl);
  const mode = autoUpdate ? 'enable' : 'disable';
  return `BOOTSTRAP_URL=${quotedUrl}; if [ ! -s bootstrap.sh ] || ! bash -n bootstrap.sh >/dev/null 2>&1; then if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 --connect-timeout 10 -o bootstrap.sh.tmp "$BOOTSTRAP_URL"; else wget -O bootstrap.sh.tmp "$BOOTSTRAP_URL"; fi || exit 1; bash -n bootstrap.sh.tmp || exit 1; mv -f bootstrap.sh.tmp bootstrap.sh; fi; chmod +x bootstrap.sh && exec bash bootstrap.sh --AUTO_UPDATE=${mode}`;
}
