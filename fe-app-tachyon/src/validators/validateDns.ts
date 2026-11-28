import { validateDomain } from './validateDomain';
import { isValidPort, parseHostPort, unbracketHost } from './hostPort';
import { validateIP } from './validateIp';
import { ValidationResult } from './types';

const ALLOWED_DNS_SCHEMES = /^(https|tls|quic|h3|tcp|udp|tdns)$/i;

export function validateDNS(value: string): ValidationResult {
  const trimmed = String(value || '').trim();
  if (!trimmed) {
    return { valid: false, message: _('DNS server address cannot be empty') };
  }

  let target = trimmed;
  const schemeMatch = /^([a-z][a-z0-9+.-]*):\/\//i.exec(trimmed);
  if (schemeMatch) {
    if (!ALLOWED_DNS_SCHEMES.test(schemeMatch[1])) {
      return {
        valid: false,
        message: _(
          'Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH',
        ),
      };
    }
    target = trimmed.slice(schemeMatch[0].length);
    if (!target || target.startsWith('/') || target.includes('://')) {
      return {
        valid: false,
        message: _(
          'Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH',
        ),
      };
    }
    if (schemeMatch[1].toLowerCase() === 'tdns') {
      const withoutFrag = target.split('#')[0];
      const [beforeQuery] = withoutFrag.split('?');
      const atIdx = beforeQuery.indexOf('@');
      if (atIdx < 0) {
        return {
          valid: false,
          message: _(
            'Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH',
          ),
        };
      }
      const userinfo = beforeQuery.slice(0, atIdx);
      const rest = beforeQuery.slice(atIdx + 1);
      const creds = userinfo.split(':');
      if (
        creds.length !== 2 ||
        !/^[0-9a-f]{16}$/i.test(creds[0]) ||
        !/^[A-Za-z0-9_-]{43}$/.test(creds[1]) ||
        !rest ||
        rest.startsWith('/')
      ) {
        return {
          valid: false,
          message: _(
            'Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH',
          ),
        };
      }
      target = rest;
    }
  }

  const [addressPart, ...pathParts] = target.split('/');
  const parsedHostPort = parseHostPort(addressPart);
  const host = parsedHostPort
    ? parsedHostPort.host
    : unbracketHost(addressPart);
  const domainValue = parsedHostPort
    ? host + (pathParts.length > 0 ? `/${pathParts.join('/')}` : '')
    : target.replace(/:(\d+)(?=\/|$)/, '');

  if (parsedHostPort && !isValidPort(parsedHostPort.port)) {
    return { valid: false, message: _('Invalid DNS server port') };
  }

  if (validateIP(host).valid) {
    return { valid: true, message: _('Valid') };
  }

  if (validateDomain(domainValue).valid) {
    return { valid: true, message: _('Valid') };
  }

  return {
    valid: false,
    message: _(
      'Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH',
    ),
  };
}
