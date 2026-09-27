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
import { detectLocale, getLocale, isMessageKey, setLocale, t } from './i18n';
import type { Locale, MessageKey, MessageParams } from './i18n';
import { maskToken, parseMonitorCommand } from './monitor-parser';
import { FORM_STORAGE_KEY, parseStoredState, renewalForStorage } from './storage';
import type { StoredFormState } from './storage';
import type { MonitorConfig, MonitorSelection, ProxyConfig, RenewalConfig } from './types';

const LOCALE_STORAGE_KEY = 'aclclouds:locale';
const THEME_STORAGE_KEY = 'aclclouds:theme';

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

interface StatusMessage {
  key: MessageKey;
  params?: MessageParams;
}

// Status lines are kept as message keys so they can be re-rendered when the
// language changes.
let outputStatus: StatusMessage = { key: 'output.waiting' };
let storageStatus: StatusMessage = { key: 'storage.initial' };

function setOutputStatus(key: MessageKey, params?: MessageParams): void {
  outputStatus = { key, params };
  byId('output-status').textContent = t(key, params);
}

function setStorageStatus(key: MessageKey): void {
  storageStatus = { key };
  byId('storage-status').textContent = t(key);
}

function readStorage(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}

function writeStorage(key: string, value: string): void {
  try { localStorage.setItem(key, value); } catch { /* Preferences are optional. */ }
}

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

function secretLabel(config: MonitorConfig): string {
  return config.type === 'cfsm' ? 'Secret' : 'Token';
}

