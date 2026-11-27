import { ValidationResult } from './types';

const MAX_AMNEZIA_SIZE = 65536;
const AMNEZIA_CONFIG_SIGNATURE = 255;

export function supportsVpnUrl() {
  return true;
}

export function compactVpnUri(raw: string): string {
  const trimmed = String(raw || '').trim();
  if (!trimmed.startsWith('vpn://')) {
    return trimmed;
  }
  const hashIdx = trimmed.indexOf('#');
  const head = hashIdx >= 0 ? trimmed.slice(0, hashIdx) : trimmed;
  const frag = hashIdx >= 0 ? trimmed.slice(hashIdx + 1).trim() : '';
  const compactHead = head.replace(/[\r\n\t ]+/g, '');
  return frag ? `${compactHead}#${frag}` : compactHead;
}

function isVpnBase64ContinuationLine(line: string): boolean {
  const trimmed = line.trim();
  if (
    !trimmed ||
    trimmed.startsWith('vpn://') ||
    trimmed.startsWith('[') ||
    trimmed.startsWith('#') ||
    trimmed.startsWith(';')
  ) {
    return false;
  }
  return /^[A-Za-z0-9+/_%-]+={0,2}(#.*)?$/.test(trimmed);
}

export function splitAmneziaTextEntries(
  rawText: string,
  defaultName = 'AmneziaWG',
): { vpnLinks: string[]; confBody: string; entries: string[] } {
  const normalized = String(rawText || '')
    .replace(/\r\n?/g, '\n')
    .trim();
  const vpnLinks: string[] = [];
  const confLines: string[] = [];
  let inVpn = false;
  let currentHasFrag = false;

  for (const line of normalized.split('\n')) {
    const trimmed = line.trim();
    if (/^(?:vpn|phobos):\/\//i.test(trimmed)) {
      const compact = trimmed.startsWith('vpn://')
        ? compactVpnUri(trimmed)
        : trimmed;
      vpnLinks.push(compact);
      currentHasFrag = compact.includes('#');
      inVpn = trimmed.startsWith('vpn://') && !currentHasFrag;
    } else if (
      inVpn &&
      !currentHasFrag &&
      isVpnBase64ContinuationLine(trimmed)
    ) {
      const lastIdx = vpnLinks.length - 1;
      const hashIdx = trimmed.indexOf('#');
      if (hashIdx >= 0) {
        const tailB64 = trimmed.slice(0, hashIdx);
        const tailFrag = trimmed.slice(hashIdx + 1).trim();
        vpnLinks[lastIdx] += tailB64 + (tailFrag ? `#${tailFrag}` : '');
        currentHasFrag = true;
        inVpn = false;
      } else {
        vpnLinks[lastIdx] += trimmed;
      }
    } else {
      inVpn = false;
      currentHasFrag = false;
      confLines.push(line);
    }
  }

  const confBody = confLines.join('\n').trim();
  const entries: string[] = [];
  if (confBody) {
    entries.push(
      JSON.stringify({ name: defaultName || 'AmneziaWG', config: confBody }),
    );
  }
  vpnLinks.forEach((v) => entries.push(v));
  return { vpnLinks, confBody, entries };
}

function adler32(data: Uint8Array): number {
  let a = 1;
  let b = 0;
  for (let i = 0; i < data.length; i++) {
    a = (a + data[i]) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
}

const FIXED_LIT_LENS = (() => {
  const lens = new Array<number>(288);
  for (let i = 0; i <= 143; i++) lens[i] = 8;
  for (let i = 144; i <= 255; i++) lens[i] = 9;
  for (let i = 256; i <= 279; i++) lens[i] = 7;
  for (let i = 280; i <= 287; i++) lens[i] = 8;
  return lens;
})();
const FIXED_DIST_LENS = new Array<number>(32).fill(5);

interface HuffTree {
  counts: Int32Array;
  symbols: Int32Array;
  maxBits: number;
}

function buildHuffTree(lengths: number[]): HuffTree | null {
  let maxBits = 0;
  const counts = new Int32Array(16);
  for (let i = 0; i < lengths.length; i++) {
    const len = lengths[i];
    if (len < 0 || len > 15) return null;
    if (len > 0) {
      counts[len]++;
      if (len > maxBits) maxBits = len;
    }
  }
  if (maxBits === 0) {
    return { counts, symbols: new Int32Array(0), maxBits: 0 };
  }
  const offs = new Int32Array(16);
  let left = 1;
  for (let bits = 1; bits <= 15; bits++) {
    left <<= 1;
    left -= counts[bits];
    if (left < 0) return null;
    if (bits < 15) offs[bits + 1] = offs[bits] + counts[bits];
  }
  const symbols = new Int32Array(lengths.length);
  for (let sym = 0; sym < lengths.length; sym++) {
    const len = lengths[sym];
    if (len > 0) {
      symbols[offs[len]++] = sym;
    }
  }
  return { counts, symbols, maxBits };
}

const FIXED_LIT_TREE = buildHuffTree(FIXED_LIT_LENS)!;
const FIXED_DIST_TREE = buildHuffTree(FIXED_DIST_LENS)!;
const CL_ORDER = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
];
const LEN_BASE = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67,
  83, 99, 115, 131, 163, 195, 227, 258,
];
const LEN_EXTRA = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5,
  5, 5, 0,
];
const DIST_BASE = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DIST_EXTRA = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11,
  11, 12, 12, 13, 13,
];

