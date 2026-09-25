/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import { MONITOR_LABELS, TESTED_VERSIONS } from './constants';
import type { CfsmOptions, MonitorConfig, MonitorSelection, MonitorType, ParseResult, StandardMonitorConfig } from './types';

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

function namedOptionValues(tokens: string[], names: string[]): string[] {
  const values: string[] = [];
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index]!;
    if (names.includes(token)) {
      const next = tokens[index + 1];
      if (next && !next.startsWith('-')) values.push(next);
      continue;
    }
    const name = names.find((candidate) => token.startsWith(`${candidate}=`));
    if (name) values.push(token.slice(name.length + 1));
  }
  return values;
}

function detectType(command: string): MonitorType | undefined {
  const matches: MonitorType[] = [];
  if (/(?:githubusercontent\.com|github\.com)\/nuomiiiii\/lite-agent/i.test(command)) matches.push('lite');
  if (/(?:githubusercontent\.com|github\.com)\/komari-monitor\/komari-agent/i.test(command)) matches.push('komari');
  if (/(?:githubusercontent\.com|github\.com)\/huilang-me\/cfsm-agent/i.test(command)) matches.push('cfsm');
  return matches.length === 1 ? matches[0] : undefined;
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

function parseRemoteControl(tokens: string[], type: StandardMonitorConfig['type'], errors: string[]): boolean {
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

function oneCfsmValue(
  tokens: string[],
  names: string[],
  label: string,
  errors: string[],
  fallback?: string
): string {
  const values = namedOptionValues(tokens, names);
  if (values.length === 0 && fallback === undefined) errors.push(`命令中缺少 ${names.join(' / ')}（${label}）`);
  if (values.length > 1) errors.push(`命令中出现了多个 ${label}，请只保留一个`);
  const value = values[0] ?? fallback ?? '';
  if (hasControlCharacters(value)) errors.push(`${label}不能包含换行或控制字符`);
  return value;
}

function cfsmInteger(
  tokens: string[],
  names: string[],
  label: string,
  fallback: number,
  minimum: number,
  maximum: number | undefined,
  errors: string[]
): number {
  const raw = oneCfsmValue(tokens, names, label, errors, String(fallback));
  if (!/^\d+$/.test(raw)) {
    errors.push(`${label}必须是整数`);
    return fallback;
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || (maximum !== undefined && value > maximum)) {
    errors.push(maximum === undefined ? `${label}必须不小于 ${minimum}` : `${label}必须在 ${minimum}-${maximum} 范围内`);
    return fallback;
  }
  return value;
}

function cfsmChoice<T extends string>(
  tokens: string[],
  names: string[],
  label: string,
  fallback: T,
  allowed: readonly T[],
  errors: string[]
): T {
  const raw = oneCfsmValue(tokens, names, label, errors, fallback).toLowerCase();
  if (!allowed.includes(raw as T)) {
    errors.push(`${label}只支持 ${allowed.join(' / ')}`);
    return fallback;
  }
  return raw as T;
}

function parseCfsm(tokens: string[], errors: string[], warnings: string[]): ParseResult {
  const agentId = oneCfsmValue(tokens, ['-id'], 'Server ID', errors);
  const token = oneCfsmValue(tokens, ['-secret'], 'Secret', errors);
  const endpoint = oneCfsmValue(tokens, ['-url'], 'URL', errors);
  if (endpoint && !validEndpoint(endpoint)) errors.push('URL 必须是有效的 http:// 或 https:// 地址');
  if (token.length > 4096) errors.push('Secret 长度异常，请确认粘贴内容');

  const options: CfsmOptions = {
    collectInterval: cfsmInteger(tokens, ['-collect_interval', '-collect'], '采样间隔', 0, 0, undefined, errors),
    reportInterval: cfsmInteger(tokens, ['-interval'], '上报间隔', 60, 1, undefined, errors),
    connectionMode: cfsmChoice(tokens, ['-connection_mode', '-connection-mode'], '连接模式', 'auto', ['auto', 'http'], errors),
    pingMode: cfsmChoice(tokens, ['-ping_mode', '-ping-mode'], 'Ping 模式', 'tcp', ['tcp', 'icmp'], errors),
    resetDay: cfsmInteger(tokens, ['-reset_day'], '流量重置日', 1, 0, 31, errors),
    debug: cfsmChoice(tokens, ['-debug'], '调试开关', '0', ['0', '1'], errors) === '1',
    ctNode: oneCfsmValue(tokens, ['-ct'], '电信节点', errors, ''),
    cuNode: oneCfsmValue(tokens, ['-cu'], '联通节点', errors, ''),
    cmNode: oneCfsmValue(tokens, ['-cm'], '移动节点', errors, ''),
    bdNode: oneCfsmValue(tokens, ['-bd', '-bgp'], 'BGP 节点', errors, ''),
    node1: oneCfsmValue(tokens, ['-node_1'], '自定义节点 1', errors, ''),
    node2: oneCfsmValue(tokens, ['-node_2'], '自定义节点 2', errors, ''),
    node3: oneCfsmValue(tokens, ['-node_3'], '自定义节点 3', errors, ''),
    node4: oneCfsmValue(tokens, ['-node_4'], '自定义节点 4', errors, ''),
    networkInterface: oneCfsmValue(tokens, ['-interface', '-interfaces', '-iface'], '网卡', errors, '')
  };

  if (options.reportInterval < options.collectInterval && options.collectInterval > 0) {
    warnings.push('CFSM 会把上报间隔自动提高到不小于采样间隔');
  }

  const autoUpdate = oneCfsmValue(tokens, ['-auto_update', '-auto-update'], 'Agent 自动更新', errors, '0');
  if (!['0', '1'].includes(autoUpdate)) errors.push('Agent 自动更新只支持 0 / 1');
  if (autoUpdate === '1') warnings.push('CFSM Agent 自更新将关闭，由本工具固定版本并校验 SHA256');

  const requestedVersions = namedOptionValues(tokens, ['--install-version']);
  if (requestedVersions.length > 1) errors.push('命令中出现了多个 --install-version，请只保留一个');
  if (requestedVersions[0] && requestedVersions[0] !== TESTED_VERSIONS.cfsm.version) {
    warnings.push(`命令指定的 ${requestedVersions[0]} 将替换为已测试版本 ${TESTED_VERSIONS.cfsm.version}`);
  }
  if (namedOptionValues(tokens, ['--install-ghproxy']).length > 0) {
    warnings.push('安装脚本代理参数不会写入运行配置；本工具直接下载并校验固定版本');
  }
  if (namedOptionValues(tokens, ['-rx_correction', '-tx_correction']).length > 0) {
    errors.push('ACLClouds 托管模式暂不支持一次性流量校正参数，请移除 -rx_correction / -tx_correction');
  }

  if (errors.length > 0) return { errors: [...new Set(errors)], warnings: [...new Set(warnings)] };
  const config: MonitorConfig = { type: 'cfsm', endpoint, token, remoteControl: false, agentId, options };
  return { config, errors, warnings: [...new Set(warnings)] };
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
  if (selection === 'auto' && !detected) errors.push('无法从安装脚本地址识别 Lite / Komari / CF Server Monitor');
  if (selection !== 'auto' && detected && detected !== selection) {
    warnings.push(`脚本看起来属于 ${MONITOR_LABELS[detected]}，已按手动选择处理`);
  }

  if (type === 'cfsm') return parseCfsm(tokenized.tokens, errors, warnings);

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
