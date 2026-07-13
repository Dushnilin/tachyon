import { validateDomain } from './validateDomain';
import { isIPv4, isIPv6 } from './validateIp';

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

export function parseHostPort(value: string): ParsedHostPort | null {
  if (!value) {
    return null;
  }

  if (value.startsWith('[')) {
    const end = value.indexOf(']');
    if (end <= 1 || value.slice(end + 1, end + 2) !== ':') {
      return null;
    }

    return {
      host: value.slice(1, end),
      port: value.slice(end + 2),
    };
  }

  const firstColon = value.indexOf(':');
  const lastColon = value.lastIndexOf(':');
  if (firstColon < 0 || firstColon !== lastColon) {
    return null;
  }

  return {
    host: value.slice(0, firstColon),
    port: value.slice(firstColon + 1),
  };
}