function inflateZlibStream(zlibBytes: Uint8Array): Uint8Array | null {
  if (zlibBytes.length < 6) return null;
  const cmf = zlibBytes[0];
  const flg = zlibBytes[1];
  if (
    (cmf & 15) !== 8 ||
    cmf >> 4 > 7 ||
    (flg & 32) !== 0 ||
    (cmf * 256 + flg) % 31 !== 0
  ) {
    return null;
  }

  const stream = zlibBytes.subarray(2, zlibBytes.length - 4);
  const expectedAdler =
    ((zlibBytes[zlibBytes.length - 4] << 24) |
      (zlibBytes[zlibBytes.length - 3] << 16) |
      (zlibBytes[zlibBytes.length - 2] << 8) |
      zlibBytes[zlibBytes.length - 1]) >>>
    0;

  let bitPos = 0;
  const totalBits = stream.length * 8;

  const readBits = (n: number): number => {
    if (bitPos + n > totalBits) throw new Error('eof');
    let val = 0;
    for (let i = 0; i < n; i++) {
      const idx = bitPos + i;
      val |= ((stream[idx >> 3] >> (idx & 7)) & 1) << i;
    }
    bitPos += n;
    return val;
  };

  const decodeSymbol = (tree: HuffTree): number => {
    let code = 0;
    let first = 0;
    let index = 0;
    for (let len = 1; len <= tree.maxBits; len++) {
      if (bitPos >= totalBits) throw new Error('eof');
      code |= (stream[bitPos >> 3] >> (bitPos & 7)) & 1;
      bitPos++;
      const count = tree.counts[len];
      if (code - count < first) {
        return tree.symbols[index + (code - first)];
      }
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw new Error('huff');
  };

  const out: number[] = [];
  let bfinal = 0;

  try {
    do {
      bfinal = readBits(1);
      const btype = readBits(2);
      if (btype === 3) return null;

      if (btype === 0) {
        bitPos = (bitPos + 7) & ~7;
        const byteOff = bitPos >> 3;
        if (byteOff + 4 > stream.length) return null;
        const len = stream[byteOff] | (stream[byteOff + 1] << 8);
        const nlen = stream[byteOff + 2] | (stream[byteOff + 3] << 8);
        if ((len ^ 0xffff) !== nlen) return null;
        const dataStart = byteOff + 4;
        if (
          dataStart + len > stream.length ||
          out.length + len > MAX_AMNEZIA_SIZE
        ) {
          return null;
        }
        for (let i = 0; i < len; i++) {
          out.push(stream[dataStart + i]);
        }
        bitPos = (dataStart + len) * 8;
        continue;
      }

      let litTree = FIXED_LIT_TREE;
      let distTree = FIXED_DIST_TREE;
      if (btype === 2) {
        const hlit = readBits(5) + 257;
        const hdist = readBits(5) + 1;
        const hclen = readBits(4) + 4;
        if (hlit > 286 || hdist > 30) return null;
        const clLens = new Array<number>(19).fill(0);
        for (let i = 0; i < hclen; i++) {
          clLens[CL_ORDER[i]] = readBits(3);
        }
        const clTree = buildHuffTree(clLens);
        if (!clTree) return null;
        const allLens: number[] = [];
        while (allLens.length < hlit + hdist) {
          const sym = decodeSymbol(clTree);
          if (sym < 16) {
            allLens.push(sym);
          } else if (sym === 16) {
            if (!allLens.length) return null;
            const prev = allLens[allLens.length - 1];
            const rep = 3 + readBits(2);
            for (let k = 0; k < rep; k++) allLens.push(prev);
          } else {
            const rep = (sym === 17 ? 3 : 11) + readBits(sym === 17 ? 3 : 7);
            for (let k = 0; k < rep; k++) allLens.push(0);
          }
        }
        if (allLens.length !== hlit + hdist) return null;
        const lt = buildHuffTree(allLens.slice(0, hlit));
        const dt = buildHuffTree(allLens.slice(hlit));
        if (!lt || !dt) return null;
        litTree = lt;
        distTree = dt;
      }

      for (;;) {
        const sym = decodeSymbol(litTree);
        if (sym === 256) break;
        if (sym < 256) {
          if (out.length >= MAX_AMNEZIA_SIZE) return null;
          out.push(sym);
        } else {
          const lenIdx = sym - 257;
          if (lenIdx < 0 || lenIdx >= LEN_BASE.length) return null;
          const length = LEN_BASE[lenIdx] + readBits(LEN_EXTRA[lenIdx]);
          const distSym = decodeSymbol(distTree);
          if (distSym >= DIST_BASE.length) return null;
          const dist = DIST_BASE[distSym] + readBits(DIST_EXTRA[distSym]);
          if (
            dist <= 0 ||
            dist > out.length ||
            out.length + length > MAX_AMNEZIA_SIZE
          ) {
            return null;
          }
          for (let i = 0; i < length; i++) {
            out.push(out[out.length - dist]);
          }
        }
      }
    } while (!bfinal);
  } catch (_e) {
    return null;
  }

  if ((bitPos + 7) >> 3 !== stream.length) {
    return null;
  }
  const result = new Uint8Array(out);
  if (adler32(result) !== expectedAdler) {
    return null;
  }
  return result;
}

function decodeUtf8Strict(bytes: Uint8Array): string | null {
  try {
    const decoded = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    if (decoded.includes('\0') || decoded.length > MAX_AMNEZIA_SIZE) {
      return null;
    }
    return decoded;
  } catch (_e) {
    return null;
  }
}

function decompressVpnUri(rawUrl: string): string | null {
  const compacted = compactVpnUri(rawUrl);
  if (!compacted.startsWith('vpn://')) return null;
  let payload = decodeURIComponent(compacted.slice(6).split('#')[0]).replace(
    /[\r\n\t ]+/g,
    '',
  );
  if (
    payload.length > 131072 ||
    !/^[A-Za-z0-9+/_-]*={0,2}$/.test(payload) ||
    payload.length % 4 === 1
  ) {
    return null;
  }
  payload = payload.replace(/-/g, '+').replace(/_/g, '/');
  while (payload.length % 4) payload += '=';
  const bin = atob(payload);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) {
    bytes[i] = bin.charCodeAt(i);
  }

  // Qt qCompress (4-byte big-endian size + zlib) or Amnezia signature 0x000000FF + zlib
  if (bytes.length >= 6 && bytes[0] === 0) {
    const declared =
      bytes[0] * 16777216 + bytes[1] * 65536 + bytes[2] * 256 + bytes[3];
    if (!declared || declared > MAX_AMNEZIA_SIZE) return null;
    const inflated = inflateZlibStream(bytes.subarray(4));
    if (!inflated) return null;
    if (declared !== AMNEZIA_CONFIG_SIGNATURE && inflated.length !== declared) {
      return null;
    }
    if (inflated.length === 0 || inflated.length > MAX_AMNEZIA_SIZE) {
      return null;
    }
    return decodeUtf8Strict(inflated);
  }

  const trimmedAscii = bin.trim();
  if (
    bytes.length >= 8 &&
    !trimmedAscii.startsWith('{') &&
    !trimmedAscii.startsWith('[') &&
    !trimmedAscii.startsWith('#')
  ) {
    const cmf = bytes[0];
    const flg = bytes[1];
    if (
      (cmf & 15) === 8 &&
      cmf >> 4 <= 7 &&
      !(flg & 32) &&
      (cmf * 256 + flg) % 31 === 0
    ) {
      const inflated = inflateZlibStream(bytes);
      if (!inflated) return null;
      return decodeUtf8Strict(inflated);
    }
  }

  return decodeUtf8Strict(bytes);
}

