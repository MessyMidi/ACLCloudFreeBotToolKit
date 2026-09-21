import { describe, expect, it } from 'vitest';
import { generateEnv, generateStartupCommand, shellQuote, validateProxy } from '../src/generator';

const monitor = {
  type: 'lite' as const,
  endpoint: 'https://lite.example.com',
  token: "abc'def;$()",
  remoteControl: false
};
const proxy = {
  sni: 'www.cloudflare.com',
  destination: 'www.cloudflare.com:443',
  fingerprint: 'chrome',
  remark: 'ACLClouds-Free'
};

describe('shellQuote', () => {
  it('safely escapes embedded single quotes', () => {
    expect(shellQuote("a'b")).toBe("'a'\\''b'");
  });

  it('rejects line breaks and control characters', () => {
    expect(() => shellQuote('a\nb')).toThrow('配置值不能包含换行或控制字符');
  });
});

describe('generateEnv', () => {
  it('uses the unified monitor schema and fixed versions', () => {
    const output = generateEnv(monitor, proxy);
    expect(output).toContain("MONITOR_TYPE='lite'");
    expect(output).toContain("MONITOR_TOKEN='abc'\\''def;$()'");
    expect(output).toContain("MIHOMO_VERSION='v1.19.31'");
    expect(output).not.toContain('SERVER_IP=');
  });

  it('keeps credentials out of the startup command', () => {
    const output = generateStartupCommand('https://tool.example/launcher.sh');
    expect(output).toContain('https://tool.example/launcher.sh');
    expect(output).not.toContain(monitor.token);
    expect(output).not.toContain(monitor.endpoint);
  });
});

describe('validateProxy', () => {
  it('accepts the launcher defaults', () => {
    expect(validateProxy(proxy).valid).toBe(true);
  });

  it('rejects missing ports and unsafe remarks', () => {
    const result = validateProxy({ ...proxy, destination: 'example.com', remark: 'bad remark;rm' });
    expect(result.errors.destination).toBeTruthy();
    expect(result.errors.remark).toBeTruthy();
  });
});
