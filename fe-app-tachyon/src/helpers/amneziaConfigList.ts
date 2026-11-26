export interface AmneziaEntryMeta {
  name: string;
  endpoint: string;
  protocol: string;
  isVpnLink: boolean;
  raw: string;
}

const AWG_OBFUSCATION_KEY_RE =
  /(?:^|\n)\s*(?:Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5])\s*=/i;
const ENDPOINT_RE = /(?:^|\n)\s*Endpoint\s*=\s*([^\r\n#;]+)/i;

function detectProtocolFromConfigBody(configBody: string): {
  protocol: string;
  isVpnLink: boolean;
  endpoint: string;
} {
  const trimmed = configBody.trim();
  if (/^vpn:\/\//i.test(trimmed)) {
    return {
      protocol: 'Amnezia (vpn://)',
      isVpnLink: true,
      endpoint: '',
    };
  }
  const epMatch = trimmed.match(ENDPOINT_RE);
  const endpoint = epMatch ? epMatch[1].trim() : '';
  const isAwg = AWG_OBFUSCATION_KEY_RE.test(trimmed);
  return {
    protocol: isAwg ? 'AmneziaWG' : 'WireGuard',
    isVpnLink: false,
    endpoint,
  };
}

export function parseAmneziaEntryMeta(
  rawEntry: string,
  index: number,
): AmneziaEntryMeta {
  const raw = String(rawEntry || '').trim();
  const fallbackName = `Config #${index + 1}`;
  if (!raw) {
    return {
      name: fallbackName,
      endpoint: '',
      protocol: 'WireGuard',
      isVpnLink: false,
      raw,
    };
  }

  if (raw.startsWith('{')) {
    try {
      const parsed = JSON.parse(raw) as { name?: unknown; config?: unknown };
      if (parsed && typeof parsed === 'object') {
        const name =
          typeof parsed.name === 'string' && parsed.name.trim()
            ? parsed.name.trim()
            : fallbackName;
        const body =
          typeof parsed.config === 'string' ? parsed.config.trim() : '';
        const info = detectProtocolFromConfigBody(body);
        return {
          name,
          endpoint: info.endpoint,
          protocol: info.protocol,
          isVpnLink: info.isVpnLink,
          raw,
        };
      }
    } catch {
      // Fall through to raw config parsing
    }
  }

  const info = detectProtocolFromConfigBody(raw);
  return {
    name: info.isVpnLink ? `Amnezia #${index + 1}` : fallbackName,
    endpoint: info.endpoint,
    protocol: info.protocol,
    isVpnLink: info.isVpnLink,
    raw,
  };
}

function getAmneziaEntryDedupKey(rawEntry: string): string {
  const trimmed = String(rawEntry || '')
    .replace(/\r\n?/g, '\n')
    .trim();
  if (!trimmed) return '';
  if (trimmed.startsWith('{')) {
    try {
      const parsed = JSON.parse(trimmed) as { config?: unknown };
      if (
        parsed &&
        typeof parsed === 'object' &&
        typeof parsed.config === 'string'
      ) {
        const body = parsed.config.replace(/\r\n?/g, '\n').trim();
        if (body) return `cfg:${body}`;
      }
    } catch {
      // Ignore malformed JSON and fall back to raw key
    }
  }
  return `raw:${trimmed}`;
}

export function dedupeAmneziaEntries(entries: string[]): string[] {
  const out: string[] = [];
  const seenKeys = new Set<string>();
  for (const item of entries) {
    const trimmed = String(item || '').trim();
    if (!trimmed) continue;
    const key = getAmneziaEntryDedupKey(trimmed);
    if (!key || seenKeys.has(key)) continue;
    seenKeys.add(key);
    out.push(trimmed);
  }
  return out;
}

export function removeAmneziaEntryAt(
  entries: string[],
  index: number,
): string[] {
  return entries.filter((_, idx) => idx !== index);
}

export function promoteAmneziaEntryToPrimary(
  entries: string[],
  index: number,
): string[] {
  if (index <= 0 || index >= entries.length) {
    return [...entries];
  }
  const copy = [...entries];
  const [picked] = copy.splice(index, 1);
  return [picked, ...copy];
}

export function applyAmneziaConfTextUpdate(opts: {
  currentConfigs: string[];
  pastedText: string;
  defaultName: string;
  appendMode: boolean;
  splitEntries: (
    raw: string,
    defaultName?: string,
  ) => { vpnLinks: string[]; confBody: string; entries: string[] };
}): { nextConfigs: string[]; clearText: boolean } {
  const trimmed = String(opts.pastedText || '')
    .replace(/\r\n?/g, '\n')
    .trim();
  if (!trimmed) {
    return {
      nextConfigs: dedupeAmneziaEntries(opts.currentConfigs),
      clearText: true,
    };
  }
  const { entries: candidates } = opts.splitEntries(trimmed, opts.defaultName);
  const nextConfigs = opts.appendMode
    ? dedupeAmneziaEntries([...opts.currentConfigs, ...candidates])
    : dedupeAmneziaEntries(candidates);
  return {
    nextConfigs,
    clearText: true,
  };
}

export function applyAmneziaFileUpload(opts: {
  currentConfigs: string[];
  loadedFiles: Array<{ name: string; config: string }>;
  appendMode: boolean;
}): string[] {
  const validEntries = opts.loadedFiles
    .filter((item) => item && String(item.config || '').trim().length > 0)
    .map((item) =>
      JSON.stringify({
        name: String(item.name || '').trim() || 'AmneziaWG',
        config: String(item.config || '')
          .replace(/\r\n?/g, '\n')
          .trim(),
      }),
    );
  if (!validEntries.length) {
    return dedupeAmneziaEntries(opts.currentConfigs);
  }
  return opts.appendMode
    ? dedupeAmneziaEntries([...opts.currentConfigs, ...validEntries])
    : dedupeAmneziaEntries(validEntries);
}
