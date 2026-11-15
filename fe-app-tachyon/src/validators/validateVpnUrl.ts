import { ValidationResult } from './types';
import { store } from '../tachyon/services/store.service';

export function supportsVpnUrl() {
  const state = store.get();
  const info = state.diagnosticsSystemInfo || {};
  const engine = state.activeEngine || info.active_engine || 'tachyon-core';
  return (
    (engine === 'tachyon-core' || engine === 'sing-box') &&
    (Number(info.sing_box_lx) === 1 ||
      Number(info.sing_box_tachyon_core) === 1 ||
      /-lx(?:[.-]|$)/.test(String(info.sing_box_version || '')) ||
      /-tachyon(?:[.-]|$)/.test(String(info.sing_box_version || '')))
  );
}
export function validateVpnUrl(url: string): ValidationResult {
  const invalid = () => ({
    valid: false,
    message: _('Invalid vpn:// link; use a WG/AWG .conf or Amnezia export'),
  });
  const key32 = (value: unknown) => {
    try {
      let key = String(value || '')
        .trim()
        .replace(/ /g, '+')
        .replace(/-/g, '+')
        .replace(/_/g, '/');
      if (key.length === 43 && /^[A-Za-z0-9+/]{43}$/.test(key)) key += '=';
      return /^[A-Za-z0-9+/]{43}=$/.test(key) && atob(key).length === 32;
    } catch (_e) {
      return false;
    }
  };
  try {
    if (url.startsWith('vpn://')) {
      let payload = decodeURIComponent(url.slice(6).split('#')[0]).replace(
        /[\r\n\t ]+/g,
        '',
      );
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
      if (
        text.length >= 8 &&
        !text.trim().startsWith('{') &&
        !text.trim().startsWith('[') &&
        !text.trim().startsWith('#')
      ) {
        const cmf = text.charCodeAt(0),
          flg = text.charCodeAt(1);
        if (
          (cmf & 15) === 8 &&
          cmf >> 4 <= 7 &&
          !(flg & 32) &&
          (cmf * 256 + flg) % 31 === 0
        ) {
          return {
            valid: true,
            message: _('Amnezia export; full validation before apply'),
          };
        }
      }
      if (text.length > 65536 || text.includes('\0')) return invalid();
      if (text.trim().startsWith('{')) {
        const data = JSON.parse(text);
        if (!Array.isArray(data.containers)) {
          if (
            typeof data.config === 'string' &&
            data.config.toLowerCase().includes('[interface]')
          ) {
            text = data.config;
          } else if (
            (data.client_priv_key || data.private_key) &&
            (data.server_pub_key || data.public_key)
          ) {
            return { valid: true, message: _('Valid') };
          } else {
            return invalid();
          }
        } else {
          if (!data.containers.length || data.containers.length > 16)
            return invalid();
          const choices: { kind: string; text: string }[] = [];
          for (const container of data.containers) {
            if (!container || typeof container !== 'object') return invalid();
            const kind = container.container;
            const proto = [
              'amnezia-awg',
              'amnezia-awg2',
              'amnezia-awg-v2',
              'amnezia-awg1.5',
              'awg',
            ].includes(kind)
              ? 'awg'
              : ['amnezia-wireguard', 'wireguard', 'wg'].includes(kind)
                ? 'wireguard'
                : null;
            if (!proto) continue;
            let settings =
              container[proto] ||
              container.awg ||
              container.awg2 ||
              container[kind] ||
              container.params;
            if (typeof settings === 'string') settings = JSON.parse(settings);
            let last = settings?.last_config ?? settings?.config;
            if (
              typeof last === 'string' &&
              !last.trim().startsWith('{') &&
              last.toLowerCase().includes('[interface]')
            ) {
              choices.push({ kind, text: last });
              continue;
            }
            if (typeof last === 'string') {
              try {
                last = JSON.parse(last);
              } catch {
                last = null;
              }
            }
            if (!last || typeof last !== 'object') last = settings;
            if (last && typeof last.config === 'string' && last.config) {
              choices.push({ kind, text: last.config });
            } else if (
              last &&
              (last.client_priv_key || last.private_key) &&
              (last.server_pub_key || last.public_key)
            ) {
              return { valid: true, message: _('Valid') };
            }
          }
          const supportedKinds = [
            'amnezia-awg',
            'amnezia-awg2',
            'amnezia-awg-v2',
            'amnezia-awg1.5',
            'awg',
            'amnezia-wireguard',
            'wireguard',
            'wg',
          ];
          if (
            data.defaultContainer &&
            !supportedKinds.includes(String(data.defaultContainer))
          )
            return invalid();
          const preferred = choices.filter(
            (c) => c.kind === data.defaultContainer,
          );
          if (
            preferred.length > 1 ||
            (!preferred.length && choices.length !== 1)
          )
            return invalid();
          text = (preferred[0] || choices[0]).text;
          if (text.length > 65536 || text.includes('\0')) return invalid();
        }
      }
      let block = '',
        peers = 0,
        interfaces = 0;
      const fields: Record<string, string> = {};
      for (const raw of text.split('\n')) {
        const line = raw.trim();
        if (!line || line.startsWith('#')) continue;
        const lowerLine = line.toLowerCase();
        if (lowerLine === '[interface]') {
          block = 'interface';
          interfaces++;
          continue;
        }
        if (lowerLine === '[peer]') {
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
      const privKey =
        fields.privatekey || fields.private_key || fields.client_priv_key;
      const pubKey =
        fields.publickey ||
        fields.public_key ||
        fields.peer_public_key ||
        fields.server_pub_key;
      const addrVal =
        fields.address || fields.local_address || fields.ip || fields.client_ip;
      const pskVal =
        fields.presharedkey ||
        fields.preshared_key ||
        fields.psk ||
        fields.psk_key;
      const endpoint = (fields.endpoint || '').match(
        /^(\[[^\]]+\]|[^:\s]+):(\d+)$/,
      );
      if (
        interfaces !== 1 ||
        peers !== 1 ||
        !key32(privKey) ||
        !key32(pubKey) ||
        !addrVal ||
        !endpoint ||
        Number(endpoint[2]) < 1 ||
        Number(endpoint[2]) > 65535 ||
        (pskVal && !key32(pskVal))
      )
        return invalid();
    }
    // The backend validates AWG fields and core compatibility before apply.
    return { valid: true, message: _('Valid') };
  } catch (_e) {
    return invalid();
  }
}
