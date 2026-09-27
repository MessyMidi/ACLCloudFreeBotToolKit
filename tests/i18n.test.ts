/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

/// <reference types="vite/client" />
import { afterEach, describe, expect, it } from 'vitest';
import indexHtml from '../index.html?raw';
import { validateProxy } from '../src/generator';
import { detectLocale, isMessageKey, MESSAGES, setLocale, t } from '../src/i18n';
import { parseMonitorCommand } from '../src/monitor-parser';

afterEach(() => setLocale('zh'));

describe('t', () => {
  it('fills placeholders and leaves unknown ones visible', () => {
    expect(t('monitor.detected', { name: 'Komari' })).toBe('已识别 Komari');
    expect(t('parse.range', { label: 'X', minimum: 0 })).toBe('X必须在 0-{maximum} 范围内');
  });

  it('switches the language of validation messages', () => {
    setLocale('en');
    const parsed = parseMonitorCommand('curl https://example.com/install.sh -e javascript:bad -t token');
    expect(parsed.errors).toContain('Could not recognise Lite, Komari, or CF Server Monitor from the install script URL');
    expect(parsed.errors).toContain('Endpoint must be a valid http:// or https:// address');
    expect(validateProxy({ sni: '', destination: 'example.com', fingerprint: 'chrome', remark: 'ok' }).errors).toEqual({
      sni: 'Enter the REALITY SNI',
      destination: 'Use host:port with a valid port'
    });
  });
});

describe('detectLocale', () => {
  it('follows the first supported browser language', () => {
    expect(detectLocale(['zh-CN', 'en'])).toBe('zh');
    expect(detectLocale(['zh-TW'])).toBe('zh');
    expect(detectLocale(['fr-FR', 'en-GB', 'zh-CN'])).toBe('en');
    expect(detectLocale(['ja-JP', 'zh-CN'])).toBe('zh');
    expect(detectLocale(['ja-JP'])).toBe('en');
    expect(detectLocale([])).toBe('en');
  });
});

describe('message catalogs', () => {
  it('translate every message into both languages', () => {
    expect(Object.keys(MESSAGES.en).sort()).toEqual(Object.keys(MESSAGES.zh).sort());
    for (const locale of ['zh', 'en'] as const) {
      for (const [key, text] of Object.entries(MESSAGES[locale])) {
        expect(text.trim(), `${locale} ${key}`).not.toBe('');
        expect(text.split('`').length % 2, `${locale} ${key} has unbalanced backticks`).toBe(1);
      }
    }
  });

  it('use the same placeholders in both languages', () => {
    const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((match) => match[1]).sort();
    for (const [key, text] of Object.entries(MESSAGES.zh)) {
      expect(placeholders(MESSAGES.en[key as keyof typeof MESSAGES.en]), key).toEqual(placeholders(text));
    }
  });

  it('cover every key used by index.html', () => {
    const keys = [...indexHtml.matchAll(/data-i18n(?:-[a-z-]+)?="([^"]+)"/g)].map((match) => match[1]!);
    expect(keys.length).toBeGreaterThan(50);
    for (const key of keys) expect(isMessageKey(key), key).toBe(true);
  });

  it('match the Chinese text that index.html shows before the script runs', () => {
    const plain = [...indexHtml.matchAll(/data-i18n="([^"]+)"[^>]*>([^<]*)</g)];
    expect(plain.length).toBeGreaterThan(40);
    for (const [, key = '', text] of plain) {
      expect(isMessageKey(key) ? MESSAGES.zh[key] : `unknown key ${key}`, key).toBe(text);
    }
  });
});
