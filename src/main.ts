/*
 * ACLCloudFreeBotToolKit
 * Copyright (C) 2026 MessyMidi
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7:
 * see /ADDITIONAL_TERMS.md
 */

import './styles.css';
import { DEFAULT_PROXY, MONITOR_LABELS, TESTED_VERSIONS } from './constants';
import { generateEnv, generateStartupCommand, validateProxy, validateRenewal } from './generator';
import { maskToken, parseMonitorCommand } from './monitor-parser';
import { FORM_STORAGE_KEY, parseStoredState, renewalForStorage } from './storage';
import type { StoredFormState } from './storage';
import type { MonitorConfig, MonitorSelection, ProxyConfig, RenewalConfig } from './types';

const byId = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T;
const form = byId<HTMLFormElement>('generator-form');
const commandInput = byId<HTMLTextAreaElement>('monitor-command');
const parseResult = byId<HTMLElement>('parse-result');
const errorBox = byId<HTMLElement>('monitor-errors');
const remoteControl = byId<HTMLInputElement>('remote-control');
const remoteRow = byId<HTMLElement>('remote-row');
const revealButton = byId<HTMLButtonElement>('reveal-token');
const monitorEnabled = byId<HTMLInputElement>('monitor-enabled');
const proxyEnabled = byId<HTMLInputElement>('proxy-enabled');
const autoUpdate = byId<HTMLInputElement>('auto-update');
const renewalEnabled = byId<HTMLInputElement>('renewal-enabled');
const rememberRenewalSecrets = byId<HTMLInputElement>('remember-renewal-secrets');
let parsedMonitor: MonitorConfig | undefined;
let tokenVisible = false;
let toastTimer = 0;
let saveTimer = 0;

function selectedMonitorType(): MonitorSelection {
  return (form.elements.namedItem('monitorType') as RadioNodeList).value as MonitorSelection;
}

function showErrors(errors: string[]): void {
  errorBox.replaceChildren(...errors.map((message) => {
    const item = document.createElement('p');
    item.textContent = message;
    return item;
  }));
}

function updateTokenPreview(): void {
  if (!parsedMonitor) return;
  byId('detected-token').textContent = tokenVisible ? parsedMonitor.token : maskToken(parsedMonitor.token);
  revealButton.classList.toggle('active', tokenVisible);
  const secretLabel = parsedMonitor.type === 'cfsm' ? 'Secret' : 'Token';
  revealButton.setAttribute('aria-label', `${tokenVisible ? '隐藏' : '显示'} ${secretLabel}`);
}

function parseCommand(): void {
  if (!monitorEnabled.checked) {
    showErrors([]);
    parsedMonitor = undefined;
    parseResult.hidden = true;
    return;
  }
  const result = parseMonitorCommand(commandInput.value, selectedMonitorType());
  showErrors(result.errors);
  parsedMonitor = result.config;
  parseResult.hidden = !parsedMonitor;
  if (!parsedMonitor) return;

  tokenVisible = false;
  const isCfsm = parsedMonitor.type === 'cfsm';
  byId('detected-type').textContent = `已识别 ${MONITOR_LABELS[parsedMonitor.type]}`;
  byId('label-endpoint').textContent = isCfsm ? 'URL' : 'Endpoint';
  byId('label-token').textContent = isCfsm ? 'Secret' : 'Token';
  const idRow = byId<HTMLElement>('row-agent-id');
  const optionsRow = byId<HTMLElement>('row-cfsm-options');
  idRow.hidden = !isCfsm;
  optionsRow.hidden = !isCfsm;
  if (parsedMonitor.type === 'cfsm') {
    byId('detected-agent-id').textContent = parsedMonitor.agentId;
    byId('detected-cfsm-options').textContent = [
      `采样 ${parsedMonitor.options.collectInterval}s`,
      `上报 ${parsedMonitor.options.reportInterval}s`,
      parsedMonitor.options.connectionMode.toUpperCase(),
      `Ping ${parsedMonitor.options.pingMode.toUpperCase()}`
    ].join(' · ');
  }
  byId('detected-endpoint').textContent = parsedMonitor.endpoint;
  byId('parse-warning').textContent = result.warnings.join('；');
  remoteControl.checked = parsedMonitor.remoteControl;
  remoteRow.hidden = isCfsm;
  if (!isCfsm) {
    byId('remote-title').textContent = `远程控制：${parsedMonitor.remoteControl ? '开启' : '关闭'}`;
    byId('remote-detail').textContent = parsedMonitor.type === 'lite'
      ? (parsedMonitor.remoteControl ? '命令包含 --enable-remote-control' : '命令未开启，或显式设置为 false')
      : (parsedMonitor.remoteControl ? '命令未包含 --disable-web-ssh' : '命令包含 --disable-web-ssh');
  }
  updateTokenPreview();
}

