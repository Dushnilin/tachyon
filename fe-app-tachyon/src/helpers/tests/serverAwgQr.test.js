import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';
import { parse } from '@babel/parser';
import { describe, expect, it } from 'vitest';
import { validateVpnUrl } from '../../validators/validateVpnUrl';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const serverTsPath = path.resolve(testDir, '../../views/server.ts');

function loadServerHelpers(values) {
  const source = fs.readFileSync(serverTsPath, 'utf8');
  const requiredFunctions = [
    'encodeQuery',
    'normalizeHost',
    'isIpv4',
    'isIpv6',
    'formatHostForUri',
    'getServerName',
    'getServerPort',
    'getPublicHost',
    'qrGetBit',
    'qrAppendBits',
    'qrRawDataModules',
    'qrRawCodewords',
    'qrDataCodewords',
    'qrEncodeText',
    'qrBuildDataCodewords',
    'qrMultiply',
    'qrReedSolomonDivisor',
    'qrReedSolomonRemainder',
    'qrAddErrorCorrection',
    'qrAlignmentPatternPositions',
    'qrMaskBit',
    'qrScoreLine',
    'qrPenaltyScore',
    'qrMakeMatrix',
    'qrSvgDataUri',
    'deflateFixedHuffman',
    'zlibCompressQt',
    'buildAwgClientConfig',
    'buildAwgAmneziaVpnUri',
  ];

  const constDecls = [
    'QR_EC_CODEWORDS_PER_BLOCK_LOW',
    'QR_NUM_ERROR_CORRECTION_BLOCKS_LOW',
    'DEFLATE_LEN_BASE',
    'DEFLATE_LEN_EXTRA',
    'DEFLATE_DIST_BASE',
    'DEFLATE_DIST_EXTRA',
  ];

  const ast = parse(source, {
    allowReturnOutsideFunction: true,
    sourceType: 'module',
    plugins: ['typescript'],
  });

  const functionSources = new Map();
  const constSources = new Map();

  for (const node of ast.program.body) {
    if (node.type === 'FunctionDeclaration' && node.id) {
      functionSources.set(node.id.name, source.slice(node.start, node.end));
    } else if (node.type === 'VariableDeclaration') {
      for (const decl of node.declarations) {
        if (
          decl.id.type === 'Identifier' &&
          constDecls.includes(decl.id.name)
        ) {
          constSources.set(decl.id.name, source.slice(node.start, node.end));
        }
      }
    }
  }

  const code = [
    ...constDecls.map((name) => {
      const s = constSources.get(name);
      if (!s) throw new Error(`Const ${name} not found`);
      return s;
    }),
    ...requiredFunctions.map((name) => {
      const s = functionSources.get(name);
      if (!s) throw new Error(`Function ${name} not found`);
      return s;
    }),
  ].join('\n');

  const uci = {
    get(_pkg, sectionId, optionName) {
      return values[`${sectionId}.${optionName}`] || '';
    },
  };

  const factory = new Function(
    'uci',
    'UCI_PACKAGE',
    'window',
    `${code}; return { qrEncodeText, qrDataCodewords, qrBuildDataCodewords, qrMakeMatrix, qrPenaltyScore, qrSvgDataUri, zlibCompressQt, buildAwgClientConfig, buildAwgAmneziaVpnUri };`,
  );

  return factory(uci, 'tachyon', { location: { hostname: '198.51.100.10' } });
}

