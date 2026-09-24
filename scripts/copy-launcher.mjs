/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const dist = resolve(root, 'dist');
const scripts = ['bootstrap.sh', 'launcher.sh'];
const binary = 'acl-renew-linux-amd64';
const assets = [...scripts, binary];

await mkdir(dist, { recursive: true });
await Promise.all([
  ...scripts.map((asset) => copyFile(resolve(root, asset), resolve(dist, asset))),
  copyFile(resolve(root, 'build', binary), resolve(dist, binary))
]);

const checksums = await Promise.all(assets.map(async (asset) => {
  const contents = await readFile(resolve(dist, asset));
  return `${createHash('sha256').update(contents).digest('hex')}  ${asset}`;
}));
await writeFile(resolve(dist, 'SHA256SUMS'), `${checksums.join('\n')}\n`, 'utf8');
