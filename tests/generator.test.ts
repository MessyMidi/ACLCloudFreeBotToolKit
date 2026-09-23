import { describe, expect, it } from 'vitest';
import { CLIENT_FINGERPRINTS } from '../src/constants';
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

  it('generates a proxy-only config without monitor credentials', () => {
    const output = generateEnv(undefined, proxy);
    expect(output).toContain("MONITOR_ENABLED='0'");
    expect(output).toContain("MIHOMO_ENABLED='1'");
    expect(output).not.toContain('MONITOR_TOKEN=');
    expect(output).toContain("REALITY_SNI='www.cloudflare.com'");
  });

  it('generates a monitor-only config without Mihomo settings', () => {
    const output = generateEnv(monitor, undefined);
    expect(output).toContain("MONITOR_ENABLED='1'");
    expect(output).toContain("MIHOMO_ENABLED='0'");
    expect(output).toContain("MONITOR_TOKEN='abc'\\''def;$()'");
    expect(output).not.toContain('REALITY_SNI=');
  });

  it('refuses to generate a config with every service disabled', () => {
    expect(() => generateEnv(undefined, undefined)).toThrow('至少启用一个服务');
  });

  it('emits CF Server Monitor variables while keeping launcher monitor disabled', () => {
    const output = generateEnv(
      { type: 'cfsm', endpoint: 'https://example.com/update', token: 'sekret', remoteControl: false, agentId: 'srv-1' },
      proxy
    );
    expect(output).toContain("MONITOR_ENABLED='0'");
    expect(output).toContain("CFSM_ID='srv-1'");
    expect(output).toContain("CFSM_SECRET='sekret'");
    expect(output).toContain("CFSM_URL='https://example.com/update'");
    expect(output).not.toContain('MONITOR_TYPE=');
    expect(output).not.toContain('MONITOR_SHA256=');
  });

  it('prepends the CF install script to the startup command referencing config.env vars', () => {
    const output = generateStartupCommand('https://tool.example/launcher.sh', {
      type: 'cfsm',
      endpoint: 'https://example.com/update',
      token: 'sekret',
      remoteControl: false,
      agentId: 'srv-1'
    });
    expect(output).toContain("curl -fsSL 'https://raw.githubusercontent.com/huilang-me/cfsm-agent/main/install.sh' | sh -s -- install -id=\"$CFSM_ID\" -secret=\"$CFSM_SECRET\" -url=\"$CFSM_URL\"");
    expect(output).toContain('exec bash launcher.sh');
    // Real credentials never leak into the startup command; only config.env holds them.
    expect(output).not.toContain('sekret');
    expect(output).not.toContain('srv-1');
  });
});

describe('validateProxy', () => {
  it('accepts the launcher defaults', () => {
    expect(validateProxy(proxy).valid).toBe(true);
  });

  it.each(CLIENT_FINGERPRINTS)('accepts the supported %s fingerprint', (fingerprint) => {
    expect(validateProxy({ ...proxy, fingerprint }).valid).toBe(true);
  });

  it('rejects fingerprints outside the Mihomo and VLESS common set', () => {
    const result = validateProxy({ ...proxy, fingerprint: 'randomized' });
    expect(result.errors.fingerprint).toBeTruthy();
  });

  it('rejects missing ports and unsafe remarks', () => {
    const result = validateProxy({ ...proxy, destination: 'example.com', remark: 'bad remark;rm' });
    expect(result.errors.destination).toBeTruthy();
    expect(result.errors.remark).toBeTruthy();
  });
});