function updateTokenPreview(): void {
  if (!parsedMonitor) return;
  byId('detected-token').textContent = tokenVisible ? parsedMonitor.token : maskToken(parsedMonitor.token);
  revealButton.classList.toggle('active', tokenVisible);
  revealButton.setAttribute('aria-label', t(tokenVisible ? 'monitor.hide' : 'monitor.show', { label: secretLabel(parsedMonitor) }));
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
  const previousToken = parsedMonitor?.token;
  parsedMonitor = result.config;
  parseResult.hidden = !parsedMonitor;
  if (!parsedMonitor) return;

  // Re-rendering the same command, after a language switch for example,
  // keeps a revealed token visible.
  if (parsedMonitor.token !== previousToken) tokenVisible = false;
  const isCfsm = parsedMonitor.type === 'cfsm';
  byId('detected-type').textContent = t('monitor.detected', { name: MONITOR_LABELS[parsedMonitor.type] });
  byId('label-endpoint').textContent = isCfsm ? 'URL' : 'Endpoint';
  byId('label-token').textContent = secretLabel(parsedMonitor);
  const idRow = byId<HTMLElement>('row-agent-id');
  const optionsRow = byId<HTMLElement>('row-cfsm-options');
  idRow.hidden = !isCfsm;
  optionsRow.hidden = !isCfsm;
  if (parsedMonitor.type === 'cfsm') {
    byId('detected-agent-id').textContent = parsedMonitor.agentId;
    byId('detected-cfsm-options').textContent = [
      t('monitor.sample', { seconds: parsedMonitor.options.collectInterval }),
      t('monitor.report', { seconds: parsedMonitor.options.reportInterval }),
      parsedMonitor.options.connectionMode.toUpperCase(),
      `Ping ${parsedMonitor.options.pingMode.toUpperCase()}`
    ].join(' · ');
  }
  byId('detected-endpoint').textContent = parsedMonitor.endpoint;
  byId('parse-warning').textContent = result.warnings.join(t('list.separator'));
  remoteControl.checked = parsedMonitor.remoteControl;
  remoteRow.hidden = isCfsm;
  if (!isCfsm) {
    byId('remote-title').textContent = t(parsedMonitor.remoteControl ? 'monitor.remoteOn' : 'monitor.remoteOff');
    const detailKey: MessageKey = parsedMonitor.type === 'lite'
      ? (parsedMonitor.remoteControl ? 'monitor.liteRemoteOn' : 'monitor.liteRemoteOff')
      : (parsedMonitor.remoteControl ? 'monitor.komariRemoteOn' : 'monitor.komariRemoteOff');
    byId('remote-detail').textContent = t(detailKey);
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

function clearGeneratedOutput(status: MessageKey = 'output.changed'): void {
  const generated = byId('generated-output');
  if (generated.hidden) return;
  generated.hidden = true;
  byId('empty-output').hidden = false;
  byId('env-output').textContent = '';
  byId('startup-output').textContent = '';
  setOutputStatus(status);
  byId('output-panel').classList.remove('ready');
}

function generate(scrollToResult = true): void {
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
  selectionError.textContent = allModulesDisabled ? t('generate.noModule') : '';
  if (allModulesDisabled || (monitorEnabled.checked && !monitor) || !validation.valid || !renewalValidation.valid) {
    clearGeneratedOutput('output.fix');
    setOutputStatus('output.fix');
    if (scrollToResult) document.querySelector('.field-error:not(:empty)')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    return;
  }

  byId('env-output').textContent = generateEnv(monitor, proxy, renewal, { consoleLanguage: getLocale() });
  byId('startup-output').textContent = generateStartupCommand(bootstrapUrl(), autoUpdate.checked);
  byId('empty-output').hidden = true;
  byId('generated-output').hidden = false;
  const enabledServices = [
    monitor ? MONITOR_LABELS[monitor.type] : '',
    proxy ? 'VLESS + REALITY' : '',
    renewal ? t('output.renewalService') : ''
  ].filter(Boolean).join(' + ');
  setOutputStatus('output.ready', { services: enabledServices });
  byId('output-panel').classList.add('ready');
  if (scrollToResult && window.innerWidth < 920) byId('output-panel').scrollIntoView({ behavior: 'smooth', block: 'start' });
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
  label.textContent = t('output.copied');
  button.classList.add('copied');
  toast(t(kind === 'env' ? 'output.envCopied' : 'output.startupCopied'));
  window.setTimeout(() => {
    label.textContent = t(kind === 'env' ? 'output.copyEnv' : 'output.copyStartup');
    button.classList.remove('copied');
  }, 1800);
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

/** Renders a message, showing `backtick` spans as inline code. */
function renderRichText(element: HTMLElement, text: string): void {
  element.replaceChildren(...text.split('`').map((part, index) => {
    if (index % 2 === 0) return document.createTextNode(part);
    const code = document.createElement('code');
    code.textContent = part;
    return code;
  }));
}

function translateElements(attribute: string, apply: (element: HTMLElement, text: string) => void): void {
  document.querySelectorAll<HTMLElement>(`[${attribute}]`).forEach((element) => {
    const key = element.getAttribute(attribute) ?? '';
    if (isMessageKey(key)) apply(element, t(key));
  });
}

function renderLocale(): void {
  const locale = getLocale();
  document.documentElement.lang = locale === 'zh' ? 'zh-CN' : 'en';
  document.title = t('meta.title');
  document.querySelector('meta[name="description"]')?.setAttribute('content', t('meta.description'));
  translateElements('data-i18n', (element, text) => { element.textContent = text; });
  translateElements('data-i18n-rich', renderRichText);
  translateElements('data-i18n-placeholder', (element, text) => element.setAttribute('placeholder', text));
  translateElements('data-i18n-aria-label', (element, text) => element.setAttribute('aria-label', text));
  translateElements('data-i18n-tooltip', (element, text) => element.setAttribute('data-tooltip', text));
  byId('output-status').textContent = t(outputStatus.key, outputStatus.params);
  byId('storage-status').textContent = t(storageStatus.key);
}

function switchLocale(locale: Locale): void {
  setLocale(locale);
  writeStorage(LOCALE_STORAGE_KEY, locale);
  renderLocale();
  // Messages built from user input are rebuilt in the new language.
  if (monitorEnabled.checked && commandInput.value.trim()) parseCommand();
  if (!byId('generated-output').hidden) {
    // Any edit hides the output, so it still matches the form. It is rebuilt
    // because the generated config also carries the Console language.
    generate(false);
  } else {
    refreshErrorMessages();
  }
}

/** Re-renders validation messages that are on screen in the current language. */
function refreshErrorMessages(): void {
  if (document.querySelector('[data-error-for]:not(:empty)')) renderProxyErrors(validateProxy(proxyConfig()).errors);
  if (document.querySelector('[data-renew-error-for]:not(:empty)')) renderRenewalErrors(validateRenewal(renewalConfig()).errors);
  const selectionError = byId('selection-error');
  if (selectionError.textContent) selectionError.textContent = t('generate.noModule');
}

function currentFormState(): StoredFormState {
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
    localStorage.setItem(FORM_STORAGE_KEY, JSON.stringify(currentFormState()));
    setStorageStatus(rememberRenewalSecrets.checked ? 'storage.saved' : 'storage.savedWithoutSecrets');
  } catch {
    setStorageStatus('storage.blocked');
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

function applyDefaultProxy(): void {
  Object.entries(DEFAULT_PROXY).forEach(([key, value]) => {
    const element = document.getElementById(key) as HTMLInputElement | HTMLSelectElement | null;
    if (element) element.value = value;
  });
}

function resetSavedState(): void {
  try { localStorage.removeItem(FORM_STORAGE_KEY); } catch { /* The form can still be reset in memory. */ }
  form.reset();
  rememberRenewalSecrets.checked = false;
  commandInput.value = '';
  applyDefaultProxy();
  parsedMonitor = undefined;
  tokenVisible = false;
  parseResult.hidden = true;
  showErrors([]);
  clearProxyErrors();
  clearRenewalErrors();
  syncModuleState('monitor-section', 'monitor-fields', monitorEnabled);
  syncModuleState('proxy-section', 'proxy-fields', proxyEnabled);
  syncModuleState('renewal-section', 'renewal-fields', renewalEnabled);
  clearGeneratedOutput('output.cleared');
  setStorageStatus('storage.cleared');
  toast(t('output.cleared'));
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
  writeStorage(THEME_STORAGE_KEY, dark ? 'dark' : 'light');
  applyTheme(dark);
});
byId('locale-toggle').addEventListener('click', () => switchLocale(getLocale() === 'zh' ? 'en' : 'zh'));
byId('clear-storage').addEventListener('click', resetSavedState);

const savedLocale = readStorage(LOCALE_STORAGE_KEY);
const browserLanguages = navigator.languages.length > 0 ? navigator.languages : [navigator.language];
setLocale(savedLocale === 'zh' || savedLocale === 'en' ? savedLocale : detectLocale(browserLanguages));
renderLocale();
renderVersions();
let storedState: StoredFormState | undefined;
try { storedState = parseStoredState(localStorage.getItem(FORM_STORAGE_KEY)); } catch { storedState = undefined; }
if (storedState) {
  applyStoredState(storedState);
  saveFormState();
  setStorageStatus(storedState.rememberRenewalSecrets ? 'storage.restored' : 'storage.restoredWithoutSecrets');
} else {
  applyDefaultProxy();
}
syncModuleState('monitor-section', 'monitor-fields', monitorEnabled);
syncModuleState('proxy-section', 'proxy-fields', proxyEnabled);
syncModuleState('renewal-section', 'renewal-fields', renewalEnabled);
if (commandInput.value.trim()) parseCommand();
const savedTheme = readStorage(THEME_STORAGE_KEY);
applyTheme(savedTheme ? savedTheme === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches);
