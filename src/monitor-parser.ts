/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import type { MonitorConfig, MonitorSelection, MonitorType, ParseResult } from './types';

interface TokenizeResult {
  tokens: string[];
  error?: string;
}

function tokenizeShellLike(input: string): TokenizeResult {
  const tokens: string[] = [];
  let token = '';
  let state: 'plain' | 'single' | 'double' = 'plain';
  let escaped = false;

  const push = () => {
    if (token.length > 0) tokens.push(token);
    token = '';
  };

  for (let index = 0; index < input.length; index += 1) {
    const char = input[index]!;
    if (escaped) {
      if (char !== '\n' && char !== '\r') token += char;
      escaped = false;
      continue;
    }
    if (state !== 'single' && char === '\\') {
      escaped = true;
      continue;
    }
    if (state === 'plain' && /\s/.test(char)) {
      push();
      continue;
    }
    if (char === "'" && state !== 'double') {
      state = state === 'single' ? 'plain' : 'single';
      continue;
    }
    if (char === '"' && state !== 'single') {
      state = state === 'double' ? 'plain' : 'double';
      continue;
    }
    token += char;
  }

  if (escaped) token += '\\';
  if (state !== 'plain') return { tokens, error: '命令中有未闭合的引号' };
  push();
  return { tokens };
}

function optionValues(tokens: string[], shortName: string, longName: string): string[] {
  const values: string[] = [];
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index]!;
    if (token === shortName || token === longName) {
      const next = tokens[index + 1];
      if (next && !next.startsWith('-')) values.push(next);
      continue;
    }
    const prefixes = [`${shortName}=`, `${longName}=`];
    const prefix = prefixes.find((candidate) => token.startsWith(candidate));
    if (prefix) values.push(token.slice(prefix.length));
  }
  return values;
}

function detectType(command: string): MonitorType | undefined {
  const lite = /(?:githubusercontent\.com|github\.com)\/nuomiiiii\/lite-agent/i.test(command);
  const komari = /(?:githubusercontent\.com|github\.com)\/komari-monitor\/komari-agent/i.test(command);
  if (lite === komari) return undefined;
  return lite ? 'lite' : 'komari';
}

function booleanFlagValues(tokens: string[], name: string): Array<boolean | undefined> {
  return tokens
    .filter((token) => token === name || token.startsWith(`${name}=`))
    .map((token) => {
      if (token === name) return true;
      const value = token.slice(name.length + 1).toLowerCase();
      if (['1', 'true', 'yes', 'on'].includes(value)) return true;
      if (['0', 'false', 'no', 'off'].includes(value)) return false;
      return undefined;
    });
}

function parseRemoteControl(tokens: string[], type: MonitorType, errors: string[]): boolean {
  const flagName = type === 'lite' ? '--enable-remote-control' : '--disable-web-ssh';
  const values = booleanFlagValues(tokens, flagName);
  if (values.length > 1) errors.push(`命令中出现了多个 ${flagName}，请只保留一个`);
  if (values.some((value) => value === undefined)) errors.push(`${flagName} 的值必须是 true 或 false`);

  const value = values[0];
  if (type === 'lite') {
    // Lite uses a positive flag. An omitted flag is treated as disabled for a
    // deterministic new deployment; official generated commands are explicit.
    return value ?? false;
  }
  // Komari uses a negative flag: remote control is enabled unless the user
  // explicitly asks the agent to disable Web SSH / remote execution.
  return !(value ?? false);
}

function validEndpoint(value: string): boolean {
  try {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) && Boolean(url.hostname) && !url.username && !url.password;
  } catch {
    return false;
  }
}

function hasControlCharacters(value: string): boolean {
  return [...value].some((character) => {
    const code = character.charCodeAt(0);
    return code <= 31 || code === 127;
  });
}

export function parseMonitorCommand(command: string, selection: MonitorSelection = 'auto'): ParseResult {
  const errors: string[] = [];
  const warnings: string[] = [];
  const trimmed = command.trim();
  if (!trimmed) return { errors: ['请粘贴 Monitor 一键安装命令'], warnings };

  const tokenized = tokenizeShellLike(trimmed);
  if (tokenized.error) errors.push(tokenized.error);

  const detected = detectType(trimmed);
  const type: MonitorType | undefined = selection === 'auto' ? detected : selection;
  if (selection === 'auto' && !detected) errors.push('无法从安装脚本地址识别 Lite 或 Komari');
  if (selection !== 'auto' && detected && detected !== selection) {
    warnings.push(`脚本看起来属于 ${detected === 'lite' ? 'Lite' : 'Komari'}，已按手动选择处理`);
  }

  const endpoints = optionValues(tokenized.tokens, '-e', '--endpoint');
  const tokens = optionValues(tokenized.tokens, '-t', '--token');
  if (endpoints.length === 0) errors.push('命令中缺少 -e / --endpoint');
  if (endpoints.length > 1) errors.push('命令中出现了多个 endpoint，请只保留一个');
  if (tokens.length === 0) errors.push('命令中缺少 -t / --token');
  if (tokens.length > 1) errors.push('命令中出现了多个 token，请只保留一个');

  const endpoint = endpoints[0] ?? '';
  const token = tokens[0] ?? '';
  if (endpoint && !validEndpoint(endpoint)) errors.push('Endpoint 必须是有效的 http:// 或 https:// 地址');
  if (hasControlCharacters(endpoint) || hasControlCharacters(token)) errors.push('Endpoint 和 Token 不能包含换行或控制字符');
  if (token.length > 4096) errors.push('Token 长度异常，请确认粘贴内容');

  const remoteControl = type ? parseRemoteControl(tokenized.tokens, type, errors) : false;
  if (errors.length > 0 || !type) return { errors: [...new Set(errors)], warnings };

  const config: MonitorConfig = {
    type,
    endpoint,
    token,
    remoteControl
  };
  return { config, errors, warnings };
}

export function maskToken(token: string): string {
  if (!token) return '';
  if (token.length <= 6) return '•'.repeat(Math.max(token.length, 6));
  return `${token.slice(0, 2)}${'•'.repeat(Math.min(12, token.length - 4))}${token.slice(-2)}`;
}
