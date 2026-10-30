/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { BOOTSTRAP_URL } from '../src/constants';
import { generateStartupCommand } from '../src/generator';

const roots: string[] = [];
const bash = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : 'bash';
const bashPath = (path: string): string => process.platform === 'win32'
  ? path.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive: string) => `/${drive.toLowerCase()}`)
  : path;

afterEach(() => {
  for (const root of roots.splice(0)) {
    if (dirname(resolve(root)) !== resolve(tmpdir()) || !basename(root).startsWith('acl startup-')) {
      throw new Error('Refusing to remove an unexpected fixture path');
    }
    rmSync(root, { recursive: true, force: true });
  }
});

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'acl startup-'));
  roots.push(root);
  const bin = join(root, 'bin');
  mkdirSync(bin);
  const bootstrap = '#!/usr/bin/env bash\nprintf "%s\\n" "$*" > "$FIXTURE_RUN"\nIFS= read -r choice || true\nprintf "%s\\n" "$choice" >> "$FIXTURE_RUN"\n';
  writeFileSync(join(root, 'payload'), bootstrap);
  const downloader = `#!/usr/bin/env bash
tool="\${0##*/}"
printf '%s\\n' "$tool" >> "$FIXTURE_CALLS"
while (( $# )); do
    case "$1" in
        -fLo|-O) output="$2"; shift 2 ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\\n' "$url" >> "$FIXTURE_URLS"
if [[ "$FIXTURE_MODE" == fail || ( "$tool" == curl && "$FIXTURE_MODE" == fallback ) ]]; then
    printf 'partial download' > "$output"
    exit 22
fi
cp "$FIXTURE_PAYLOAD" "$output"
`;
  for (const name of ['curl', 'wget']) writeFileSync(join(bin, name), downloader, { mode: 0o700 });
  const run = (mode = 'success', autoUpdate = true, url = BOOTSTRAP_URL) => spawnSync(bash, [
    '--noprofile', '--norc', '-c', `PATH="$FIXTURE_BIN:/usr/bin:/bin";${generateStartupCommand(url, autoUpdate)}`
  ], {
    cwd: root,
    input: '2\n',
    encoding: 'utf8',
    timeout: 10000,
    env: {
      ...process.env, BASH_ENV: '', ENV: '',
      FIXTURE_BIN: bashPath(bin), FIXTURE_MODE: mode,
      FIXTURE_PAYLOAD: bashPath(join(root, 'payload')),
      FIXTURE_RUN: bashPath(join(root, 'run')),
      FIXTURE_CALLS: bashPath(join(root, 'calls')),
      FIXTURE_URLS: bashPath(join(root, 'urls'))
    }
  });
  return { root, bootstrap, run, read: (name: string) => readFileSync(join(root, name), 'utf8') };
}

describe('generated Startup Command execution', () => {
  it.each([true, false])('installs atomically and preserves Console stdin (autoUpdate=%s)', (autoUpdate) => {
    const f = fixture();
    const result = f.run('success', autoUpdate);
    expect(result.error).toBeUndefined();
    expect(result.status, result.stderr).toBe(0);
    expect(f.read('bootstrap.sh')).toBe(f.bootstrap);
    expect(f.read('run')).toBe(`--AUTO_UPDATE=${autoUpdate ? 'enable' : 'disable'}\n2\n`);
    expect(existsSync(join(f.root, 'bootstrap.sh.tmp'))).toBe(false);
  }, 15000);

  it('uses wget when curl fails, replacing the partial download', () => {
    const f = fixture();
    expect(f.run('fallback').status).toBe(0);
    expect(f.read('calls')).toBe('curl\nwget\n');
    expect(f.read('bootstrap.sh')).toBe(f.bootstrap);
  }, 15000);

  it('uses a valid cache without contacting either downloader', () => {
    const f = fixture();
    writeFileSync(join(f.root, 'bootstrap.sh'), f.bootstrap);
    expect(f.run('fail').status).toBe(0);
    expect(existsSync(join(f.root, 'calls'))).toBe(false);
  }, 15000);

  it.each(['', 'if then\n'])('repairs an empty or invalid cache (%j)', (previous) => {
    const f = fixture();
    writeFileSync(join(f.root, 'bootstrap.sh'), previous);
    expect(f.run().status).toBe(0);
    expect(f.read('bootstrap.sh')).toBe(f.bootstrap);
  }, 15000);

  it('does not replace or execute an invalid cache when downloads fail', () => {
    const f = fixture();
    const previous = 'printf bad > "$FIXTURE_RUN"\nif then\n';
    writeFileSync(join(f.root, 'bootstrap.sh'), previous);
    expect(f.run('fail').status).not.toBe(0);
    expect(f.read('bootstrap.sh')).toBe(previous);
    expect(existsSync(join(f.root, 'run'))).toBe(false);
  }, 15000);

  it('rejects a downloaded syntax error before replacing the cache', () => {
    const f = fixture();
    writeFileSync(join(f.root, 'bootstrap.sh'), 'if then\n');
    writeFileSync(join(f.root, 'payload'), 'if then\n# bad download\n');
    expect(f.run().status).not.toBe(0);
    expect(f.read('bootstrap.sh')).toBe('if then\n');
    expect(existsSync(join(f.root, 'run'))).toBe(false);
  }, 15000);

  it('passes a quoted URL as one literal downloader argument', () => {
    const f = fixture();
    const url = "https://example.test/a'b ;$(touch injected)";
    expect(f.run('success', true, url).status).toBe(0);
    expect(f.read('urls')).toBe(`${url}\n`);
    expect(existsSync(join(f.root, 'injected'))).toBe(false);
  }, 15000);
});
