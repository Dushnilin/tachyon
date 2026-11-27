import { validateDomain } from './validateDomain';
import { isValidPort, parseHostPort, unbracketHost } from './hostPort';
import { validateIP } from './validateIp';
import { ValidationResult } from './types';

const ALLOWED_DNS_SCHEMES = /^(https|tls|quic|h3|tcp|udp)$/i;

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
