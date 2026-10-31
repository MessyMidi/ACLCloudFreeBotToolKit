/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7: see /ADDITIONAL_TERMS.md
 */
import { describe, expect, it } from 'vitest';
import { BOOTSTRAP_URL } from '../src/constants';
import { generateStartupCommand } from '../src/generator';
import { convertStartupCommand } from '../src/startup-converter';

const launcher = 'https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases/download/v0.2.0-pre1/launcher.sh';
const old = `LAUNCHER_URL='${launcher}'; curl -fL --retry 3 -o launcher.sh "$LAUNCHER_URL" && chmod +x launcher.sh && exec bash launcher.sh`;

describe('convertStartupCommand', () => {
  it.each([old, `wget -O launcher.sh '${launcher}' && bash launcher.sh`, `curl -fsSL https://raw.githubusercontent.com/MessyMidi/ACLCloudFreeBotToolKit/main/launcher.sh | bash`, `exec bash ./bootstrap.sh`])('converts a known legacy entry point', input => {
    expect(convertStartupCommand(input)).toEqual({ command: generateStartupCommand(BOOTSTRAP_URL, true), autoUpdate: true });
  });
  it.each([true, false])('retains the explicit update switch %s', enabled => {
    const command = generateStartupCommand(BOOTSTRAP_URL, enabled);
    expect(convertStartupCommand(command)).toEqual({ command, autoUpdate: enabled });
    expect(command.length).toBeLessThanOrEqual(255);
  });
  it('uses the current switch when the old command does not specify it', () => {
    expect(convertStartupCommand(old, false).autoUpdate).toBe(false);
  });
  it('handles quoted flags, CRLF, continuations and comments', () => {
    const result = convertStartupCommand(`u="${BOOTSTRAP_URL}"; \\\r\n exec bash bootstrap.sh '--AUTO_UPDATE=disable' # --AUTO_UPDATE=enable\r\n`);
    expect(result.autoUpdate).toBe(false);
  });
  it.each(['https://github.com.attacker.test/MessyMidi/ACLCloudFreeBotToolKit/launcher.sh', 'https://github.com/other/tool/releases/latest/download/bootstrap.sh', `${BOOTSTRAP_URL}?token=private`, 'https://private@github.com/MessyMidi/ACLCloudFreeBotToolKit/releases/latest/download/bootstrap.sh'])('rejects custom/spoofed/credential-bearing URLs', url => {
    expect(convertStartupCommand(`curl '${url}' | bash`).error).toBe('converter.customUrl');
  });
  it.each(['--AUTO_UPDATE=maybe', '--AUTO_UPDATE=disable --AUTO_UPDATE=enable', '--AUTO_UPDATE'])('rejects ambiguous update settings', setting => {
    expect(convertStartupCommand(`bash bootstrap.sh ${setting}`).error).toBe('converter.invalidUpdate');
  });
  it.each(['--UPDATE_CHANNEL=prerelease', 'ACL_UPDATE_BASE_URL=https://example.test', 'BOOTSTRAP_UPDATE_CHANNEL=prerelease'])('does not silently migrate test channels or custom bases', setting => {
    expect(convertStartupCommand(`${setting}; bash bootstrap.sh`).error).toBe('converter.customChannel');
  });
  it('does not carry arbitrary commands, HTML, or credentials into output', () => {
    const result = convertStartupCommand(`${old}; $(touch injected); TOKEN='secret'; echo '<img src=x onerror=alert(1)>'`);
    expect(result.command).toBe(generateStartupCommand(BOOTSTRAP_URL, true));
    expect(result.command).not.toMatch(/secret|injected|onerror/);
  });
  it.each(['', "bash bootstrap.sh '", 'unknown command', `bash bootstrap.sh\0`, 'x'.repeat(12001)])('rejects empty, malformed, unknown and oversized input', input => {
    const result = convertStartupCommand(input);
    expect(result.error).toBeTruthy();
    expect(result.command).toBeUndefined();
  });
});