const AWG_CONTAINER_KINDS = new Set([
  'amnezia-awg',
  'amnezia-awg2',
  'amnezia-awg-v2',
  'amnezia-awg1.5',
  'amnezia-awg3',
  'amnezia-awg-v3',
  'amnezia-awg3.1',
  'awg',
  'awg2',
  'awg3',
]);
const WG_CONTAINER_KINDS = new Set(['amnezia-wireguard', 'wireguard', 'wg']);
const PROXY_CONTAINER_KINDS = new Set([
  'amnezia-xray',
  'xray',
  'xray-reality',
  'amnezia-ssxray',
  'ssxray',
  'amnezia-shadowsocks',
  'shadowsocks',
  'amnezia-ss',
  'ss',
]);

function firstStr(
  objs: (Record<string, unknown> | null | undefined)[],
  keys: string[],
): string {
  for (const obj of objs) {
    if (!obj || typeof obj !== 'object') continue;
    for (const k of keys) {
      const v = obj[k];
      if (typeof v === 'string' && v.trim()) return v.trim();
      if (typeof v === 'number' && Number.isFinite(v)) return String(v);
    }
  }
  return '';
}

function finalizeConfText(
  confText: string,
  last: Record<string, unknown> | null,
  settings: Record<string, unknown> | null,
  rootData: Record<string, unknown> | null,
): string {
  let out = String(confText || '');
  const remoteHost = firstStr(
    [last, settings, rootData],
    ['hostName', 'hostname', 'server', 'server_addr', 'endpoint_host'],
  );
  if (remoteHost) {
    out = out
      .replace(/\$REMOTE_HOST/g, remoteHost)
      .replace(/\$SERVER_IP_ADDRESS/g, remoteHost);
  }
  const lower = out.toLowerCase();
  if (lower.includes('[interface]') && !lower.includes('[peer]')) {
    const pub = firstStr(
      [last, settings, rootData],
      ['server_pub_key', 'public_key', 'peer_public_key'],
    );
    const port = firstStr([last, settings, rootData], ['port', 'server_port']);
    const epRaw = firstStr([last, settings, rootData], ['endpoint']);
    const endpoint =
      epRaw ||
      (remoteHost && port
        ? `${remoteHost.includes(':') && !remoteHost.startsWith('[') ? `[${remoteHost}]` : remoteHost}:${port}`
        : '');
    if (pub && endpoint) {
      const psk = firstStr(
        [last, settings, rootData],
        ['psk_key', 'preshared_key'],
      );
      const allowed =
        firstStr([last, settings, rootData], ['allowed_ips', 'allowedIPs']) ||
        '0.0.0.0/0, ::/0';
      const peerLines = [
        '[Peer]',
        `PublicKey = ${pub}`,
        `Endpoint = ${endpoint}`,
        `AllowedIPs = ${allowed}`,
      ];
      if (psk) peerLines.push(`PresharedKey = ${psk}`);
      out = `${out.trimEnd()}\n${peerLines.join('\n')}\n`;
    }
  }
  return out;
}