describe('server AWG QR & AmneziaVPN encoder', () => {
  it('selects the minimum-penalty ISO 18004 mask across 0..7 and matches format bits', () => {
    const h = loadServerHelpers({});
    const sample = `[Interface]
Address = 10.8.0.2/32
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
DNS = 10.8.0.1
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 15
S2 = 25
H1 = 184920412
H2 = 492019482
H3 = 829401928
H4 = 392019481

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 198.51.100.10:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
`;
    const bytes = h.qrEncodeText(sample);
    let version = 1;
    for (; version <= 40; version += 1) {
      const countBits = version <= 9 ? 8 : 16;
      if (4 + countBits + bytes.length * 8 <= h.qrDataCodewords(version) * 8) {
        break;
      }
    }
    const codewords = h.qrBuildDataCodewords(bytes, version);
    const matrix = h.qrMakeMatrix(version, codewords);

    const size = version * 4 + 17;
    expect(matrix.length).toBe(size);
    expect(matrix.every((row) => row.length === size)).toBe(true);

    let rawFormat = 0;
    const coords = [
      [8, 0],
      [8, 1],
      [8, 2],
      [8, 3],
      [8, 4],
      [8, 5],
      [8, 7],
      [8, 8],
      [7, 8],
      [5, 8],
      [4, 8],
      [3, 8],
      [2, 8],
      [1, 8],
      [0, 8],
    ];
    for (let i = 0; i < coords.length; i += 1) {
      const [x, y] = coords[i];
      if (matrix[y][x]) {
        rawFormat |= 1 << i;
      }
    }
    const unmasked = rawFormat ^ 0x5412;
    const ecBits = (unmasked >>> 13) & 0x3;
    const maskId = (unmasked >>> 10) & 0x7;
    expect(ecBits).toBe(1);
    expect(maskId).toBeGreaterThanOrEqual(0);
    expect(maskId).toBeLessThanOrEqual(7);
  });

  it('renders SVG QR without crispEdges and faithfully encodes all merged dark runs', () => {
    const h = loadServerHelpers({});
    const payload = 'awg://test-payload-1234567890-abcdef';
    const dataUri = h.qrSvgDataUri(payload);
    expect(dataUri.startsWith('data:image/svg+xml,')).toBe(true);

    const svg = decodeURIComponent(dataUri.slice('data:image/svg+xml,'.length));
    expect(svg).not.toContain('shape-rendering="crispEdges"');
    expect(svg).not.toContain('crispEdges');

    const vbMatch = svg.match(/viewBox="0 0 (\d+) (\d+)"/);
    expect(vbMatch).not.toBeNull();
    const viewSize = Number(vbMatch[1]);
    const border = 4;
    const size = viewSize - border * 2;

    const pathMatch = svg.match(/<path fill="#000" d="([^"]+)"/);
    expect(pathMatch).not.toBeNull();
    const cmds = pathMatch[1].split(' ');
    expect(cmds.some((c) => /h7v1h-7z$/.test(c))).toBe(true);

    const decoded = Array.from({ length: size }, () => Array(size).fill(false));
    for (const cmd of cmds) {
      const m = cmd.match(/^M(\d+),(\d+)h(\d+)v1h-(\d+)z$/);
      expect(m).not.toBeNull();
      const x0 = Number(m[1]) - border;
      const y0 = Number(m[2]) - border;
      const w = Number(m[3]);
      expect(w).toBe(Number(m[4]));
      for (let dx = 0; dx < w; dx += 1) {
        decoded[y0][x0 + dx] = true;
      }
    }

    const bytes = h.qrEncodeText(payload);
    let version = 1;
    for (; version <= 40; version += 1) {
      const countBits = version <= 9 ? 8 : 16;
      if (4 + countBits + bytes.length * 8 <= h.qrDataCodewords(version) * 8) {
        break;
      }
    }
    const expected = h.qrMakeMatrix(
      version,
      h.qrBuildDataCodewords(bytes, version),
    );
    expect(decoded).toEqual(expected);
  });

  it('refuses awg_peer_public_key fallback in buildAwgClientConfig', () => {
    const missingServerKey = loadServerHelpers({
      'awg1.public_host': '198.51.100.10',
      'awg1.listen_port': '51820',
      'awg1.awg_client_private_key':
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      'awg1.awg_peer_public_key':
        'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
    });
    expect(missingServerKey.buildAwgClientConfig('awg1', '2.0')).toBe('');

    const valid = loadServerHelpers({
      'awg1.public_host': '198.51.100.10',
      'awg1.listen_port': '51820',
      'awg1.awg_client_private_key':
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      'awg1.awg_server_public_key':
        'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=',
      'awg1.awg_peer_public_key':
        'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
    });
    const conf = valid.buildAwgClientConfig('awg1', '2.0');
    expect(conf).toContain(
      'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    );
    expect(conf).toContain(
      'PublicKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=',
    );
    expect(conf).not.toContain('BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=');
  });

  it('compresses zlib Qt streams losslessly (both repetitive JSON and stored fallback) and emits valid AmneziaVPN vpn:// URI', () => {
    const h = loadServerHelpers({
      'awg1.label': 'Router AWG',
      'awg1.public_host': '198.51.100.10',
      'awg1.listen_port': '51820',
      'awg1.awg_client_private_key':
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      'awg1.awg_server_public_key':
        'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=',
      'awg1.awg_client_address': '10.8.0.2/32',
      'awg1.awg_dns': '10.8.0.1, 1.1.1.1',
      'awg1.awg_s1': '15',
      'awg1.awg_s2': '25',
      'awg1.awg_h1': '111111',
      'awg1.awg_h2': '222222',
      'awg1.awg_h3': '333333',
      'awg1.awg_h4': '444444',
    });

    const rawRandom = new Uint8Array(64);
    for (let i = 0; i < rawRandom.length; i += 1) {
      rawRandom[i] = (i * 179 + 37) & 0xff;
    }
    const qtRandom = h.zlibCompressQt(rawRandom);
    expect(Buffer.from(qtRandom.subarray(0, 4)).readUInt32BE(0)).toBe(
      rawRandom.length,
    );
    expect(Buffer.from(zlib.inflateSync(qtRandom.subarray(4)))).toEqual(
      Buffer.from(rawRandom),
    );

    const vpnUri = h.buildAwgAmneziaVpnUri('awg1', '2.0');
    expect(vpnUri.startsWith('vpn://')).toBe(true);

    let b64 = vpnUri
      .slice('vpn://'.length)
      .replace(/-/g, '+')
      .replace(/_/g, '/');
    while (b64.length % 4) b64 += '=';
    const rawBytes = Buffer.from(b64, 'base64');
    const declaredLen = rawBytes.readUInt32BE(0);
    const inflatedJson = zlib
      .inflateSync(rawBytes.subarray(4))
      .toString('utf8');
    expect(Buffer.byteLength(inflatedJson, 'utf8')).toBe(declaredLen);

    const parsed = JSON.parse(inflatedJson);
    expect(parsed.defaultContainer).toBe('amnezia-awg');
    expect(parsed.hostName).toBe('198.51.100.10');
    expect(parsed.description).toBe('Router AWG');
    expect(parsed.dns1).toBe('10.8.0.1');
    expect(parsed.dns2).toBe('1.1.1.1');
    expect(parsed.containers[0].container).toBe('amnezia-awg');
    expect(parsed.containers[0].awg.S1).toBe('15');
    expect(parsed.containers[0].awg.S2).toBe('25');

    const lastCfg = JSON.parse(parsed.containers[0].awg.last_config);
    expect(lastCfg.server_pub_key).toBe(
      'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=',
    );
    expect(lastCfg.config).toContain('[Interface]');

    const check = validateVpnUrl(vpnUri);
    expect(check.valid).toBe(true);
  });
});
