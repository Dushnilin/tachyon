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
