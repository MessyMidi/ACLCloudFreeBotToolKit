/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

/// <reference types="vite/client" />
import { describe, expect, it } from 'vitest';
import bootstrapScript from '../bootstrap.sh?raw';
import exampleConfig from '../config.env.example?raw';
import launcherScript from '../launcher.sh?raw';
import packageJson from '../package.json?raw';
import { TESTED_VERSIONS } from '../src/constants';

// The pinned runtime versions live in the Web generator, the launcher
// defaults, and the example config; these tests keep the copies in sync.

function monitorBranch(type: string): string {
  const defaults = launcherScript.split('# ---------------- Defaults ----------------')[1];
  const match = defaults?.match(new RegExp(`^\\s+${type}\\)\\n([\\s\\S]*?)^\\s+;;`, 'm'));
  if (!match?.[1]) throw new Error(`launcher.sh has no ${type} branch`);
  return match[1];
}

describe('release version', () => {
  it('is the same in package.json and both runtime scripts', () => {
    const { version } = JSON.parse(packageJson) as { version: string };
    expect(bootstrapScript).toContain(`\nBOOTSTRAP_VERSION='${version}'\n`);
    expect(launcherScript).toContain(`\nLAUNCHER_VERSION='${version}'\n`);
  });
});

describe('pinned runtime versions', () => {
  it('match the launcher defaults for Mihomo', () => {
    const { version, url, sha256, fallbackUrl, fallbackSha256 } = TESTED_VERSIONS.mihomo;
    const template = (value: string) => value.replaceAll(version, '${MIHOMO_VERSION}');
    expect(launcherScript).toContain(`MIHOMO_VERSION="\${MIHOMO_VERSION:-${version}}"`);
    expect(launcherScript).toContain(`MIHOMO_URL="\${MIHOMO_URL:-${template(url)}}"`);
    expect(launcherScript).toContain(`MIHOMO_SHA256="\${MIHOMO_SHA256:-${sha256}}"`);
    expect(launcherScript).toContain(`MIHOMO_FALLBACK_URL="\${MIHOMO_FALLBACK_URL:-${template(fallbackUrl)}}"`);
    expect(launcherScript).toContain(`MIHOMO_FALLBACK_SHA256="\${MIHOMO_FALLBACK_SHA256:-${fallbackSha256}}"`);
  });

  it.each(['lite', 'komari', 'cfsm'] as const)('match the launcher defaults for %s', (type) => {
    const { version, url, sha256 } = TESTED_VERSIONS[type];
    const branch = monitorBranch(type);
    expect(branch).toContain(`:-${version}}`);
    expect(branch).toContain(url.replaceAll(version, '${MONITOR_VERSION}'));
    expect(branch).toContain(`:-${sha256}}`);
  });

  it('match the example configuration', () => {
    const { mihomo, komari } = TESTED_VERSIONS;
    expect(exampleConfig).toContain(`MIHOMO_VERSION='${mihomo.version}'`);
    expect(exampleConfig).toContain(`MIHOMO_URL='${mihomo.url}'`);
    expect(exampleConfig).toContain(`MIHOMO_SHA256='${mihomo.sha256}'`);
    expect(exampleConfig).toContain(`MIHOMO_FALLBACK_URL='${mihomo.fallbackUrl}'`);
    expect(exampleConfig).toContain(`MIHOMO_FALLBACK_SHA256='${mihomo.fallbackSha256}'`);
    expect(exampleConfig).toContain(`MONITOR_VERSION='${komari.version}'`);
    expect(exampleConfig).toContain(`MONITOR_URL='${komari.url}'`);
    expect(exampleConfig).toContain(`MONITOR_SHA256='${komari.sha256}'`);
  });
});
