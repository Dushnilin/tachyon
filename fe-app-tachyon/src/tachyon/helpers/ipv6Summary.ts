import { tr } from './i18n';
import type { StoreType } from '../services/store.service';

export type IPv6EffectiveState =
  | 'disabled'
  | 'leak_guard'
  | 'tunnel_over_v4'
  | 'full';

export type IPv6Mode = 'off' | 'auto' | 'dual_stack' | 'tunnel_over_v4';

export interface IPv6RuntimeSnapshot {
  ipv6Mode: IPv6Mode;
  effectiveState: IPv6EffectiveState;
  modeLabel: string;
  configuredModeLabel: string;
  leakGuardActive: boolean;
  webrtcGuardActive: boolean;
  fakeIpEnabled: boolean;
  fakeIp4Range: string;
  fakeIp6Range: string;
  dnsStrategy: string;
  wan6Label: string;
  hasWan6: boolean;
  warningText: string;
  isWarning: boolean;
}

interface UciReader {
  get?: (pkg: string, sec: string, opt: string) => unknown;
  sections?: (pkg: string, type: string) => Array<Record<string, unknown>>;
}

function uciReader(): UciReader | null {
  try {
    const lexicalUci =
      typeof uci !== 'undefined' ? (uci as unknown as UciReader) : null;
    if (lexicalUci && typeof lexicalUci.get === 'function') return lexicalUci;
    const g = globalThis as {
      uci?: UciReader;
      L?: { uci?: UciReader };
    };
    return g.uci || g.L?.uci || null;
  } catch {
    // ignore outside LuCI runtime
  }
  return null;
}

function readUciSetting(option: string): string {
  try {
    const reader = uciReader();
    if (reader && typeof reader.get === 'function') {
      const val = reader.get('tachyon', 'settings', option);
      return typeof val === 'string' ? val.trim() : '';
    }
  } catch {
    // ignore outside LuCI runtime
  }
  return '';
}

// An enabled section with fail_policy=block, which turns "auto" protections on.
function hasFailClosedSection(): boolean {
  try {
    const reader = uciReader();
    if (!reader || typeof reader.sections !== 'function') return false;
    return (reader.sections('tachyon', 'section') || []).some((s) => {
      const enabled = `${s.enabled ?? '1'}`.trim().toLowerCase();
      return (
        !['0', 'false', 'no', 'off'].includes(enabled) &&
        `${s.fail_policy ?? ''}`.trim().toLowerCase() === 'block'
      );
    });
  } catch {
    return false;
  }
}

function normalizeFlag(
  uciVal: string,
  sysVal: number | string | boolean | undefined,
  defaultValue: boolean,
): boolean {
  if (uciVal === '0' || uciVal === 'false') return false;
  if (uciVal === '1' || uciVal === 'true') return true;
  if (sysVal === 0 || sysVal === '0' || sysVal === false) return false;
  if (sysVal === 1 || sysVal === '1' || sysVal === true) return true;
  return defaultValue;
}

export function normalizeIpv6Mode(raw: unknown): IPv6Mode {
  const v = String(raw || '')
    .trim()
    .toLowerCase();
  if (
    v === 'off' ||
    v === 'ipv4_only' ||
    v === 'ipv4' ||
    v === '0' ||
    v === 'false'
  ) {
    return 'off';
  }
  if (v === 'dual_stack' || v === 'ipv4_ipv6' || v === 'on' || v === 'full') {
    return 'dual_stack';
  }
  if (v === 'tunnel_over_v4' || v === 'v6_over_v4') {
    return 'tunnel_over_v4';
  }
  return 'auto';
}

export function getIPv6ModeLabel(mode: string): string {
  switch (normalizeIpv6Mode(mode)) {
    case 'off':
      return tr(
        'Только IPv4 (без IPv6 на устройствах)',
        'IPv4 Only (no IPv6 on LAN devices)',
      );
    case 'dual_stack':
      return tr(
        'IPv4 + IPv6: Двойной стек (Dual-Stack)',
        'IPv4 + IPv6: Full Dual-Stack',
      );
    case 'tunnel_over_v4':
      return tr(
        'IPv4 + IPv6: Через IPv4-туннель',
        'IPv4 + IPv6: Over IPv4 Tunnel',
      );
    case 'auto':
    default:
      return tr(
        'IPv4 + IPv6: Авто (рекомендуется)',
        'IPv4 + IPv6: Auto (Recommended)',
      );
  }
}

