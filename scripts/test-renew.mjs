/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { resolveGo } from './go-tool.mjs';

const root = resolve(import.meta.dirname, '..');
const go = await resolveGo(root);
const goEnvironment = {
  ...process.env,
  GOCACHE: process.env.GOCACHE || resolve(root, '.tools', 'gocache'),
  GOPATH: process.env.GOPATH || resolve(root, '.tools', 'gopath')
};
const result = spawnSync(go, ['test', './cmd/...', './internal/...'], { cwd: root, env: goEnvironment, stdio: 'inherit' });
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
