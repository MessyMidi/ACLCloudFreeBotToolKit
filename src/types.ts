/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

export type MonitorType = 'lite' | 'komari';
export type MonitorSelection = 'auto' | MonitorType;

export interface MonitorConfig {
  type: MonitorType;
  endpoint: string;
  token: string;
  remoteControl: boolean;
}

export interface ProxyConfig {
  sni: string;
  destination: string;
  fingerprint: string;
  remark: string;
}

export interface RenewalConfig {
  username: string;
  password: string;
  serverId: string;
  telegramBotToken: string;
  telegramChatId: string;
}

export interface ParseResult {
  config?: MonitorConfig;
  errors: string[];
  warnings: string[];
}

export interface ValidationResult {
  errors: Partial<Record<keyof ProxyConfig, string>>;
  valid: boolean;
}

export interface RenewalValidationResult {
  errors: Partial<Record<keyof RenewalConfig, string>>;
  valid: boolean;
}
