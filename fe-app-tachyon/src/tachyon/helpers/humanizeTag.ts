import { TACHYON_UCI_PACKAGE } from '../../constants';
import { cleanBalancerTagId } from '../runtimeTags';
import { tr } from './i18n';

const SOURCE_PREFIXES = [
  'awgconf-',
  'awg-',
  'warp-',
  'ovpn-',
  'sub-',
  'link-',
  'fptn-',
  'iface-',
  'desync-',
  'wg-',
  'vless-',
  'vmess-',
  'trojan-',
  'ss-',
  'hy2-',
  'tuic-',
  'mieru-',
  'naive-',
  'anytls-',
  'snell-',
  'sudoku-',
  'trusttunnel-',
  'tewfai-',
  'masque-',
  'openconnect-',
  'shadowtls-',
  'tailscale-',
  'custom-',
];

const INDEXED_SOURCE_PREFIXES = [
  'awgconf-',
  'awg-',
  'wg-',
  'warp-',
  'fptn-',
  'ovpn-',
  'desync-',
  'iface-',
  'tailscale-',
  'sub-',
  'link-',
  'json-',
];

export interface RuntimeTagDisplayContext {
  exact: Map<string, string>;
  lower: Map<string, string>;
  sections: Array<{ id: string; label: string }>;
  balancers: Array<{ id: string; name: string }>;
  servers: Array<{ id: string; label: string }>;
}

interface UciSectionRecord {
  '.name'?: unknown;
  label?: unknown;
  name?: unknown;
  action?: unknown;
  connection_type?: unknown;
  outbound_source_refs?: unknown;
  id?: unknown;
  source_type?: unknown;
  custom_json?: unknown;
}

function safeUciList(sectionType: string): UciSectionRecord[] {
  try {
    if (typeof uci !== 'undefined' && typeof uci.sections === 'function') {
      const list = uci.sections(TACHYON_UCI_PACKAGE, sectionType);
      return Array.isArray(list) ? (list as UciSectionRecord[]) : [];
    }
  } catch {
    // Ignore when UCI is unavailable in isolated unit tests
  }
  return [];
}

function cleanTechnicalSourceStem(stem: string): string {
  const s = stem.trim();
  if (s.startsWith('src_') && s.length > 4) {
    return s.slice(4);
  }
  return s;
}

function isTechnicalRuntimeTag(tag: string): boolean {
  return /^(?:bal-|sel-|desync-sec-|tailscale-sec-|srv-|server-.*-in|awgconf-|awg-|wg-|warp-|fptn-|ovpn-|iface-|desync-)/i.test(
    tag,
  );
}

