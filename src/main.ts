import './styles.css';
import { DEFAULT_PROXY, TESTED_VERSIONS } from './constants';
import { generateEnv, generateStartupCommand, validateProxy } from './generator';
import { maskToken, parseMonitorCommand } from './monitor-parser';
import type { MonitorConfig, MonitorSelection, ProxyConfig } from './types';

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
let parsedMonitor: MonitorConfig | undefined;
let tokenVisible = false;
let toastTimer = 0;

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
  revealButton.setAttribute('aria-label', tokenVisible ? '隐藏 Token' : '显示 Token');
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
  byId('detected-type').textContent = `已识别 ${parsedMonitor.type === 'lite' ? 'Lite' : 'Komari'}`;
  byId('detected-endpoint').textContent = parsedMonitor.endpoint;
  byId('parse-warning').textContent = result.warnings.join('；');
  remoteControl.checked = parsedMonitor.remoteControl;
  remoteRow.hidden = false;
  byId('remote-title').textContent = `远程控制：${parsedMonitor.remoteControl ? '开启' : '关闭'}`;
  byId('remote-detail').textContent = parsedMonitor.type === 'lite'
    ? (parsedMonitor.remoteControl ? '命令包含 --enable-remote-control' : '命令未开启，或显式设置为 false')
    : (parsedMonitor.remoteControl ? '命令未包含 --disable-web-ssh' : '命令包含 --disable-web-ssh');
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

function launcherUrl(): string {
  return 'https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases/download/v0.1.0/launcher.sh';
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
  const validation = proxy ? validateProxy(proxy) : { errors: {}, valid: true };
  renderProxyErrors(validation.errors);
  const selectionError = byId('selection-error');
  selectionError.textContent = !monitorEnabled.checked && !proxyEnabled.checked ? '请至少启用 Monitor 或代理中的一个' : '';
  if ((!monitorEnabled.checked && !proxyEnabled.checked) || (monitorEnabled.checked && !monitor) || !validation.valid) {
    clearGeneratedOutput('请修正标记的问题');
    byId('output-status').textContent = '请修正标记的问题';
    document.querySelector('.field-error:not(:empty)')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    return;
  }

  byId('env-output').textContent = generateEnv(monitor, proxy);
  byId('startup-output').textContent = generateStartupCommand(launcherUrl());
  byId('empty-output').hidden = true;
  byId('generated-output').hidden = false;
  const enabledServices = [
    monitor ? (monitor.type === 'lite' ? 'Lite' : 'Komari') : '',
    proxy ? 'VLESS + REALITY' : ''
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
    ['Komari Agent', TESTED_VERSIONS.komari.version]
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

commandInput.addEventListener('input', parseCommand);
form.addEventListener('input', () => clearGeneratedOutput());
form.querySelectorAll<HTMLInputElement>('input[name="monitorType"]').forEach((input) => input.addEventListener('change', parseCommand));
monitorEnabled.addEventListener('change', () => syncModuleState('monitor-section', 'monitor-fields', monitorEnabled));
proxyEnabled.addEventListener('change', () => syncModuleState('proxy-section', 'proxy-fields', proxyEnabled));
revealButton.addEventListener('click', () => { tokenVisible = !tokenVisible; updateTokenPreview(); });
form.addEventListener('submit', (event) => { event.preventDefault(); generate(); });
document.querySelectorAll<HTMLButtonElement>('[data-copy]').forEach((button) => button.addEventListener('click', () => void copyText(button.dataset.copy as 'env' | 'startup', button)));
byId('theme-toggle').addEventListener('click', () => {
  const dark = !document.body.classList.contains('dark');
  saveTheme(dark);
  applyTheme(dark);
});

renderVersions();
syncModuleState('monitor-section', 'monitor-fields', monitorEnabled);
syncModuleState('proxy-section', 'proxy-fields', proxyEnabled);
const savedTheme = readTheme();
applyTheme(savedTheme ? savedTheme === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches);
Object.entries(DEFAULT_PROXY).forEach(([key, value]) => {
  const element = document.getElementById(key) as HTMLInputElement | HTMLSelectElement | null;
  if (element) element.value = value;
});
