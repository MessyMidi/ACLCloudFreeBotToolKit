/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import type { MonitorType } from './types';

export const MONITOR_LABELS: Record<MonitorType, string> = {
  lite: 'Lite',
  komari: 'Komari',
  cfsm: 'CF Server Monitor'
};

export const TESTED_VERSIONS = {
  mihomo: {
    version: 'v1.19.32',
    url: 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-linux-amd64-v1-v1.19.32.gz',
    sha256: '306f81e723e60ce6b828899a6fe83e1d00e9ecefb2dc8d4d849312a5bc00efdc',
    fallbackUrl: 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-linux-amd64-compatible-v1.19.32.gz',
    fallbackSha256: 'ba3ce607747a07f948fc35780e108a4a7c7f552a38b9bd4d115f313ebcb89c20'
  },
  komari: {
    version: '1.5.11',
    url: 'https://github.com/komari-monitor/komari-agent/releases/download/1.5.11/komari-agent-linux-amd64',
    sha256: '78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c'
  },
  lite: {
    version: '2.3.6.0',
    url: 'https://github.com/nuomiiiii/Lite-agent/releases/download/2.3.6.0/Lite-agent-linux-amd64',
    sha256: 'd973b48edba2c1be9faea959c231dc6a278fa40ad283d53a459f8ad7727ef15b'
  },
  cfsm: {
    version: 'v1.0.19',
    url: 'https://github.com/huilang-me/cfsm-agent/releases/download/v1.0.19/cf-probe-linux-amd64',
    sha256: '64cc6e2a34ac49a39fb04894a48262bc0b3221d97ba7314dde15ad108097d52c'
  }
} as const;

/**
 * Conservative common set supported by Mihomo and VLESS/Xray clients. The
 * selected value is written to the generated `fp=` share-link parameter.
 */
export const CLIENT_FINGERPRINTS = [
  'chrome',
  'firefox',
  'safari',
  'ios',
  'android',
  'edge',
  '360',
  'qq',
  'random'
] as const;

export const DEFAULT_PROXY = {
  sni: 'www.cloudflare.com',
  destination: 'www.cloudflare.com:443',
  fingerprint: 'chrome',
  remark: 'ACLClouds-Free'
} as const;
