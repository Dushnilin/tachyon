import { tr } from './i18n';
import { store } from '../services/store.service';
import type { Tachyon } from '../types';

export interface PlatformBadgeInfo {
  label: string;
  tooltip: string;
  warning: string | null;
}

export const OPENWRT_ONLY_FIX_CODES = new Set([
  'disable_flow_offloading',
  'sync_flow_offload_guard',
]);

export function getPlatformInfo(
  explicit?: Tachyon.PlatformInfo | null,
): Tachyon.PlatformInfo | null {
  if (explicit) return explicit;
  const st = store.get();
  return (
    st.servicesInfoWidget?.data?.platformInfo ||
    st.diagnosticsSystemInfo?.platform_info ||
    null
  );
}

export function isEntwarePlatform(
  explicit?: Tachyon.PlatformInfo | null,
): boolean {
  return Boolean(getPlatformInfo(explicit)?.is_entware);
}

export function isOpenWrtOnlyFixCode(
  code: string,
  platformInfo?: Tachyon.PlatformInfo | null,
): boolean {
  if (!isEntwarePlatform(platformInfo)) return false;
  return OPENWRT_ONLY_FIX_CODES.has(String(code || '').trim());
}

export function isOpenWrtOnlyNotice(
  text: string,
  platformInfo?: Tachyon.PlatformInfo | null,
): boolean {
  if (!isEntwarePlatform(platformInfo)) return false;
  const lower = String(text || '').toLowerCase();
  return (
    lower.includes('fw4') ||
    lower.includes('flow offload') ||
    lower.includes('odhcpd') ||
    lower.includes('luci launcher') ||
    lower.includes('openwrt luci')
  );
}

export function formatPlatformBadge(
  info: Tachyon.PlatformInfo,
): PlatformBadgeInfo {
  const parts: string[] = [];
  const baseName = info.is_keenetic
    ? 'Keenetic Entware'
    : (info.display_name || '').trim() ||
      (info.is_entware ? 'Entware' : 'OpenWrt');
  parts.push(baseName);

  const fsType = String(info.storage_fs || '').trim();
  if (info.storage_kind === 'usb_external') {
    parts.push(fsType ? `USB ${fsType}` : 'USB');
  } else if (fsType && info.is_entware) {
    parts.push(fsType);
  }

  const fw = String(info.firewall || '').trim();
  if (fw) {
    parts.push(fw);
  }

  const warnings: string[] = [];
  if (info.storage_posix === false) {
    warnings.push(
      tr(
        'ФС хранилища не поддерживает POSIX-права (требуется ext2/ext3/ext4)',
        'Storage filesystem is not POSIX-compliant (ext2/ext3/ext4 required)',
      ),
    );
  }
  if (info.runtime_tmpfs_ok === false) {
    warnings.push(
      tr(
        'Временные файлы размещены не в RAM tmpfs — возможен повышенный износ USB/флеш',
        'Runtime state is not on RAM tmpfs — increased USB/flash wear possible',
      ),
    );
  }

  const tooltipLines: string[] = [
    `${tr('Платформа', 'Platform')}: ${info.display_name || info.platform}`,
    `${tr('Фаервол', 'Firewall')}: ${fw || 'unknown'}`,
  ];
  if (info.storage_mount || fsType) {
    tooltipLines.push(
      `${tr('Хранилище', 'Storage')}: ${info.storage_mount || '/opt'} (${fsType || info.storage_kind || 'unknown'})`,
    );
  }
  if (info.entware_dns_mode) {
    const portSuffix =
      info.entware_dns_port && info.entware_dns_mode === 'redirect'
        ? ` :${info.entware_dns_port}`
        : '';
    tooltipLines.push(
      `${tr('Режим DNS', 'DNS Mode')}: ${info.entware_dns_mode}${portSuffix}`,
    );
  }
  if (warnings.length > 0) {
    tooltipLines.push(...warnings);
  }

  return {
    label: parts.join(' · '),
    tooltip: tooltipLines.join('\n'),
    warning: warnings.length > 0 ? warnings.join('; ') : null,
  };
}

export function validateEntwareDnsPort(value: unknown): true | string {
  const raw = String(value ?? '').trim();
  if (!raw) {
    return tr('Укажите порт от 1 до 65535', 'Enter a port between 1 and 65535');
  }
  if (!/^\d+$/.test(raw)) {
    return tr(
      'Порт должен быть целым числом от 1 до 65535',
      'Port must be an integer between 1 and 65535',
    );
  }
  const num = Number(raw);
  if (!Number.isInteger(num) || num < 1 || num > 65535) {
    return tr(
      'Порт должен быть в диапазоне 1..65535',
      'Port must be in range 1..65535',
    );
  }
  return true;
}