export function validateVpnUrl(url: string): ValidationResult {
  const invalid = () => ({
    valid: false,
    message: _('Invalid vpn:// link; use a WG/AWG .conf or Amnezia export'),
  });
  const key32 = (value: unknown) => {
    try {
      let key = String(value || '')
        .trim()
        .replace(/ /g, '+')
        .replace(/-/g, '+')
        .replace(/_/g, '/');
      if (key.length === 43 && /^[A-Za-z0-9+/]{43}$/.test(key)) key += '=';
      return /^[A-Za-z0-9+/]{43}=$/.test(key) && atob(key).length === 32;
    } catch (_e) {
      return false;
    }
  };
  try {
    const compacted = compactVpnUri(url);
    if (compacted.startsWith('vpn://') || /^phobos:\/\//i.test(compacted)) {
      let text = compacted.startsWith('vpn://')
        ? decompressVpnUri(compacted)
        : '';
      if (compacted.startsWith('vpn://') && text == null) return invalid();
      if (text == null) text = '';
      const isPhobosUri = /^phobos:\/\//i.test(compacted);
      if (isPhobosUri) {
        const hashIdx = compacted.indexOf('#');
        const rawPayload = (
          hashIdx >= 0
            ? compacted.slice('phobos://'.length, hashIdx)
            : compacted.slice('phobos://'.length)
        )
          .trim()
          .replace(/^v1\./, '');
        if (!rawPayload) return invalid();
        let normB64 = rawPayload.replace(/-/g, '+').replace(/_/g, '/');
        while (normB64.length % 4) normB64 += '=';
        try {
          const decoded = atob(normB64);
          if (!decoded.toLowerCase().includes('[interface]')) return invalid();
          text = decoded;
        } catch (_e) {
          return invalid();
        }
      }
      if (text.length > MAX_AMNEZIA_SIZE || text.includes('\0')) {
        return invalid();
      }
      if (!isPhobosUri && text.trim().startsWith('{')) {
        let data = JSON.parse(text) as Record<string, unknown>;
        if (!Array.isArray(data.containers)) {
          if (
            (data.api_config != null ||
              data.auth_data != null ||
              data.api_key != null) &&
            !data.config &&
            !data.client_priv_key &&
            !data.private_key
          ) {
            return {
              valid: false,
              message: _(
                'This vpn:// key is an Amnezia Cloud API token without embedded WireGuard keys. Export a .conf file or full container config in the Amnezia app.',
              ),
            };
          }
          const wrapped = firstStr(
            [data],
            ['config', 'wg_config', 'awg_config'],
          );
          if (wrapped.startsWith('vpn://')) {
            const inner = decompressVpnUri(wrapped);
            if (inner == null) return invalid();
            if (!inner.trim().startsWith('{')) {
              text = finalizeConfText(inner, data, data, data);
              data = {};
            } else {
              data = JSON.parse(inner) as Record<string, unknown>;
            }
          }
          if (Object.keys(data).length > 0 && !Array.isArray(data.containers)) {
            if (
              typeof data.config === 'string' &&
              data.config.toLowerCase().includes('[interface]')
            ) {
              text = finalizeConfText(data.config, data, data, data);
            } else if (
              (data.client_priv_key || data.private_key) &&
              (data.server_pub_key || data.public_key)
            ) {
              return { valid: true, message: _('Valid') };
            } else {
              return invalid();
            }
          }
        }
        if (Array.isArray(data.containers)) {
          if (!data.containers.length || data.containers.length > 16)
            return invalid();
          const wgChoices: { kind: string; text: string; isAwg: boolean }[] =
            [];
          let hasValidProxyContainer = false;
          for (const rawContainer of data.containers) {
            if (!rawContainer || typeof rawContainer !== 'object')
              return invalid();
            const container = rawContainer as Record<string, unknown>;
            const kindRaw =
              typeof container.container === 'string'
                ? container.container.trim()
                : '';
            const kind = kindRaw.toLowerCase();
            let proto: 'awg' | 'wireguard' | 'proxy' | null =
              AWG_CONTAINER_KINDS.has(kind)
                ? 'awg'
                : WG_CONTAINER_KINDS.has(kind)
                  ? 'wireguard'
                  : PROXY_CONTAINER_KINDS.has(kind)
                    ? 'proxy'
                    : null;
            if (!proto && !kind) {
              if (
                container.awg ||
                container.awg2 ||
                container.awg3 ||
                container['amnezia-awg'] ||
                container['amnezia-awg2'] ||
                container['amnezia-awg3']
              ) {
                proto = 'awg';
              } else if (
                container.wireguard ||
                container.wg ||
                container['amnezia-wireguard']
              ) {
                proto = 'wireguard';
              } else if (
                container.xray ||
                container['amnezia-xray'] ||
                container.shadowsocks ||
                container['amnezia-shadowsocks']
              ) {
                proto = 'proxy';
              }
            }
            if (!proto) continue;

            if (proto === 'proxy') {
              let pSettings =
                container.xray ||
                container['amnezia-xray'] ||
                container['xray-reality'] ||
                container.ssxray ||
                container.shadowsocks ||
                container['amnezia-shadowsocks'] ||
                container.ss ||
                container[kindRaw] ||
                container[kind];
              if (typeof pSettings === 'string') {
                pSettings = JSON.parse(pSettings);
              }
              const pObj =
                pSettings && typeof pSettings === 'object'
                  ? (pSettings as Record<string, unknown>)
                  : null;
              const pLast = pObj?.last_config ?? pObj?.config;
              const pHost = firstStr([pObj, data], ['hostName', 'server']);
              const pStr =
                typeof pLast === 'string'
                  ? pLast.trim()
                  : pLast && typeof pLast === 'object'
                    ? JSON.stringify(pLast)
                    : '';
              if (pHost && pStr && pStr !== '{}') {
                hasValidProxyContainer = true;
              }
              continue;
            }

            let settings =
              container[proto] ||
              container.awg ||
              container.awg2 ||
              container.awg3 ||
              container['amnezia-awg'] ||
              container['amnezia-awg2'] ||
              container['amnezia-awg3'] ||
              container['amnezia-wireguard'] ||
              container[kindRaw] ||
              container[kind] ||
              container.params ||
              (container.last_config != null || container.config != null
                ? container
                : null);
            if (typeof settings === 'string') settings = JSON.parse(settings);
            const settingsObj =
              settings && typeof settings === 'object'
                ? (settings as Record<string, unknown>)
                : null;
            let last = settingsObj?.last_config ?? settingsObj?.config;
            if (
              typeof last === 'string' &&
              !last.trim().startsWith('{') &&
              last.toLowerCase().includes('[interface]')
            ) {
              wgChoices.push({
                kind,
                text: finalizeConfText(last, settingsObj, settingsObj, data),
                isAwg: proto === 'awg',
              });
              continue;
            }
            if (typeof last === 'string') {
              try {
                last = JSON.parse(last);
              } catch {
                last = null;
              }
            }
            const lastObj =
              last && typeof last === 'object'
                ? (last as Record<string, unknown>)
                : settingsObj;
            if (
              lastObj &&
              typeof lastObj.config === 'string' &&
              lastObj.config
            ) {
              wgChoices.push({
                kind,
                text: finalizeConfText(
                  lastObj.config,
                  lastObj,
                  settingsObj,
                  data,
                ),
                isAwg: proto === 'awg',
              });
            } else if (
              lastObj &&
              (lastObj.client_priv_key || lastObj.private_key) &&
              (lastObj.server_pub_key || lastObj.public_key)
            ) {
              return { valid: true, message: _('Valid') };
            }
          }
          const defLower =
            typeof data.defaultContainer === 'string'
              ? data.defaultContainer.trim().toLowerCase()
              : '';
          if (
            defLower &&
            !AWG_CONTAINER_KINDS.has(defLower) &&
            !WG_CONTAINER_KINDS.has(defLower) &&
            !PROXY_CONTAINER_KINDS.has(defLower)
          ) {
            return invalid();
          }
          if (!wgChoices.length) {
            return hasValidProxyContainer
              ? { valid: true, message: _('Valid') }
              : invalid();
          }
          const preferred = defLower
            ? wgChoices.filter((c) => c.kind === defLower)
            : [];
          if (preferred.length > 1) return invalid();
          const chosen =
            preferred[0] || wgChoices.find((c) => c.isAwg) || wgChoices[0];
          text = chosen.text;
          if (text.length > MAX_AMNEZIA_SIZE || text.includes('\0')) {
            return invalid();
          }
        }
      }

      let block: 'interface' | 'peer' | 'instance' | 'socks5' | '' = '';
      let interfaces = 0;
      const ifaceFields: Record<string, string> = {};
      const instanceFields: Record<string, string> = {};
      const peerList: Record<string, string>[] = [];
      let currentPeer: Record<string, string> | null = null;
      for (const raw of text.split('\n')) {
        const line = raw.trim();
        if (!line || line.startsWith('#') || line.startsWith(';')) continue;
        const lowerLine = line.toLowerCase();
        if (lowerLine === '[interface]') {
          block = 'interface';
          interfaces++;
          continue;
        }
        if (lowerLine === '[peer]') {
          block = 'peer';
          currentPeer = {};
          peerList.push(currentPeer);
          continue;
        }
        if (lowerLine === '[instance]' || lowerLine === '[client]') {
          block = 'instance';
          continue;
        }
        if (lowerLine === '[socks5]') {
          block = 'socks5';
          continue;
        }
        if (line.startsWith('[')) return invalid();
        const eq = line.indexOf('=');
        if (block && eq > 0) {
          const k = line.slice(0, eq).trim().toLowerCase();
          const v = line.slice(eq + 1).trim();
          if (
            (block === 'instance' || block === 'socks5') &&
            k === 'mode' &&
            v.toLowerCase() === 'socks5'
          ) {
            return invalid();
          }
          if (block === 'interface') {
            ifaceFields[k] = v;
          } else if (block === 'instance') {
            instanceFields[k] = v;
          } else if (block === 'peer' && currentPeer) {
            currentPeer[k] = v;
          }
        }
      }
      const privKey =
        ifaceFields.privatekey ||
        ifaceFields.private_key ||
        ifaceFields.client_priv_key;
      const addrVal =
        ifaceFields.address ||
        ifaceFields.local_address ||
        ifaceFields.ip ||
        ifaceFields.client_ip;
      const cleanVal = (v: string | undefined) =>
        v && v.toLowerCase() !== 'none' ? v : '';
      if (
        interfaces !== 1 ||
        peerList.length < 1 ||
        !key32(privKey) ||
        !cleanVal(addrVal)
      ) {
        return invalid();
      }
      const phobosTarget = cleanVal(instanceFields.target);
      for (const peerFields of peerList) {
        const pubKey =
          peerFields.publickey ||
          peerFields.public_key ||
          peerFields.peer_public_key ||
          peerFields.server_pub_key;
        const pskVal = cleanVal(
          peerFields.presharedkey ||
            peerFields.preshared_key ||
            peerFields.psk ||
            peerFields.psk_key,
        );
        const effEp = peerFields.endpoint || phobosTarget;
        const endpoint = (effEp || '').match(/^(\[[^\]]+\]|[^:\s]+):(\d+)$/);
        if (
          !key32(pubKey) ||
          !endpoint ||
          Number(endpoint[2]) < 1 ||
          Number(endpoint[2]) > 65535 ||
          (pskVal && !key32(pskVal))
        ) {
          return invalid();
        }
      }
    }
    // The backend validates AWG fields and core compatibility before apply.
    return { valid: true, message: _('Valid') };
  } catch (_e) {
    return invalid();
  }
}
