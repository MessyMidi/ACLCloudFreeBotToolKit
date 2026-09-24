/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import { access } from 'node:fs/promises';
import { constants } from 'node:fs';
import { resolve } from 'node:path';

export async function resolveGo(root) {
  const local = resolve(root, '.tools', 'go', 'bin', process.platform === 'win32' ? 'go.exe' : 'go');
  try {
    await access(local, constants.X_OK);
    return local;
  } catch {
    return 'go';
  }
}