function proxyConfig(): ProxyConfig {
  return {
    sni: byId<HTMLInputElement>('sni').value.trim(),
    destination: byId<HTMLInputElement>('destination').value.trim(),
    fingerprint: byId<HTMLSelectElement>('fingerprint').value,
    remark: byId<HTMLInputElement>('remark').value.trim()
  };
}

function renewalConfig(): RenewalConfig {
  return {
    username: byId<HTMLInputElement>('acl-username').value.trim(),
    password: byId<HTMLInputElement>('acl-password').value,
    serverId: byId<HTMLInputElement>('acl-server-id').value.trim(),
    telegramBotToken: byId<HTMLInputElement>('telegram-bot-token').value.trim(),
    telegramChatId: byId<HTMLInputElement>('telegram-chat-id').value.trim()
  };
}

function clearProxyErrors(): void {
  document.querySelectorAll<HTMLElement>('[data-error-for]').forEach((element) => { element.textContent = ''; });
}

function renderProxyErrors(errors: ReturnType<typeof validateProxy>['errors']): void {
  clearProxyErrors();
  Object.entries(errors).forEach(([field, message]) => {
    const element = document.querySelector<HTMLElement>(`[data-error-for="${field}"]`);
    if (element) element.textContent = message;
  });
}

function clearRenewalErrors(): void {
  document.querySelectorAll<HTMLElement>('[data-renew-error-for]').forEach((element) => { element.textContent = ''; });
}

function renderRenewalErrors(errors: ReturnType<typeof validateRenewal>['errors']): void {
  clearRenewalErrors();
  Object.entries(errors).forEach(([field, message]) => {
    const element = document.querySelector<HTMLElement>(`[data-renew-error-for="${field}"]`);
    if (element) element.textContent = message;
  });
}

function bootstrapUrl(): string {
  return 'https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases/latest/download/bootstrap.sh';
}

function clearGeneratedOutput(status = '配置已更改，请重新生成'): void {
  const generated = byId('generated-output');
  if (generated.hidden) return;
  generated.hidden = true;
  byId('empty-output').hidden = false;
  byId('env-output').textContent = '';
  byId('startup-output').textContent = '';
  byId('output-status').textContent = status;
  byId('output-panel').classList.remove('ready');
}

function generate(): void {
  parseCommand();
  const monitor = monitorEnabled.checked ? parsedMonitor : undefined;
  const proxy = proxyEnabled.checked ? proxyConfig() : undefined;
  const renewal = renewalEnabled.checked ? renewalConfig() : undefined;
  const validation = proxy ? validateProxy(proxy) : { errors: {}, valid: true };
  const renewalValidation = renewal ? validateRenewal(renewal) : { errors: {}, valid: true };
  renderProxyErrors(validation.errors);
  renderRenewalErrors(renewalValidation.errors);
  const selectionError = byId('selection-error');
  const allModulesDisabled = !monitorEnabled.checked && !proxyEnabled.checked && !renewalEnabled.checked;
  selectionError.textContent = allModulesDisabled ? '请至少启用 Monitor、代理或自动延期中的一个' : '';
  if (allModulesDisabled || (monitorEnabled.checked && !monitor) || !validation.valid || !renewalValidation.valid) {
    clearGeneratedOutput('请修正标记的问题');
    byId('output-status').textContent = '请修正标记的问题';
    document.querySelector('.field-error:not(:empty)')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    return;
  }

  byId('env-output').textContent = generateEnv(monitor, proxy, renewal);
  byId('startup-output').textContent = generateStartupCommand(bootstrapUrl(), autoUpdate.checked);
  byId('empty-output').hidden = true;
  byId('generated-output').hidden = false;
  const enabledServices = [
    monitor ? MONITOR_LABELS[monitor.type] : '',
    proxy ? 'VLESS + REALITY' : '',
    renewal ? '自动延期' : ''
  ].filter(Boolean).join(' + ');
  byId('output-status').textContent = `${enabledServices} · 配置已就绪`;
  byId('output-panel').classList.add('ready');
  if (window.innerWidth < 920) byId('output-panel').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function toast(message: string): void {
  const element = byId('toast');
  element.textContent = message;
  element.hidden = false;
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => { element.hidden = true; }, 2200);
}

