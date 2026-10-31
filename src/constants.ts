/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import type { MonitorType } from './types';

export const BOOTSTRAP_URL = 'https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases/latest/download/bootstrap.sh';

export const MONITOR_LABELS: Record<MonitorType, string> = {
  lite: 'Lite',
  komari: 'Komari',
  cfsm: 'CF Server Monitor'
};

export const TESTED_VERSIONS = {
  mihomo: {
    version: 'v1.19.33',
    url: 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo-linux-amd64-v1-v1.19.33.gz',
    sha256: '8ec92e7b2fdc6b853ba00156bab7e4e965c8b0d843b8c4ac8ab98795f02ad524',
    fallbackUrl: 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo-linux-amd64-compatible-v1.19.33.gz',
    fallbackSha256: '386508bfb1c72c43b6a0eda73708ecdce82546581b0ebcb16366c53757c622b6'
  },
  komari: {
    version: '1.5.11',
    url: 'https://github.com/komari-monitor/komari-agent/releases/download/1.5.11/komari-agent-linux-amd64',
    sha256: '78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c'
  },
  lite: {
    version: '2.3.10.1',
    url: 'https://github.com/nuomiiiii/Lite-agent/releases/download/2.3.10.1/Lite-agent-linux-amd64',
    sha256: 'b25ce9827b2997bfc96f5e3e957dda52e2f1ea0564b2bd2aca14c6dd38e62562'
  },
  cfsm: {
    version: 'v1.1.1',
    url: 'https://github.com/huilang-me/cfsm-agent/releases/download/v1.1.1/cf-probe-linux-amd64',
    sha256: '3d1592f3f31cb8d66764cad663c0a8ad9ed0a2a5e8f7052a3b3987b160232714'
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
