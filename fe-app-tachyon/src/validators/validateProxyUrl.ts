import { ValidationResult } from './types';
import { supportsVpnUrl, validateVpnUrl } from './validateVpnUrl';
import { validateShadowsocksUrl } from './validateShadowsocksUrl';
import { validateVlessUrl } from './validateVlessUrl';
import { validateVmessUrl } from './validateVmessUrl';
import { validateTrojanUrl } from './validateTrojanUrl';
import { validateSocksUrl } from './validateSocksUrl';
import { validateHysteria2Url } from './validateHysteriaUrl';
import { validateTuicUrl } from './validateTuicUrl';
import { validateHttpProxyUrl } from './validateHttpProxyUrl';
import { validateFptnUrl } from './validateFptnUrl';
import { isValidPort, parseHostPort } from './hostPort';

function validateExtendedShareLink(url: string): ValidationResult {
  if (!url || /\s/.test(url)) {
    return {
      valid: false,
      message: _('Invalid proxy URL: must not contain spaces'),
    };
  }
  const schemeIdx = url.indexOf('://');
  if (schemeIdx <= 0) {
    return { valid: false, message: _('Invalid proxy URL') };
  }
  const scheme = url.slice(0, schemeIdx).toLowerCase();
  const body = url.slice(schemeIdx + 3);
  const [mainPart] = body.split('#');
  const [authorityPart, queryPart = ''] = mainPart.split('?');

  if (scheme === 'tg') {
    const params = new URLSearchParams(queryPart);
    const server = (params.get('server') || '').trim();
    const port = Number(params.get('port') || '0');
    const secret = (params.get('secret') || '').trim();
    if (!server || !isValidPort(port) || !secret) {
      return {
        valid: false,
        message: _(
          'Invalid Telegram proxy URL: missing server, port, or secret',
        ),
      };
    }
    return { valid: true, message: _('Valid') };
  }

  if (scheme === 'csqtt' || scheme === 'wdtt' || scheme === 'qwdtt') {
    const cleanMain = mainPart.trim();
    if (!cleanMain) {
      return {
        valid: false,
        message: _('Invalid CSQTT / WDTT URL: empty body'),
      };
    }
    if (scheme === 'qwdtt') {
      const q = queryPart || cleanMain;
      const hasHost = /(?:^|&)(?:ip|server|host)=[^&]+/i.test(q);
      const hasPass = /(?:^|&)(?:pass|password)=.+$/i.test(q);
      if (!hasHost || !hasPass) {
        return {
          valid: false,
          message: _('Invalid QWDTT URL: missing ip/host or password'),
        };
      }
      return { valid: true, message: _('Valid') };
    }
    if (scheme === 'csqtt' && /^connect\?/i.test(cleanMain)) {
      const params = new URLSearchParams(queryPart);
      const hasHost = Boolean(
        params.get('host') ||
          params.get('server') ||
          params.get('ip') ||
          params.get('addr') ||
          (params.get('peer') &&
            /^(?:\[[^\]]+\]|[^:]+):\d+$/.test(params.get('peer') || '')),
      );
      const hasCred = Boolean(
        params.get('password') ||
          params.get('pass') ||
          params.get('p') ||
          params.get('hash') ||
          params.get('hashes') ||
          params.get('h') ||
          params.get('k') ||
          params.get('key') ||
          params.get('id'),
      );
      if (!hasHost || !hasCred) {
        return {
          valid: false,
          message: _('Invalid CSQTT URL: missing host/addr or credentials'),
        };
      }
      return { valid: true, message: _('Valid') };
    }
    if (
      !cleanMain.includes(':') &&
      !cleanMain.includes('?') &&
      !cleanMain.includes('@')
    ) {
      const b64Candidate = cleanMain.replace(/\/+$/, '');
      if (scheme === 'csqtt' && /^[A-Za-z0-9_-]{28,}$/.test(b64Candidate)) {
        return { valid: true, message: _('Valid') };
      }
      try {
        const rawB64 = b64Candidate.replace(/-/g, '+').replace(/_/g, '/');
        const pad = rawB64.length % 4;
        const b64 = pad ? rawB64 + '='.repeat(4 - pad) : rawB64;
        const jsonStr = atob(b64);
        const obj = JSON.parse(jsonStr);
        if (
          obj &&
          typeof obj === 'object' &&
          (obj.ip || obj.add || obj.server) &&
          (obj.pass || obj.id || obj.password)
        ) {
          return { valid: true, message: _('Valid') };
        }
      } catch {
        return {
          valid: false,
          message: _('Invalid CSQTT / WDTT URL payload'),
        };
      }
    }
    if (!queryPart && !cleanMain.includes('@') && cleanMain.includes(':')) {
      const colonSource = cleanMain.startsWith('[')
        ? cleanMain.replace(/^\[[^\]]+\]:/, '')
        : cleanMain.slice(cleanMain.indexOf(':') + 1);
      const parts = colonSource.split(':');
      if (parts.length >= 5) {
        const dtls = Number(parts[0]);
        if (isValidPort(dtls) && parts[3]) {
          return { valid: true, message: _('Valid') };
        }
      }
    }
    const csqttAt = authorityPart.lastIndexOf('@');
    const csqttUser = csqttAt >= 0 ? authorityPart.slice(0, csqttAt) : '';
    const csqttHostPort =
      csqttAt >= 0 ? authorityPart.slice(csqttAt + 1) : authorityPart;
    const params = new URLSearchParams(queryPart);
    const hasPass = Boolean(
      csqttUser ||
        params.get('pass') ||
        params.get('password') ||
        params.get('id'),
    );
    const defaultPort = scheme === 'csqtt' ? '46000' : '56000';
    const effective =
      !csqttHostPort.includes(':') ||
      (csqttHostPort.startsWith('[') && csqttHostPort.endsWith(']'))
        ? `${csqttHostPort}:${defaultPort}`
        : csqttHostPort;
    const parsed = parseHostPort(effective);
    if (!parsed || !parsed.host || !isValidPort(parsed.port) || !hasPass) {
      return {
        valid: false,
        message: _('Invalid CSQTT / WDTT URL: invalid host, port, or password'),
      };
    }
    return { valid: true, message: _('Valid') };
  }

  const atIdx = authorityPart.lastIndexOf('@');
  const userPart = atIdx >= 0 ? authorityPart.slice(0, atIdx) : '';
  const hostPortPart =
    atIdx >= 0 ? authorityPart.slice(atIdx + 1) : authorityPart;

  if (
    [
      'anytls',
      'shadowtls',
      'snell',
      'tewfai',
      'mieru',
      'mierus',
      'mtproto',
    ].includes(scheme) &&
    !userPart
  ) {
    return {
      valid: false,
      message: _('Invalid proxy URL: missing credentials'),
    };
  }

  if (scheme === 'mieru' || scheme === 'mierus') {
    const params = new URLSearchParams(queryPart);
    const qPort = params.get('port');
    if (qPort && !hostPortPart.includes(':')) {
      const portNum = Number(qPort);
      if (!hostPortPart || !isValidPort(portNum)) {
        return {
          valid: false,
          message: _('Invalid Mieru URL: invalid host or port'),
        };
      }
      return { valid: true, message: _('Valid') };
    }
  }

  const defaultPortSchemes = [
    'masque',
    'openconnect',
    'anyconnect',
    'naive+https',
    'naive+quic',
  ];
  const effectiveHostPort =
    !hostPortPart.includes(':') && defaultPortSchemes.includes(scheme)
      ? `${hostPortPart}:443`
      : hostPortPart;

  const parsed = parseHostPort(effectiveHostPort);
  if (!parsed || !parsed.host || !parsed.port || !isValidPort(parsed.port)) {
    return {
      valid: false,
      message: _('Invalid proxy URL: invalid host or port'),
    };
  }
  return { valid: true, message: _('Valid') };
}