async function copyText(kind: 'env' | 'startup', button: HTMLButtonElement): Promise<void> {
  const source = kind === 'env' ? byId('env-output') : byId('startup-output');
  const text = source.textContent ?? '';
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const area = document.createElement('textarea');
    area.value = text;
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.append(area);
    area.select();
    document.execCommand('copy');
    area.remove();
  }
  const label = button.querySelector('span')!;
  const original = label.textContent;
  label.textContent = '已复制';
  button.classList.add('copied');
  toast(kind === 'env' ? 'config.env 已复制' : 'Startup Command 已复制');
  window.setTimeout(() => { label.textContent = original; button.classList.remove('copied'); }, 1800);
}

function renderVersions(): void {
  const entries = [
    ['Mihomo', TESTED_VERSIONS.mihomo.version],
    ['Lite Agent', TESTED_VERSIONS.lite.version],
    ['Komari Agent', TESTED_VERSIONS.komari.version],
    ['CF Server Monitor', TESTED_VERSIONS.cfsm.version]
  ];
  byId('version-list').replaceChildren(...entries.map(([name, version]) => {
    const row = document.createElement('div');
    const label = document.createElement('span');
    const value = document.createElement('code');
    label.textContent = name!;
    value.textContent = version!;
    row.append(label, value);
    return row;
  }));
}

function syncModuleState(sectionId: string, fieldsId: string, toggle: HTMLInputElement): void {
  const section = byId(sectionId);
  const fields = byId<HTMLFieldSetElement>(fieldsId);
  fields.disabled = !toggle.checked;
  section.classList.toggle('module-disabled', !toggle.checked);
  byId('selection-error').textContent = '';
  if (toggle === monitorEnabled) {
    if (!toggle.checked || commandInput.value.trim()) parseCommand();
    else showErrors([]);
  }
  if (toggle === proxyEnabled && !toggle.checked) clearProxyErrors();
  if (toggle === renewalEnabled && !toggle.checked) clearRenewalErrors();
}

function applyTheme(dark: boolean): void {
  document.body.classList.toggle('dark', dark);
  const icon = byId('theme-toggle').querySelector('use')!;
  icon.setAttribute('href', dark ? '#i-sun' : '#i-moon');
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', dark ? '#15221c' : '#f6f8fa');
}

function readTheme(): string | null {
  try { return localStorage.getItem('aclclouds:theme'); } catch { return null; }
}

function saveTheme(dark: boolean): void {
  try { localStorage.setItem('aclclouds:theme', dark ? 'dark' : 'light'); } catch { /* Theme persistence is optional. */ }
}

function currentStoredState(): StoredFormState {
  const renewal = renewalConfig();
  return {
    version: 3,
    monitorEnabled: monitorEnabled.checked,
    monitorType: selectedMonitorType(),
    monitorCommand: commandInput.value,
    proxyEnabled: proxyEnabled.checked,
    proxy: proxyConfig(),
    autoUpdate: autoUpdate.checked,
    renewalEnabled: renewalEnabled.checked,
    rememberRenewalSecrets: rememberRenewalSecrets.checked,
    renewal: renewalForStorage(renewal, rememberRenewalSecrets.checked)
  };
}

function saveFormState(): void {
  try {
    localStorage.setItem(FORM_STORAGE_KEY, JSON.stringify(currentStoredState()));
    byId('storage-status').textContent = rememberRenewalSecrets.checked
      ? '配置与续期凭证已保存在此浏览器'
      : '配置已保存；续期密码和 Token 未保存';
  } catch {
    byId('storage-status').textContent = '浏览器拒绝了本地保存';
  }
}

function scheduleFormSave(): void {
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(saveFormState, 200);
}

