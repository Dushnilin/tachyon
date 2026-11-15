import { ValidationResult } from './types';
import { isIPv4, isIPv6 } from './validateIp';

export type CidrRange = {
  family: 4 | 6;
  start: bigint;
  end: bigint;
};

function ipv4ToBigInt(ip: string): bigint | null {
  if (!isIPv4(ip)) {
    return null;
  }
  const octets = ip.split('.').map(Number);
  return (
    (BigInt(octets[0]) << 24n) |
    (BigInt(octets[1]) << 16n) |
    (BigInt(octets[2]) << 8n) |
    BigInt(octets[3])
  );
}

function ipv6ToBigInt(ip: string): bigint | null {
  if (!isIPv6(ip)) {
    return null;
  }
  let normalized = ip.toLowerCase();
  const lastColon = normalized.lastIndexOf(':');
  if (normalized.includes('.') && lastColon >= 0) {
    const v4 = ipv4ToBigInt(normalized.slice(lastColon + 1));
    if (v4 === null) {
      return null;
    }
    const hi = Number((v4 >> 16n) & 0xffffn).toString(16);
    const lo = Number(v4 & 0xffffn).toString(16);
    normalized = `${normalized.slice(0, lastColon)}:${hi}:${lo}`;
  }

  const halves = normalized.split('::');
  if (halves.length > 2) {
    return null;
  }
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const missing = halves.length === 2 ? 8 - (head.length + tail.length) : 0;
  if (missing < 0 || (halves.length === 1 && head.length !== 8)) {
    return null;
  }
  const groups = [...head, ...new Array<string>(missing).fill('0'), ...tail];
  if (groups.length !== 8) {
    return null;
  }
  let result = 0n;
  for (const grp of groups) {
    const val = parseInt(grp, 16);
    if (!Number.isInteger(val) || val < 0 || val > 0xffff) {
      return null;
    }
    result = (result << 16n) | BigInt(val);
  }
  return result;
}

export function parseCidrRange(value: string): CidrRange | null {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  const slashIdx = trimmed.indexOf('/');
  if (slashIdx <= 0) {
    return null;
  }
  const ip = trimmed.slice(0, slashIdx);
  const prefixStr = trimmed.slice(slashIdx + 1);
  if (!/^\d+$/.test(prefixStr)) {
    return null;
  }
  const prefix = parseInt(prefixStr, 10);

  const v4 = ipv4ToBigInt(ip);
  if (v4 !== null) {
    if (prefix < 0 || prefix > 32) {
      return null;
    }
    const allOnes = 0xffffffffn;
    const hostBits = BigInt(32 - prefix);
    const mask = prefix === 0 ? 0n : (allOnes << hostBits) & allOnes;
    const start = v4 & mask;
    const end = start | (allOnes ^ mask);
    return { family: 4, start, end };
  }

  const v6 = ipv6ToBigInt(ip);
  if (v6 !== null) {
    if (prefix < 0 || prefix > 128) {
      return null;
    }
    const allOnes = (1n << 128n) - 1n;
    const hostBits = BigInt(128 - prefix);
    const mask = prefix === 0 ? 0n : (allOnes << hostBits) & allOnes;
    const start = v6 & mask;
    const end = start | (allOnes ^ mask);
    return { family: 6, start, end };
  }

  return null;
}

export function cidrsOverlap(cidrA: string, cidrB: string): boolean {
  const a = parseCidrRange(cidrA);
  const b = parseCidrRange(cidrB);
  if (!a || !b || a.family !== b.family) {
    return false;
  }
  return a.start <= b.end && b.start <= a.end;
}

export function validateCidr(value: string, family?: 4 | 6): ValidationResult {
  const parsed = parseCidrRange(value);
  if (!parsed) {
    return {
      valid: false,
      message:
        family === 6
          ? _('Invalid IPv6 CIDR format (expected prefix, e.g. fc00::/18)')
          : family === 4
            ? _(
                'Invalid IPv4 CIDR format (expected prefix, e.g. 198.18.0.0/15)',
              )
            : _('Invalid CIDR format (expected IP/prefix)'),
    };
  }
  if (family && parsed.family !== family) {
    return {
      valid: false,
      message:
        family === 6
          ? _('Expected an IPv6 CIDR (e.g. fc00::/18)')
          : _('Expected an IPv4 CIDR (e.g. 198.18.0.0/15)'),
    };
  }
  return { valid: true, message: _('Valid') };
}

export function validateSubnet(value: string): ValidationResult {
  const trimmed = value.trim();

  if (/^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/.test(trimmed)) {
    return { valid: true, message: _('Valid') };
  }

  const [ip, cidr, extra] = trimmed.split('/');

  if (!ip || extra !== undefined || (!isIPv4(ip) && !isIPv6(ip))) {
    return {
      valid: false,
      message: _('Invalid format. Use an IP address or CIDR subnet'),
    };
  }

  if ((ip === '0.0.0.0' || ip === '::') && cidr == null) {
    return {
      valid: false,
      message: _('Unspecified IP address is not allowed'),
    };
  }

  if (cidr !== undefined) {
    if (!/^\d+$/.test(cidr)) {
      return {
        valid: false,
        message: _('Invalid CIDR prefix'),
      };
    }

    const cidrNum = parseInt(cidr, 10);
    const maxPrefix = isIPv6(ip) ? 128 : 32;

    if (cidrNum < 0 || cidrNum > maxPrefix) {
      return {
        valid: false,
        message: _(
          'CIDR must be between 0 and 32 for IPv4 or 0 and 128 for IPv6',
        ),
      };
    }
  }

  return { valid: true, message: _('Valid') };
}
