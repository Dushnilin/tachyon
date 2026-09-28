import { IConnection } from './partials';

export function aggregateClientConnections(
  rawConnections: Array<{
    metadata?: { sourceIP?: string };
    upload?: number | string;
    download?: number | string;
  }>,
  hostnames: Map<string, string>,
): IConnection[] {
  const map = new Map<string, IConnection>();

  for (const conn of rawConnections) {
    const ip = conn.metadata?.sourceIP;
    if (!ip) continue;

    const up = Number(conn.upload) || 0;
    const down = Number(conn.download) || 0;

    if (map.has(ip)) {
      const existing = map.get(ip)!;
      existing.count++;
      existing.upload += up;
      existing.download += down;
    } else {
      const name = hostnames.get(ip);
      map.set(ip, { ip, count: 1, upload: up, download: down, name });
    }
  }

  return Array.from(map.values()).sort(
    (a, b) => b.download + b.upload - (a.download + a.upload),
  );
}