function applyStoredState(state: StoredFormState): void {
  monitorEnabled.checked = state.monitorEnabled;
  proxyEnabled.checked = state.proxyEnabled;
  autoUpdate.checked = state.autoUpdate;
  renewalEnabled.checked = state.renewalEnabled;
  rememberRenewalSecrets.checked = state.rememberRenewalSecrets;
  commandInput.value = state.monitorCommand;
  const monitorType = form.querySelector<HTMLInputElement>(`input[name="monitorType"][value="${state.monitorType}"]`);
  if (monitorType) monitorType.checked = true;
  byId<HTMLInputElement>('sni').value = state.proxy.sni;
  byId<HTMLInputElement>('destination').value = state.proxy.destination;
  byId<HTMLSelectElement>('fingerprint').value = state.proxy.fingerprint;
  byId<HTMLInputElement>('remark').value = state.proxy.remark;
  byId<HTMLInputElement>('acl-username').value = state.renewal.username;
  byId<HTMLInputElement>('acl-password').value = state.renewal.password;
  byId<HTMLInputElement>('acl-server-id').value = state.renewal.serverId;
  byId<HTMLInputElement>('telegram-bot-token').value = state.renewal.telegramBotToken;
  byId<HTMLInputElement>('telegram-chat-id').value = state.renewal.telegramChatId;
}

function resetSavedState(): void {
  try { localStorage.removeItem(FORM_STORAGE_KEY); } catch { /* The form can still be reset in memory. */ }
  form.reset();
  commandInput.value = '';
  Object.entries(DEFAULT_PROXY).forEach(([key, value]) => {
    const element = document.getElementById(key) as HTMLInputElement | HTMLSelectElement | null;
    if (element) element.value = value;
  });
  parsedMonitor = undefined;
  tokenVisible = false;
  parseResult.hidden = true;
  showErrors([]);
  clearProxyErrors();
  clearRenewalErrors();
  syncModuleState('monitor-section', 'monitor-fields', monitorEnabled);
  syncModuleState('proxy-section', 'proxy-fields', proxyEnabled);
  syncModuleState('renewal-section', 'renewal-fields', renewalEnabled);
  clearGeneratedOutput('本地配置已清除');
  byId('storage-status').textContent = '已清除；下一次修改会重新保存';
  toast('本地配置已清除');
}

commandInput.addEventListener('input', parseCommand);
form.addEventListener('input', () => { clearGeneratedOutput(); scheduleFormSave(); });
form.addEventListener('change', scheduleFormSave);
form.querySelectorAll<HTMLInputElement>('input[name="monitorType"]').forEach((input) => input.addEventListener('change', parseCommand));
monitorEnabled.addEventListener('change', () => syncModuleState('monitor-section', 'monitor-fields', monitorEnabled));
proxyEnabled.addEventListener('change', () => syncModuleState('proxy-section', 'proxy-fields', proxyEnabled));
renewalEnabled.addEventListener('change', () => syncModuleState('renewal-section', 'renewal-fields', renewalEnabled));
rememberRenewalSecrets.addEventListener('change', saveFormState);
revealButton.addEventListener('click', () => { tokenVisible = !tokenVisible; updateTokenPreview(); });
form.addEventListener('submit', (event) => { event.preventDefault(); generate(); });
document.querySelectorAll<HTMLButtonElement>('[data-copy]').forEach((button) => button.addEventListener('click', () => void copyText(button.dataset.copy as 'env' | 'startup', button)));
byId('theme-toggle').addEventListener('click', () => {
  const dark = !document.body.classList.contains('dark');
  saveTheme(dark);
  applyTheme(dark);
});
byId('clear-storage').addEventListener('click', resetSavedState);

renderVersions();
let storedState: StoredFormState | undefined;
try { storedState = parseStoredState(localStorage.getItem(FORM_STORAGE_KEY)); } catch { storedState = undefined; }
if (storedState) {
  applyStoredState(storedState);
  saveFormState();
  byId('storage-status').textContent = storedState.rememberRenewalSecrets
    ? '已恢复配置与续期凭证'
    : '已恢复配置；续期密码和 Token 未保存';
} else {
  Object.entries(DEFAULT_PROXY).forEach(([key, value]) => {
    const element = document.getElementById(key) as HTMLInputElement | HTMLSelectElement | null;
    if (element) element.value = value;
  });
}
syncModuleState('monitor-section', 'monitor-fields', monitorEnabled);
syncModuleState('proxy-section', 'proxy-fields', proxyEnabled);
syncModuleState('renewal-section', 'renewal-fields', renewalEnabled);
if (commandInput.value.trim()) parseCommand();
const savedTheme = readTheme();
applyTheme(savedTheme ? savedTheme === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches);