export function buildRuntimeTagDisplayContextFromUci(): RuntimeTagDisplayContext {
  const exact = new Map<string, string>();
  const lower = new Map<string, string>();
  const setTag = (key: string, label: string) => {
    if (!key || !label) return;
    if (!exact.has(key)) exact.set(key, label);
    const lc = key.toLowerCase();
    if (!lower.has(lc)) lower.set(lc, label);
  };

  const sectionRecords = safeUciList('section');
  const balancerRecords = safeUciList('balancer');
  const sourceRecords = safeUciList('outbound_source');
  const serverRecords = safeUciList('server');

  const sections: Array<{ id: string; label: string }> = [];
  const balancers: Array<{ id: string; name: string }> = [];
  const servers: Array<{ id: string; label: string }> = [];
  const uniqueSourceOwner = new Map<string, string | null>();

  for (const sec of sectionRecords) {
    const sid = String(sec?.['.name'] || '').trim();
    if (!sid) continue;
    const lbl = String(sec?.label || sec?.name || sid).trim() || sid;
    sections.push({ id: sid, label: lbl });
    setTag(`sel-${sid}`, lbl);
    setTag(`${sid}-out`, lbl);
    setTag(`desync-sec-${sid}`, lbl);
    setTag(`tailscale-sec-${sid}`, lbl);
    setTag(sid, lbl);

    const refsRaw = sec?.outbound_source_refs;
    const refs = Array.isArray(refsRaw)
      ? refsRaw.map((v: unknown) => String(v || '').trim()).filter(Boolean)
      : typeof refsRaw === 'string'
        ? refsRaw.split(/\s+/).filter(Boolean)
        : [];
    for (const sref of refs) {
      if (!uniqueSourceOwner.has(sref)) {
        uniqueSourceOwner.set(sref, lbl);
      } else if (uniqueSourceOwner.get(sref) !== lbl) {
        uniqueSourceOwner.set(sref, null);
      }
    }
  }

  const defaultDesyncSections = sectionRecords.filter((sec) => {
    const act = String(sec?.action || '').toLowerCase();
    const ct = String(sec?.connection_type || '').toLowerCase();
    const refsRaw = sec?.outbound_source_refs;
    const hasRefs = Array.isArray(refsRaw)
      ? refsRaw.some((v) => String(v || '').trim().length > 0)
      : typeof refsRaw === 'string' && refsRaw.trim().length > 0;
    return sec && (act === 'desync' || ct === 'desync') && !hasRefs;
  });
  if (defaultDesyncSections.length === 1) {
    const dSec = defaultDesyncSections[0];
    const dLbl =
      String(dSec?.label || dSec?.name || dSec?.['.name'] || '').trim() ||
      'Desync';
    setTag('adaptive-desync-default', dLbl);
  }

  for (const bal of balancerRecords) {
    const bid = String(bal?.['.name'] || bal?.id || '').trim();
    if (!bid) continue;
    const bname = String(bal?.name || '').trim();
    balancers.push({ id: bid, name: bname });
    for (const sec of sections) {
      const balLabel = bname || cleanBalancerTagId(sec.id, bid);
      setTag(`bal-${sec.id}-${bid}`, balLabel);
      setTag(`${sec.id}-urltest-${bid}`, balLabel);
      setTag(`${sec.id}-priority-${bid}`, balLabel);
    }
    if (bname) setTag(bid, bname);
  }

  for (const src of sourceRecords) {
    const srcId = String(src?.['.name'] || '').trim();
    if (!srcId) continue;
    const srcName = String(src?.name || src?.label || '').trim();
    const ownerLabel = uniqueSourceOwner.get(srcId) || '';
    const srcLabel =
      src?.source_type === 'desync'
        ? ownerLabel || srcName || srcId
        : srcName || ownerLabel || srcId;
    for (const pfx of SOURCE_PREFIXES) {
      setTag(`${pfx}${srcId}`, srcLabel);
      setTag(`${pfx}${srcId}-0`, srcLabel);
    }
    if (src?.source_type === 'custom_json' && src?.custom_json) {
      try {
        const parsed = JSON.parse(String(src.custom_json)) as Record<
          string,
          unknown
        >;
        const ctag = typeof parsed?.tag === 'string' ? parsed.tag.trim() : '';
        if (ctag) setTag(ctag, srcLabel);
      } catch {
        // Ignore malformed custom JSON
      }
    }
    setTag(srcId, srcLabel);
  }

  for (const srv of serverRecords) {
    const srvId = String(srv?.['.name'] || '').trim();
    if (!srvId) continue;
    const srvLabel = String(srv?.label || srv?.name || srvId).trim() || srvId;
    servers.push({ id: srvId, label: srvLabel });
    setTag(`srv-${srvId}`, srvLabel);
    setTag(`srv-${srvId}-inner`, srvLabel);
    setTag(`server-${srvId}-in`, srvLabel);
    setTag(`server-${srvId}-in-inner`, srvLabel);
  }

  return { exact, lower, sections, balancers, servers };
}

export interface HumanizeTagOptions {
  directBlockLabels?: boolean;
  context?: RuntimeTagDisplayContext;
}

