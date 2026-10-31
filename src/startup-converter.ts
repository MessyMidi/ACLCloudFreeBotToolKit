/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7: see /ADDITIONAL_TERMS.md
 */

import { BOOTSTRAP_URL } from './constants';
import { generateStartupCommand } from './generator';
import type { MessageKey } from './i18n';

export type StartupConversion =
  | { command: string; autoUpdate: boolean; error?: never }
  | { command?: never; autoUpdate?: never; error: MessageKey };

// Recognize literal words only. This never expands variables, substitutes
// commands, follows URLs, or executes pasted shell code.
function literalWords(input: string): string[] | undefined {
  const words: string[] = [];
  let word = '';
  let quote = '';
  let escaped = false;
  let comment = false;
  const push = () => { if (word) words.push(word); word = ''; };
  for (const char of input) {
    if (comment) { if (char === '\n') comment = false; continue; }
    if (escaped) { if (char !== '\n') word += char; escaped = false; continue; }
    if (char === '\\' && quote !== "'") { escaped = true; continue; }
    if (quote) {
      if (char === quote) quote = ''; else word += char;
    } else if (char === "'" || char === '"') {
      quote = char;
    } else if (char === '#' && !word) {
      comment = true;
    } else if (/\s|[;|&<>()]/.test(char)) {
      push();
    } else {
      word += char;
    }
  }
  if (quote || escaped) return undefined;
  push();
  return words;
}

function officialScript(value: string): boolean {
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password || url.port || url.search || url.hash) return false;
    const repo = '/MessyMidi/ACLCloudFreeBotToolKit/';
    const suffix = url.pathname.slice(repo.length);
    if (!url.pathname.toLowerCase().startsWith(repo.toLowerCase())) return false;
    if (url.hostname === 'github.com') return /^releases\/(?:latest\/download|download\/[^/]+)\/(?:bootstrap|launcher)\.sh$/.test(suffix);
    return url.hostname === 'raw.githubusercontent.com' && /^(?:refs\/heads\/)?[^/]+\/(?:bootstrap|launcher)\.sh$/.test(suffix);
  } catch { return false; }
}

export function convertStartupCommand(input: string, defaultAutoUpdate = true): StartupConversion {
  if (!input.trim()) return { error: 'converter.empty' };
  if (input.length > 12000 || [...input].some(c => { const n = c.charCodeAt(0); return (n < 32 && ![9, 10, 13].includes(n)) || n === 127; })) return { error: 'converter.invalidText' };
  const words = literalWords(input.replace(/\r\n?/g, '\n'));
  if (!words) return { error: 'converter.quotes' };
  if (words.some(w => /^(?:--UPDATE_CHANNEL(?:=|$)|--UPDATE_BASE_URL(?:=|$)|BOOTSTRAP_UPDATE_CHANNEL=|ACL_UPDATE_BASE_URL=)/.test(w))) return { error: 'converter.customChannel' };
  const urls = words.map(w => w.replace(/^[A-Za-z_][A-Za-z0-9_]*=/, '')).filter(w => /^https?:\/\//i.test(w));
  if (urls.some(u => !officialScript(u))) return { error: 'converter.customUrl' };
  const localBootstrap = words.some((w, i) => w === 'bash' && ['bootstrap.sh', './bootstrap.sh'].includes(words[i + 1] ?? ''));
  if (!urls.length && !localBootstrap) return { error: 'converter.unrecognized' };
  const settings: string[] = [];
  for (let i = 0; i < words.length; i++) {
    const word = words[i]!;
    if (word === '--AUTO_UPDATE') settings.push(words[++i] ?? '');
    else if (word.startsWith('--AUTO_UPDATE=')) settings.push(word.slice('--AUTO_UPDATE='.length));
  }
  if (settings.length > 1 || settings.some(s => s !== 'enable' && s !== 'disable')) return { error: 'converter.invalidUpdate' };
  const autoUpdate = settings.length ? settings[0] === 'enable' : defaultAutoUpdate;
  return { command: generateStartupCommand(BOOTSTRAP_URL, autoUpdate), autoUpdate };
}
