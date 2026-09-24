/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import type { MonitorType } from './types';

/**
 * Install source for CF Server Monitor. Unlike Lite/Komari it is not a pinned
 * binary run by launcher.sh; it is installed by this one-click script from the
 * generated Startup Command, so no version/sha256 is tracked here.
 */
export const CFSM_INSTALL_SCRIPT = 'https://raw.githubusercontent.com/huilang-me/cfsm-agent/main/install.sh';

export const MONITOR_LABELS: Record<MonitorType, string> = {
  lite: 'Lite',
  komari: 'Komari',
  cfsm: 'CF Server Monitor'
};

export const TESTED_VERSIONS = {
  mihomo: {
    version: 'v1.19.31',
    url: 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.31/mihomo-linux-amd64-v1-v1.19.31.gz',
    fallbackUrl: 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.31/mihomo-linux-amd64-compatible-v1.19.31.gz'
  },
  komari: {
    version: '1.5.11',
    url: 'https://github.com/komari-monitor/komari-agent/releases/download/1.5.11/komari-agent-linux-amd64',
    sha256: '78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c'
  },
  lite: {
    version: '2.3.3.5',
    url: 'https://github.com/nuomiiiii/Lite-agent/releases/download/2.3.3.5/Lite-agent-linux-amd64',
    sha256: 'c39042e712bd204a5ea359b6d0f0f5b2c3e6bf6fa9bdcd8954e8fad30f32a6ed'
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
