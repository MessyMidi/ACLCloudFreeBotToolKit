/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import { describe, expect, it } from 'vitest';
import { maskToken, parseMonitorCommand } from '../src/monitor-parser';

describe('parseMonitorCommand', () => {
  it('detects Lite and its remote-control flag', () => {
    const result = parseMonitorCommand(
      'wget -qO- https://raw.githubusercontent.com/nuomiiiii/Lite-agent/main/install.sh | sudo bash -s -- -e "https://lite.example.com" -t "secret-token" --enable-remote-control'
    );
    expect(result.errors).toEqual([]);
    expect(result.config).toEqual({
      type: 'lite',
      endpoint: 'https://lite.example.com',
      token: 'secret-token',
      remoteControl: true
    });
  });

  it('detects Komari and supports long options', () => {
    const result = parseMonitorCommand(
      'curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install.sh | bash -s -- --endpoint=https://komari.example.com --token=abc123'
    );
    expect(result.errors).toEqual([]);
    expect(result.config?.type).toBe('komari');
    expect(result.config?.remoteControl).toBe(true);
  });

  it('disables Komari remote control only when the negative flag is enabled', () => {
    const disabled = parseMonitorCommand(
      'curl https://github.com/komari-monitor/komari-agent/install.sh -e https://komari.example -t token --disable-web-ssh'
    );
    const explicitlyNotDisabled = parseMonitorCommand(
      'curl https://github.com/komari-monitor/komari-agent/install.sh -e https://komari.example -t token --disable-web-ssh=false'
    );
    expect(disabled.config?.remoteControl).toBe(false);
    expect(explicitlyNotDisabled.config?.remoteControl).toBe(true);
  });

  it('follows both explicit forms of the Lite positive flag', () => {
    const enabled = parseMonitorCommand(
      'curl https://github.com/nuomiiiii/Lite-agent/install.sh -e https://lite.example -t token --enable-remote-control'
    );
    const disabled = parseMonitorCommand(
      'curl https://github.com/nuomiiiii/Lite-agent/install.sh -e https://lite.example -t token --enable-remote-control=false'
    );
    expect(enabled.config?.remoteControl).toBe(true);
    expect(disabled.config?.remoteControl).toBe(false);
  });

  it('rejects invalid or repeated remote-control flags', () => {
    const invalid = parseMonitorCommand(
      'curl https://github.com/nuomiiiii/Lite-agent/install.sh -e https://lite.example -t token --enable-remote-control=maybe'
    );
    const repeated = parseMonitorCommand(
      'curl https://github.com/komari-monitor/komari-agent/install.sh -e https://komari.example -t token --disable-web-ssh --disable-web-ssh=false'
    );
    expect(invalid.errors).toContain('--enable-remote-control 的值必须是 true 或 false');
    expect(repeated.errors).toContain('命令中出现了多个 --disable-web-ssh，请只保留一个');
  });

  it('rejects duplicate credentials', () => {
    const result = parseMonitorCommand(
      'https://github.com/nuomiiiii/Lite-agent -e https://one.example -e https://two.example -t one -t two'
    );
    expect(result.errors).toContain('命令中出现了多个 endpoint，请只保留一个');
    expect(result.errors).toContain('命令中出现了多个 token，请只保留一个');
  });

  it('rejects unknown projects and malformed URLs', () => {
    const result = parseMonitorCommand('curl https://example.com/install.sh -e javascript:bad -t token');
    expect(result.errors).toContain('无法从安装脚本地址识别 Lite / Komari / CF Server Monitor');
    expect(result.errors).toContain('Endpoint 必须是有效的 http:// 或 https:// 地址');
  });

  it('detects CF Server Monitor and preserves official runtime options', () => {
    const result = parseMonitorCommand(
      "curl -fsSL 'https://raw.githubusercontent.com/huilang-me/cfsm-agent/main/install.sh' | sh -s -- install -id=server-id -secret='my secret' -url=https://worker.example.com/update -collect_interval=2 -interval=60 -connection_mode=http -ping_mode=icmp -reset_day=0 -ct='ct.example.com:80' -interface='eth0,eth1' -auto_update=1"
    );
    expect(result.errors).toEqual([]);
    expect(result.warnings).toContain('CFSM Agent 自更新将关闭，由本工具固定版本并校验 SHA256');
    expect(result.config).toEqual({
      type: 'cfsm',
      endpoint: 'https://worker.example.com/update',
      token: 'my secret',
      remoteControl: false,
      agentId: 'server-id',
      options: {
        collectInterval: 2,
        reportInterval: 60,
        connectionMode: 'http',
        pingMode: 'icmp',
        resetDay: 0,
        debug: false,
        ctNode: 'ct.example.com:80',
        cuNode: '',
        cmNode: '',
        bdNode: '',
        node1: '',
        node2: '',
        node3: '',
        node4: '',
        networkInterface: 'eth0,eth1'
      }
    });
  });

  it('rejects unsafe or unsupported CF Server Monitor install options', () => {
    const missing = parseMonitorCommand(
      'curl https://raw.githubusercontent.com/huilang-me/cfsm-agent/main/install.sh | sh -s -- install -id=abc'
    );
    expect(missing.errors).toContain('命令中缺少 -secret（Secret）');
    expect(missing.errors).toContain('命令中缺少 -url（URL）');

    const unsupported = parseMonitorCommand(
      'curl https://github.com/huilang-me/cfsm-agent -id=abc -secret=s -url=https://worker.example/update -rx_correction=1'
    );
    expect(unsupported.errors).toContain('ACLClouds 托管模式暂不支持一次性流量校正参数，请移除 -rx_correction / -tx_correction');
  });

  it('allows a deliberate manual type selection with a warning', () => {
    const result = parseMonitorCommand(
      'curl https://github.com/komari-monitor/komari-agent/install.sh -e https://monitor.example -t token',
      'lite'
    );
    expect(result.config?.type).toBe('lite');
    expect(result.warnings).toHaveLength(1);
  });
});

describe('maskToken', () => {
  it('does not expose a normal token', () => {
    expect(maskToken('super-secret-token')).toBe('su••••••••••••en');
  });
});