export function humanizeRuntimeTag(
  rawTag?: string,
  explicitDisplayName?: string,
  options?: HumanizeTagOptions,
): string {
  const raw = String(rawTag || '').trim();
  const explicit = String(explicitDisplayName || '').trim();
  if (
    explicit &&
    (!raw || (explicit !== raw && !isTechnicalRuntimeTag(explicit)))
  ) {
    return explicit;
  }
  if (!raw) {
    return explicit;
  }

  const lowerRaw = raw.toLowerCase();
  if (options?.directBlockLabels !== false) {
    if (lowerRaw === 'direct' || lowerRaw === 'direct-out') {
      return tr('Напрямую', 'Direct');
    }
    if (
      lowerRaw === 'block' ||
      lowerRaw === 'block-out' ||
      lowerRaw === 'reject'
    ) {
      return tr('Блокировка', 'Block');
    }
  }

  const ctx = options?.context || buildRuntimeTagDisplayContextFromUci();
  const hit = ctx.exact.get(raw) || ctx.lower.get(lowerRaw);
  if (hit) {
    return hit;
  }

  const findSectionLabel = (secId: string) =>
    ctx.sections.find((s) => s.id.toLowerCase() === secId.toLowerCase())
      ?.label || secId;

  const secPrefixMatch = raw.match(/^(?:sel|desync-sec|tailscale-sec)-(.+)$/i);
  if (secPrefixMatch?.[1]) {
    return findSectionLabel(secPrefixMatch[1]);
  }

  const srvV2Match = raw.match(/^srv-(.+?)(?:-inner)?$/i);
  if (srvV2Match?.[1]) {
    const srvId = srvV2Match[1];
    return (
      ctx.servers.find((s) => s.id.toLowerCase() === srvId.toLowerCase())
        ?.label || srvId
    );
  }

  const srvLegacyMatch = raw.match(/^server-(.+)-in(?:-inner)?$/i);
  if (srvLegacyMatch?.[1]) {
    const srvId = srvLegacyMatch[1];
    return (
      ctx.servers.find((s) => s.id.toLowerCase() === srvId.toLowerCase())
        ?.label || srvId
    );
  }

  if (lowerRaw.endsWith('-out') && raw.length > 4) {
    const baseSec = raw.slice(0, -4);
    const knownSec = ctx.sections.find(
      (s) => s.id.toLowerCase() === baseSec.toLowerCase(),
    );
    if (knownSec) return knownSec.label;
    return baseSec;
  }

  if (lowerRaw.startsWith('bal-')) {
    const rest = raw.slice(4);
    let bestSecId = '';
    for (const sec of ctx.sections) {
      if (
        rest.length > sec.id.length + 1 &&
        rest.slice(0, sec.id.length).toLowerCase() === sec.id.toLowerCase() &&
        rest[sec.id.length] === '-' &&
        sec.id.length > bestSecId.length
      ) {
        bestSecId = sec.id;
      }
    }
    if (bestSecId) {
      const balPart = rest.slice(bestSecId.length + 1);
      const knownBal = ctx.balancers.find(
        (b) => b.id.toLowerCase() === balPart.toLowerCase() && b.name,
      );
      return knownBal ? knownBal.name : cleanBalancerTagId(bestSecId, balPart);
    }
    const balStructured = raw.match(/^bal-(.+?)-(bal_(?:prio_)?.*)$/i);
    if (balStructured) {
      return cleanBalancerTagId(balStructured[1], balStructured[2]);
    }
    const balSimple = raw.match(/^bal-([^-]+)-(.+)$/i);
    if (balSimple) {
      return cleanBalancerTagId(balSimple[1], balSimple[2]);
    }
  }

  const parenMatch = raw.match(/^(.+)\s+\((\d+)\)$/);
  if (parenMatch) {
    const baseLabel = humanizeRuntimeTag(parenMatch[1], undefined, {
      ...options,
      directBlockLabels: false,
      context: ctx,
    });
    const peerNum = Number(parenMatch[2]);
    return peerNum <= 1 ? baseLabel : `${baseLabel} #${peerNum}`;
  }

  for (const pfx of INDEXED_SOURCE_PREFIXES) {
    if (raw.length > pfx.length && lowerRaw.startsWith(pfx)) {
      const rest = raw.slice(pfx.length);
      const idxMatch = rest.match(/^(.+)-(\d+)$/);
      if (idxMatch) {
        const stem = idxMatch[1];
        const idxNum = Number(idxMatch[2]);
        const baseKey = `${pfx}${stem}`;
        const baseLabel =
          ctx.exact.get(baseKey) ||
          ctx.lower.get(baseKey.toLowerCase()) ||
          cleanTechnicalSourceStem(stem);
        return idxNum === 0 ? baseLabel : `${baseLabel} #${idxNum + 1}`;
      }
      return cleanTechnicalSourceStem(rest);
    }
  }

  return raw;
}
