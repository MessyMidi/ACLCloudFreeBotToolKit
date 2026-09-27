/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

// `npm version` runs this after bumping package.json so the runtime scripts
// report the same version as the release tag. The Go helper receives the
// version at build time instead (see build-renew.mjs).
const root = resolve(import.meta.dirname, '..');
const { version } = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) throw new Error(`Unsupported version: ${version}`);

const targets = [
  ['bootstrap.sh', 'BOOTSTRAP_VERSION'],
  ['launcher.sh', 'LAUNCHER_VERSION']
];
for (const [file, variable] of targets) {
  const path = resolve(root, file);
  const source = await readFile(path, 'utf8');
  const pattern = new RegExp(`^${variable}='[^']*'$`, 'm');
  if (!pattern.test(source)) throw new Error(`${file} has no ${variable} assignment`);
  await writeFile(path, source.replace(pattern, `${variable}='${version}'`), 'utf8');
}
