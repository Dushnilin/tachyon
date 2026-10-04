import { ValidationResult } from './types';
import { store } from '../tachyon/services/store.service';

export function supportsVpnUrl() {
  const state = store.get();
  const info = state.diagnosticsSystemInfo || {};
  const engine = state.activeEngine || info.active_engine || 'sing-box';
  return (
    engine === 'sing-box' &&
    (Number(info.sing_box_lx) === 1 ||
      /-lx(?:[.-]|$)/.test(String(info.sing_box_version || '')))
  );
}
export function validateVpnUrl(url: string): ValidationResult {
  const invalid = () => ({
    valid: false,
    message: _('Invalid vpn:// link; use a WG/AWG .conf or Amnezia export'),
  });
  const key32 = (value: unknown) => {
    try {
      const key = String(value || '').replace(/ /g, '+');
      return /^[A-Za-z0-9+/]{43}=$/.test(key) && atob(key).length === 32;
    } catch (_e) {
      return false;
    }
  };
  try {
    if (url.startsWith('vpn://')) {
      let payload = decodeURIComponent(url.slice(6).split('#')[0]);
      if (
        payload.length > 131072 ||
        !/^[A-Za-z0-9+/_-]*={0,2}$/.test(payload) ||
        payload.length % 4 === 1
      )
        return invalid();
      payload = payload.replace(/-/g, '+').replace(/_/g, '/');
      while (payload.length % 4) payload += '=';
      let text = atob(payload);
      // Qt qCompress: 4-byte big-endian output size, then a zlib stream.
      // CBI validation is synchronous. Check the envelope here; the backend
      // checks deflate, exact size, Adler-32, container and all WG/AWG fields.
      if (text.length >= 12 && text.charCodeAt(0) === 0) {
        const size =
          text.charCodeAt(0) * 16777216 +
          text.charCodeAt(1) * 65536 +
          text.charCodeAt(2) * 256 +
          text.charCodeAt(3);
        const cmf = text.charCodeAt(4),
          flg = text.charCodeAt(5);
        if (
          !size ||
          size > 65536 ||
          (cmf & 15) !== 8 ||
          cmf >> 4 > 7 ||
          flg & 32 ||
          (cmf * 256 + flg) % 31
        )
          return invalid();
        return {
          valid: true,
          message: _('Amnezia export; full validation before apply'),
        };
      }
      if (text.length > 65536 || text.includes('\0')) return invalid();
      if (text.trim().startsWith('{')) {
        const data = JSON.parse(text);
        if (
          !Array.isArray(data.containers) ||
          !data.containers.length ||
          data.containers.length > 16
        )
          return invalid();
        const choices: { kind: string; text: string }[] = [];
        for (const container of data.containers) {
          if (!container || typeof container !== 'object') return invalid();
          const kind = container.container;
          const proto = ['amnezia-awg', 'amnezia-awg2'].includes(kind)
            ? 'awg'
            : kind === 'amnezia-wireguard'
              ? 'wireguard'
              : null;
          if (!proto) continue;
          let settings = container[proto];
          if (typeof settings === 'string') settings = JSON.parse(settings);
          let last = settings?.last_config;
          if (typeof last === 'string') last = JSON.parse(last);
          if (!last || typeof last.config !== 'string') return invalid();
          choices.push({ kind, text: last.config });
        }
        const preferred = choices.filter(
          (c) => c.kind === data.defaultContainer,
        );
        if (
          !preferred.length &&
          typeof data.defaultContainer === 'string' &&
          data.defaultContainer
        )
          return invalid();
        if (preferred.length > 1 || (!preferred.length && choices.length !== 1))
          return invalid();
        text = (preferred[0] || choices[0]).text;
        if (text.length > 65536 || text.includes('\0')) return invalid();
      }
      let block = '',
        peers = 0,
        interfaces = 0;
      const fields: Record<string, string> = {};
      for (const raw of text.split('\n')) {
        const line = raw.trim();
        if (!line || line.startsWith('#')) continue;
        if (line === '[Interface]') {
          block = 'interface';
          interfaces++;
          continue;
        }
        if (line === '[Peer]') {
          block = 'peer';
          peers++;
          continue;
        }
        if (line.startsWith('[')) return invalid();
        const eq = line.indexOf('=');
        if (block && eq > 0)
          fields[line.slice(0, eq).trim().toLowerCase()] = line
            .slice(eq + 1)
            .trim();
      }
      const endpoint = (fields.endpoint || '').match(
        /^(\[[^\]]+\]|[^:\s]+):(\d+)$/,
      );
      if (
        interfaces !== 1 ||
        peers !== 1 ||
        !key32(fields.privatekey) ||
        !key32(fields.publickey) ||
        !fields.address ||
        !endpoint ||
        Number(endpoint[2]) < 1 ||
        Number(endpoint[2]) > 65535 ||
        (fields.presharedkey && !key32(fields.presharedkey))
      )
        return invalid();
    }
    // The backend validates AWG fields and core compatibility before apply.
    return { valid: true, message: _('Valid') };
  } catch (_e) {
    return invalid();
  }
}
