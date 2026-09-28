export function normalizeString(value: unknown): string {
  return value == null ? '' : String(value).trim();
}

export function formatEndpoint(
  address?: string,
  port?: string | number,
): string {
  const normalizedAddress = normalizeString(address);
  const normalizedPort = normalizeString(port);

  if (!normalizedAddress) {
    return '-';
  }

  if (!normalizedPort || normalizedPort === '443') {
    return normalizedAddress;
  }

  if (normalizedAddress.includes(':') && !normalizedAddress.startsWith('[')) {
    return `[${normalizedAddress}]:${normalizedPort}`;
  }

  return `${normalizedAddress}:${normalizedPort}`;
}

export function formatDuration(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const pad = (value: number) => String(value).padStart(2, '0');

  if (hours > 0) {
    return `${hours}:${pad(minutes)}:${pad(seconds)}`;
  }

  return `${minutes}:${pad(seconds)}`;
}

export function parseStartedAt(connection: {
  start?: string;
  lastSeenAt: number;
}): number {
  const startedAt = Date.parse(connection.start || '');
  return Number.isFinite(startedAt) ? startedAt : connection.lastSeenAt;
}
