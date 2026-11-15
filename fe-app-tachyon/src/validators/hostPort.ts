import { validateDomain } from './validateDomain';
import { isIPv4, isIPv6 } from './validateIp';

export function formatHostForUri(host: string): string {
  const normalized = unbracketHost(String(host || '').trim());
  return isIPv6(normalized) ? `[${normalized}]` : normalized;
}

export function splitHostPort(
  value: string,
): { host: string; port?: string } | null {
  const trimmed = String(value || '').trim();
  if (!trimmed) {
    return null;
  }

  if (trimmed.startsWith('[')) {
    const end = trimmed.indexOf(']');
    if (end <= 1) {
      return null;
    }
    const host = trimmed.slice(1, end);
    if (!isIPv6(host) && !isValidHost(host)) {
      return null;
    }
    const rest = trimmed.slice(end + 1);
    if (!rest) {
      return { host };
    }
    if (!rest.startsWith(':')) {
      return null;
    }
    const port = rest.slice(1);
    return port ? { host, port } : null;
  }

  const firstColon = trimmed.indexOf(':');
  const lastColon = trimmed.lastIndexOf(':');
  if (firstColon < 0) {
    return isValidHost(trimmed) ? { host: trimmed } : null;
  }
  if (firstColon === lastColon) {
    const host = trimmed.slice(0, firstColon);
    const port = trimmed.slice(firstColon + 1);
    return host && port && isValidHost(host) ? { host, port } : null;
  }
  return isIPv6(trimmed) ? { host: trimmed } : null;
}

export type ParsedHostPort = {
  host: string;
  port: string;
};

export function unbracketHost(host: string): string {
  if (host.startsWith('[') && host.endsWith(']')) {
    return host.slice(1, -1);
  }

  return host;
}

export function isValidHost(host: string): boolean {
  const normalizedHost = unbracketHost(host);

  return (
    isIPv4(normalizedHost) ||
    isIPv6(normalizedHost) ||
    validateDomain(normalizedHost).valid
  );
}

export function isValidPort(port: unknown): boolean {
  const normalized = String(port ?? '');
  const value = Number(normalized);
  return /^\d+$/.test(normalized) && value >= 1 && value <= 65535;
}

export function parseHostPort(value: string): ParsedHostPort | null {
  if (!value) {
    return null;
  }

  if (value.startsWith('[')) {
    const end = value.indexOf(']');
    if (end <= 1 || value.slice(end + 1, end + 2) !== ':') {
      return null;
    }

    const parsed = {
      host: value.slice(1, end),
      port: value.slice(end + 2),
    };
    return isValidHost(parsed.host) ? parsed : null;
  }

  const firstColon = value.indexOf(':');
  const lastColon = value.lastIndexOf(':');
  if (firstColon < 0 || firstColon !== lastColon) {
    return null;
  }

  const parsed = {
    host: value.slice(0, firstColon),
    port: value.slice(firstColon + 1),
  };
  return isValidHost(parsed.host) ? parsed : null;
}
