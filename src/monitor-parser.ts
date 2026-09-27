/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import { MONITOR_LABELS, TESTED_VERSIONS } from './constants';
import { t } from './i18n';
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
  if (state !== 'plain') return { tokens, error: t('parse.unclosedQuote') };
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
  if (values.length > 1) errors.push(t('parse.duplicate', { name: flagName }));
  if (values.some((value) => value === undefined)) errors.push(t('parse.flagBoolean', { flag: flagName }));

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
  if (values.length === 0 && fallback === undefined) errors.push(t('parse.missing', { names: names.join(' / '), label }));
  if (values.length > 1) errors.push(t('parse.duplicate', { name: label }));
  const value = values[0] ?? fallback ?? '';
  if (hasControlCharacters(value)) errors.push(t('parse.controlCharacters', { label }));
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
    errors.push(t('parse.integer', { label }));
    return fallback;
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || (maximum !== undefined && value > maximum)) {
    errors.push(maximum === undefined ? t('parse.minimum', { label, minimum }) : t('parse.range', { label, minimum, maximum }));
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
    errors.push(t('parse.choice', { label, allowed: allowed.join(' / ') }));
    return fallback;
  }
  return raw as T;
}

function parseCfsm(tokens: string[], errors: string[], warnings: string[]): ParseResult {
  const agentId = oneCfsmValue(tokens, ['-id'], 'Server ID', errors);
  const token = oneCfsmValue(tokens, ['-secret'], 'Secret', errors);
  const endpoint = oneCfsmValue(tokens, ['-url'], 'URL', errors);
  if (endpoint && !validEndpoint(endpoint)) errors.push(t('parse.invalidUrl', { label: 'URL' }));
  if (token.length > 4096) errors.push(t('parse.tooLong', { label: 'Secret' }));

  const options: CfsmOptions = {
    collectInterval: cfsmInteger(tokens, ['-collect_interval', '-collect'], t('cfsm.collectInterval'), 0, 0, undefined, errors),
    reportInterval: cfsmInteger(tokens, ['-interval'], t('cfsm.reportInterval'), 60, 1, undefined, errors),
    connectionMode: cfsmChoice(tokens, ['-connection_mode', '-connection-mode'], t('cfsm.connectionMode'), 'auto', ['auto', 'http'], errors),
    pingMode: cfsmChoice(tokens, ['-ping_mode', '-ping-mode'], t('cfsm.pingMode'), 'tcp', ['tcp', 'icmp'], errors),
    resetDay: cfsmInteger(tokens, ['-reset_day'], t('cfsm.resetDay'), 1, 0, 31, errors),
    debug: cfsmChoice(tokens, ['-debug'], t('cfsm.debug'), '0', ['0', '1'], errors) === '1',
    ctNode: oneCfsmValue(tokens, ['-ct'], t('cfsm.ctNode'), errors, ''),
    cuNode: oneCfsmValue(tokens, ['-cu'], t('cfsm.cuNode'), errors, ''),
    cmNode: oneCfsmValue(tokens, ['-cm'], t('cfsm.cmNode'), errors, ''),
    bdNode: oneCfsmValue(tokens, ['-bd', '-bgp'], t('cfsm.bgpNode'), errors, ''),
    node1: oneCfsmValue(tokens, ['-node_1'], t('cfsm.customNode', { number: 1 }), errors, ''),
    node2: oneCfsmValue(tokens, ['-node_2'], t('cfsm.customNode', { number: 2 }), errors, ''),
    node3: oneCfsmValue(tokens, ['-node_3'], t('cfsm.customNode', { number: 3 }), errors, ''),
    node4: oneCfsmValue(tokens, ['-node_4'], t('cfsm.customNode', { number: 4 }), errors, ''),
    networkInterface: oneCfsmValue(tokens, ['-interface', '-interfaces', '-iface'], t('cfsm.interface'), errors, '')
  };

  if (options.reportInterval < options.collectInterval && options.collectInterval > 0) {
    warnings.push(t('parse.intervalRaised'));
  }

  const autoUpdateLabel = t('cfsm.autoUpdate');
  const autoUpdate = oneCfsmValue(tokens, ['-auto_update', '-auto-update'], autoUpdateLabel, errors, '0');
  if (!['0', '1'].includes(autoUpdate)) errors.push(t('parse.choice', { label: autoUpdateLabel, allowed: '0 / 1' }));
  if (autoUpdate === '1') warnings.push(t('parse.selfUpdateDisabled'));

  const requestedVersions = namedOptionValues(tokens, ['--install-version']);
  if (requestedVersions.length > 1) errors.push(t('parse.duplicate', { name: '--install-version' }));
  if (requestedVersions[0] && requestedVersions[0] !== TESTED_VERSIONS.cfsm.version) {
    warnings.push(t('parse.versionReplaced', { requested: requestedVersions[0], tested: TESTED_VERSIONS.cfsm.version }));
  }
  if (namedOptionValues(tokens, ['--install-ghproxy']).length > 0) {
    warnings.push(t('parse.proxyIgnored'));
  }
  if (namedOptionValues(tokens, ['-rx_correction', '-tx_correction']).length > 0) {
    errors.push(t('parse.correctionUnsupported'));
  }

  if (errors.length > 0) return { errors: [...new Set(errors)], warnings: [...new Set(warnings)] };
  const config: MonitorConfig = { type: 'cfsm', endpoint, token, remoteControl: false, agentId, options };
  return { config, errors, warnings: [...new Set(warnings)] };
}

export function parseMonitorCommand(command: string, selection: MonitorSelection = 'auto'): ParseResult {
  const errors: string[] = [];
  const warnings: string[] = [];
  const trimmed = command.trim();
  if (!trimmed) return { errors: [t('parse.empty')], warnings };

  const tokenized = tokenizeShellLike(trimmed);
  if (tokenized.error) errors.push(tokenized.error);

  const detected = detectType(trimmed);
  const type: MonitorType | undefined = selection === 'auto' ? detected : selection;
  if (selection === 'auto' && !detected) errors.push(t('parse.unknownProject'));
  if (selection !== 'auto' && detected && detected !== selection) {
    warnings.push(t('parse.manualSelection', { name: MONITOR_LABELS[detected] }));
  }

  if (type === 'cfsm') return parseCfsm(tokenized.tokens, errors, warnings);

  const endpoints = optionValues(tokenized.tokens, '-e', '--endpoint');
  const tokens = optionValues(tokenized.tokens, '-t', '--token');
  if (endpoints.length === 0) errors.push(t('parse.missingOption', { names: '-e / --endpoint' }));
  if (endpoints.length > 1) errors.push(t('parse.duplicate', { name: 'endpoint' }));
  if (tokens.length === 0) errors.push(t('parse.missingOption', { names: '-t / --token' }));
  if (tokens.length > 1) errors.push(t('parse.duplicate', { name: 'token' }));

  const endpoint = endpoints[0] ?? '';
  const token = tokens[0] ?? '';
  if (endpoint && !validEndpoint(endpoint)) errors.push(t('parse.invalidUrl', { label: 'Endpoint' }));
  if (hasControlCharacters(endpoint) || hasControlCharacters(token)) errors.push(t('parse.credentialControl'));
  if (token.length > 4096) errors.push(t('parse.tooLong', { label: 'Token' }));

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
