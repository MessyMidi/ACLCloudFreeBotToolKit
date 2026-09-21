export type MonitorType = 'lite' | 'komari';
export type MonitorSelection = 'auto' | MonitorType;

export interface MonitorConfig {
  type: MonitorType;
  endpoint: string;
  token: string;
  remoteControl: boolean;
}

export interface ProxyConfig {
  sni: string;
  destination: string;
  fingerprint: string;
  remark: string;
}

export interface ParseResult {
  config?: MonitorConfig;
  errors: string[];
  warnings: string[];
}

export interface ValidationResult {
  errors: Partial<Record<keyof ProxyConfig, string>>;
  valid: boolean;
}