/**
 * Scheme dispatch, longest prefix first so that a longer scheme can never be
 * swallowed by a shorter one. Adding a protocol is one row.
 */
const DISPATCH: {
  prefixes: string[];
  validate: (url: string) => ValidationResult;
}[] = [
  {
    prefixes: ['fptnb://', 'fptn://', 'fptnb:', 'fptn:'],
    validate: validateFptnUrl,
  },
  { prefixes: ['ss://'], validate: validateShadowsocksUrl },
  { prefixes: ['vless://'], validate: validateVlessUrl },
  { prefixes: ['vmess://'], validate: validateVmessUrl },
  { prefixes: ['trojan://'], validate: validateTrojanUrl },
  {
    prefixes: ['socks4://', 'socks4a://', 'socks5://'],
    validate: validateSocksUrl,
  },
  { prefixes: ['http://', 'https://'], validate: validateHttpProxyUrl },
  { prefixes: ['hysteria2://', 'hy2://'], validate: validateHysteria2Url },
  { prefixes: ['tuic://'], validate: validateTuicUrl },
  {
    prefixes: [
      'anytls://',
      'shadowtls://',
      'naive+https://',
      'naive+quic://',
      'snell://',
      'mierus://',
      'mieru://',
      'mtproto://',
      'tg://',
      'tewfai://',
      'trusttunnel://',
      'masque://',
      'openconnect://',
      'anyconnect://',
      'csqtt://',
      'wdtt://',
      'qwdtt://',
      'amneziawg://',
      'awg://',
    ],
    validate: validateExtendedShareLink,
  },
];

/**
 * Routes a pasted share link to its scheme validator.
 *
 * Input is untrusted. The scheme match is case-sensitive on purpose: share
 * links are generated in lower case, and accepting "SS://" would let a
 * lookalike through a filter that only lowercases one side. No prefix here
 * overlaps another, so ordering only matters for readability.
 */
export function validateProxyUrl(url: string): ValidationResult {
  const trimmedUrl = url.trim();
  if (trimmedUrl.startsWith('vpn://')) {
    if (!supportsVpnUrl())
      return {
        valid: false,
        message: _('vpn:// is available only with Tachyon Core or sing-box LX'),
      };
    return validateVpnUrl(trimmedUrl);
  }

  for (const { prefixes, validate } of DISPATCH) {
    for (const prefix of prefixes) {
      if (trimmedUrl.startsWith(prefix)) {
        return validate(trimmedUrl);
      }
    }
  }

  return {
    valid: false,
    message:
      _(
        'URL must start with vless://, vmess://, ss://, trojan://, socks4://, socks4a://, socks5://, http://, https://, hysteria2://, hy2://, tuic://, fptn://, or fptn:',
      ) + (supportsVpnUrl() ? '; vpn:// (Tachyon Core / LX)' : ''),
  };
}
