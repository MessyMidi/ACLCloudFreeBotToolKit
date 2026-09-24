/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import type { MonitorSelection, ProxyConfig, RenewalConfig } from './types';

export const FORM_STORAGE_KEY = 'aclclouds:generator-state';

export interface StoredFormState {
  version: 2;
  monitorEnabled: boolean;
  monitorType: MonitorSelection;
  monitorCommand: string;
  proxyEnabled: boolean;
  proxy: ProxyConfig;
  autoUpdate: boolean;
  renewalEnabled: boolean;
  renewal: RenewalConfig;
}

function isString(value: unknown): value is string {
  return typeof value === 'string';
}

export function parseStoredState(raw: string | null): StoredFormState | undefined {
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw) as Omit<Partial<StoredFormState>, 'version'> & { version?: number };
    const proxy = value.proxy as Partial<ProxyConfig> | undefined;
    const legacy = value.version === 1;
    const renewal = value.renewal as Partial<RenewalConfig> | undefined;
    if (
      (value.version !== 1 && value.version !== 2) ||
      typeof value.monitorEnabled !== 'boolean' ||
      !['auto', 'lite', 'komari'].includes(value.monitorType ?? '') ||
      !isString(value.monitorCommand) ||
      typeof value.proxyEnabled !== 'boolean' ||
      !proxy ||
      !isString(proxy.sni) ||
      !isString(proxy.destination) ||
      !isString(proxy.fingerprint) ||
      !isString(proxy.remark) ||
      typeof value.autoUpdate !== 'boolean'
    ) return undefined;
    if (legacy) {
      return {
        ...(value as unknown as Omit<StoredFormState, 'version' | 'renewalEnabled' | 'renewal'>),
        version: 2,
        renewalEnabled: false,
        renewal: { username: '', password: '', serverId: '', telegramBotToken: '', telegramChatId: '' }
      };
    }
    if (
      typeof value.renewalEnabled !== 'boolean' || !renewal ||
      !isString(renewal.username) || !isString(renewal.password) || !isString(renewal.serverId) ||
      !isString(renewal.telegramBotToken) || !isString(renewal.telegramChatId)
    ) return undefined;
    return value as StoredFormState;
  } catch {
    return undefined;
  }
}