export function getIPv6RuntimeSnapshot(
  sysInfo?: StoreType['diagnosticsSystemInfo'] | null,
): IPv6RuntimeSnapshot {
  const ipv6Mode = normalizeIpv6Mode(
    readUciSetting('ipv6_mode') || sysInfo?.ipv6_mode || 'auto',
  );
  const leakGuardActive = normalizeFlag(
    readUciSetting('ipv6_leak_guard'),
    sysInfo?.ipv6_leak_guard,
    true,
  );
  // "auto" (also the unset default) is on while a section is Fail-Closed.
  const webrtcRaw = readUciSetting('webrtc_leak_protect').toLowerCase();
  const webrtcGuardActive =
    webrtcRaw === '' || webrtcRaw === 'auto'
      ? hasFailClosedSection()
      : normalizeFlag(webrtcRaw, sysInfo?.webrtc_leak_protect, true);
  const fakeIpEnabled = normalizeFlag(
    readUciSetting('fakeip_enabled'),
    sysInfo?.fakeip_enabled,
    true,
  );
  const fakeIp4Range =
    readUciSetting('fakeip_inet4_range') ||
    sysInfo?.fakeip_inet4_range ||
    '198.18.0.0/15';
  const fakeIp6Range =
    readUciSetting('fakeip_inet6_range') ||
    sysInfo?.fakeip_inet6_range ||
    'fc00::/18';
  const dnsStrategy =
    readUciSetting('dns_strategy') || sysInfo?.dns_strategy || 'prefer_ipv4';
  const runtimeDnsStrategy = sysInfo?.runtime_dns_strategy || dnsStrategy;
  const pdFirst =
    Array.isArray(sysInfo?.wan6_pd) && sysInfo.wan6_pd.length > 0
      ? String(sysInfo.wan6_pd[0] || '')
      : '';
  const wan6Label = (
    sysInfo?.wan6_prefix ||
    pdFirst ||
    sysInfo?.wan_ipv6 ||
    ''
  ).trim();
  const hasWan6 =
    Boolean(wan6Label) ||
    sysInfo?.wan6_available === 1 ||
    sysInfo?.wan6_available === true;

  const rawEff = sysInfo?.ipv6_effective_state;
  let effectiveState: IPv6EffectiveState;
  if (
    rawEff === 'disabled' ||
    rawEff === 'leak_guard' ||
    rawEff === 'tunnel_over_v4' ||
    rawEff === 'full'
  ) {
    effectiveState = rawEff;
  } else if (ipv6Mode === 'off') {
    effectiveState = leakGuardActive ? 'leak_guard' : 'disabled';
  } else if (ipv6Mode === 'tunnel_over_v4') {
    effectiveState = 'tunnel_over_v4';
  } else if (ipv6Mode === 'dual_stack') {
    effectiveState = 'full';
  } else {
    effectiveState = hasWan6
      ? 'full'
      : leakGuardActive
        ? 'leak_guard'
        : 'disabled';
  }

  const configuredModeLabel = getIPv6ModeLabel(ipv6Mode);

  let modeLabel: string;
  if (effectiveState === 'full') {
    modeLabel =
      ipv6Mode === 'auto'
        ? tr('IPv4 + IPv6: Авто (Dual-Stack)', 'IPv4 + IPv6: Auto (Dual-Stack)')
        : getIPv6ModeLabel('dual_stack');
  } else if (effectiveState === 'tunnel_over_v4') {
    modeLabel = getIPv6ModeLabel('tunnel_over_v4');
  } else if (effectiveState === 'leak_guard') {
    modeLabel =
      ipv6Mode === 'auto'
        ? tr(
            'IPv4 + IPv6: Авто (IPv4 + Leak Guard)',
            'IPv4 + IPv6: Auto (IPv4 + Leak Guard)',
          )
        : getIPv6ModeLabel('off');
  } else {
    modeLabel = getIPv6ModeLabel('off');
  }

  let warningText = '';
  if (dnsStrategy === 'ipv6_only' && runtimeDnsStrategy === 'ipv4_only') {
    warningText = tr(
      'Выбрана стратегия ipv6_only, но активного IPv6-транспорта нет — ядро переключило DNS в режим ipv4_only.',
      'DNS strategy is ipv6_only without an active IPv6 transport — runtime fell back to ipv4_only.',
    );
  } else if (
    dnsStrategy === 'ipv6_only' &&
    effectiveState !== 'full' &&
    effectiveState !== 'tunnel_over_v4'
  ) {
    warningText = tr(
      'Выбрана стратегия ipv6_only, но активного IPv6-транспорта нет: домены без AAAA/IPv6-связности не будут открываться.',
      'DNS strategy is ipv6_only without an active IPv6 transport: IPv4-only domains will fail to resolve.',
    );
  } else if (dnsStrategy === 'ipv6_only') {
    warningText = tr(
      'Включена строгая стратегия ipv6_only — ресурсы без AAAA-записей не будут резолвиться.',
      'Strict ipv6_only DNS strategy is enabled — domains without AAAA records will not resolve.',
    );
  } else if (effectiveState === 'disabled' && !leakGuardActive) {
    warningText = tr(
      'Защита от утечек IPv6 (Leak Guard) отключена — рекомендуется включить её для строгой изоляции маршрута.',
      'IPv6 Leak Guard is disabled — enabling leak protection is recommended for strict route isolation.',
    );
  }

  return {
    ipv6Mode,
    effectiveState,
    modeLabel,
    configuredModeLabel,
    leakGuardActive,
    webrtcGuardActive,
    fakeIpEnabled,
    fakeIp4Range,
    fakeIp6Range,
    dnsStrategy,
    wan6Label,
    hasWan6,
    warningText,
    isWarning: Boolean(warningText),
  };
}
