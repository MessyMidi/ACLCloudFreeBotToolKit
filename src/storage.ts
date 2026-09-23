/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import type { MonitorSelection, ProxyConfig } from './types';

export const FORM_STORAGE_KEY = 'aclclouds:generator-state';

export interface StoredFormState {
  version: 1;
  monitorEnabled: boolean;
  monitorType: MonitorSelection;
  monitorCommand: string;
  proxyEnabled: boolean;
  proxy: ProxyConfig;
  autoUpdate: boolean;
}

function isString(value: unknown): value is string {
  return typeof value === 'string';
}

export function parseStoredState(raw: string | null): StoredFormState | undefined {
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw) as Partial<StoredFormState>;
    const proxy = value.proxy as Partial<ProxyConfig> | undefined;
    if (
      value.version !== 1 ||
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

    return value as StoredFormState;
  } catch {
    return undefined;
  }
}
