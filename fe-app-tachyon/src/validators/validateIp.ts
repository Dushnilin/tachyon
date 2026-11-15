import { ValidationResult } from './types';

export function isIPv4(ip: string): boolean {
  const ipRegex =
    /^(?:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$/;

  return ipRegex.test(ip);
}

export function isIPv6(ip: string): boolean {
  if (!ip.includes(':') || ip.includes('%')) {
    return false;
  }

  try {
    new URL(`http://[${ip}]/`);
    return true;
  } catch (_e) {
    return false;
  }
}

export function isIPv6WithZone(ip: string): boolean {
  const pctIdx = ip.indexOf('%');
  if (pctIdx < 0) {
    return isIPv6(ip);
  }
  const addr = ip.slice(0, pctIdx);
  const zone = ip.slice(pctIdx + 1);
  if (!zone || !/^[A-Za-z0-9._-]+$/.test(zone)) {
    return false;
  }
  return isIPv6(addr);
}

export function validateIPWithZone(ip: string): ValidationResult {
  if (isIPv4(ip) || isIPv6WithZone(ip)) {
    return { valid: true, message: _('Valid') };
  }

  return { valid: false, message: _('Invalid IP address format') };
}

export function validateIP(ip: string): ValidationResult {
  if (isIPv4(ip) || isIPv6(ip)) {
    return { valid: true, message: _('Valid') };
  }

  return { valid: false, message: _('Invalid IP address') };
}
