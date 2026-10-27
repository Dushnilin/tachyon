"use strict";
"require form";
"require baseclass";
"require dom";
"require fs";
"require rpc";
"require uci";
"require ui";
"require view.tachyon.main as main";

const UCI_PACKAGE = main.TACHYON_UCI_PACKAGE;
const ROUTING_SECTION_ACTIONS = [
  "connection",
  "proxy",
  "outbound",
  "vpn",
  "byedpi",
  "zapret",
  "zapret2",
];
const callNetworkInterfaceDump = rpc.declare({
  object: "network.interface",
  method: "dump",
  expect: { interface: [] },
});
let defaultPublicHostPromise = null;
let defaultPublicHostCache = null;
let routerNetworkEnvPromise = null;
let routerNetworkEnvCache = null;

function fetchRouterNetworkEnv() {
  if (routerNetworkEnvCache != null) {
    return Promise.resolve(routerNetworkEnvCache);
  }
  if (routerNetworkEnvPromise) {
    return routerNetworkEnvPromise;
  }
  routerNetworkEnvPromise = fs
    .exec("/usr/bin/tachyon", ["get_router_network_env"])
    .then((res) => {
      if (res && res.code === 0 && res.stdout) {
        try {
          routerNetworkEnvCache = JSON.parse(res.stdout);
          return routerNetworkEnvCache;
        } catch (e) {}
      }
      return null;
    })
    .catch(() => null)
    .finally(() => {
      routerNetworkEnvPromise = null;
    });
  return routerNetworkEnvPromise;
}

function asList(value) {
  if (!value) {
    return [];
  }

  return Array.isArray(value) ? value.filter(Boolean) : [`${value}`];
}

const QR_EC_CODEWORDS_PER_BLOCK_LOW = [
  -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28,
  28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
  30, 30,
];
const QR_NUM_ERROR_CORRECTION_BLOCKS_LOW = [
  -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10,
  12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
];

function qrGetBit(value, index) {
  return ((value >>> index) & 1) !== 0;
}

function qrAppendBits(buffer, value, length) {
  for (let i = length - 1; i >= 0; i -= 1) {
    buffer.push(qrGetBit(value, i));
  }
}

function qrRawDataModules(version) {
  let result = (16 * version + 128) * version + 64;

  if (version >= 2) {
    const numAlign = Math.floor(version / 7) + 2;
    result -= (25 * numAlign - 10) * numAlign - 55;
    if (version >= 7) {
      result -= 36;
    }
  }

  return result;
}

function qrRawCodewords(version) {
  return Math.floor(qrRawDataModules(version) / 8);
}

function qrDataCodewords(version) {
  return (
    qrRawCodewords(version) -
    QR_EC_CODEWORDS_PER_BLOCK_LOW[version] *
      QR_NUM_ERROR_CORRECTION_BLOCKS_LOW[version]
  );
}

function qrEncodeText(text) {
  return Array.from(new TextEncoder().encode(text));
}

function qrBuildDataCodewords(bytes, version) {
  const capacity = qrDataCodewords(version);
  const bits = [];
  const countBits = version <= 9 ? 8 : 16;

  qrAppendBits(bits, 4, 4);
  qrAppendBits(bits, bytes.length, countBits);
  bytes.forEach((value) => qrAppendBits(bits, value, 8));
  qrAppendBits(bits, 0, Math.min(4, capacity * 8 - bits.length));

  while (bits.length % 8 !== 0) {
    bits.push(false);
  }

  const result = [];
  for (let i = 0; i < bits.length; i += 8) {
    let value = 0;
    for (let j = 0; j < 8; j += 1) {
      value = (value << 1) | (bits[i + j] ? 1 : 0);
    }
    result.push(value);
  }

  for (let pad = 0xec; result.length < capacity; pad ^= 0xfd) {
    result.push(pad);
  }

  return result;
}

function qrMultiply(x, y) {
  let z = 0;

  for (let i = 7; i >= 0; i -= 1) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }

  return z;
}

function qrReedSolomonDivisor(degree) {
  const result = Array(degree).fill(0);
  result[degree - 1] = 1;

  let root = 1;
  for (let i = 0; i < degree; i += 1) {
    for (let j = 0; j < degree; j += 1) {
      result[j] = qrMultiply(result[j], root);
      if (j + 1 < degree) {
        result[j] ^= result[j + 1];
      }
    }
    root = qrMultiply(root, 2);
  }

  return result;
}

function qrReedSolomonRemainder(data, divisor) {
  const result = Array(divisor.length).fill(0);

  data.forEach((value) => {
    const factor = value ^ result.shift();
    result.push(0);
    for (let i = 0; i < result.length; i += 1) {
      result[i] ^= qrMultiply(divisor[i], factor);
    }
  });

  return result;
}

function qrAddErrorCorrection(data, version) {
  const numBlocks = QR_NUM_ERROR_CORRECTION_BLOCKS_LOW[version];
  const blockEccLen = QR_EC_CODEWORDS_PER_BLOCK_LOW[version];
  const rawCodewords = qrRawCodewords(version);
  const numShortBlocks = numBlocks - (rawCodewords % numBlocks);
  const shortBlockDataLen = Math.floor(rawCodewords / numBlocks) - blockEccLen;
  const divisor = qrReedSolomonDivisor(blockEccLen);
  const blocks = [];

  for (let i = 0, offset = 0; i < numBlocks; i += 1) {
    const dataLen = shortBlockDataLen + (i < numShortBlocks ? 0 : 1);
    const blockData = data.slice(offset, offset + dataLen);
    offset += dataLen;
    blocks.push({
      data: blockData,
      ecc: qrReedSolomonRemainder(blockData, divisor),
    });
  }

  const result = [];
  const maxDataLen = Math.max(...blocks.map((block) => block.data.length));

  for (let i = 0; i < maxDataLen; i += 1) {
    blocks.forEach((block) => {
      if (i < block.data.length) {
        result.push(block.data[i]);
      }
    });
  }

  for (let i = 0; i < blockEccLen; i += 1) {
    blocks.forEach((block) => result.push(block.ecc[i]));
  }

  return result;
}

function qrAlignmentPatternPositions(version) {
  if (version === 1) {
    return [];
  }

  const size = version * 4 + 17;
  const numAlign = Math.floor(version / 7) + 2;
  const step =
    version === 32 ? 26 : Math.ceil((version * 4 + 4) / (numAlign * 2 - 2)) * 2;
  const result = [6];

  for (let pos = size - 7; result.length < numAlign; pos -= step) {
    result.splice(1, 0, pos);
  }

  return result;
}

function qrMakeMatrix(version, dataCodewords) {
  const size = version * 4 + 17;
  const modules = Array.from({ length: size }, () => Array(size).fill(false));
  const isFunction = Array.from({ length: size }, () =>
    Array(size).fill(false),
  );

  function setFunction(x, y, dark) {
    modules[y][x] = dark;
    isFunction[y][x] = true;
  }

  function drawFinder(cx, cy) {
    for (let dy = -4; dy <= 4; dy += 1) {
      for (let dx = -4; dx <= 4; dx += 1) {
        const x = cx + dx;
        const y = cy + dy;
        if (x < 0 || x >= size || y < 0 || y >= size) {
          continue;
        }
        const dist = Math.max(Math.abs(dx), Math.abs(dy));
        setFunction(x, y, dist !== 2 && dist !== 4);
      }
    }
  }

  function drawAlignment(cx, cy) {
    for (let dy = -2; dy <= 2; dy += 1) {
      for (let dx = -2; dx <= 2; dx += 1) {
        setFunction(
          cx + dx,
          cy + dy,
          Math.max(Math.abs(dx), Math.abs(dy)) !== 1,
        );
      }
    }
  }

  drawFinder(3, 3);
  drawFinder(size - 4, 3);
  drawFinder(3, size - 4);

  for (let i = 8; i < size - 8; i += 1) {
    setFunction(6, i, i % 2 === 0);
    setFunction(i, 6, i % 2 === 0);
  }

  const alignPositions = qrAlignmentPatternPositions(version);
  alignPositions.forEach((x) => {
    alignPositions.forEach((y) => {
      const overlapsFinder =
        (x === 6 && y === 6) ||
        (x === 6 && y === size - 7) ||
        (x === size - 7 && y === 6);
      if (!overlapsFinder) {
        drawAlignment(x, y);
      }
    });
  });

  if (version >= 7) {
    let rem = version;
    for (let i = 0; i < 12; i += 1) {
      rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    }
    const bits = (version << 12) | rem;
    for (let i = 0; i < 18; i += 1) {
      const bit = qrGetBit(bits, i);
      const a = size - 11 + (i % 3);
      const b = Math.floor(i / 3);
      setFunction(a, b, bit);
      setFunction(b, a, bit);
    }
  }

  function drawFormatBits(mask) {
    const formatData = (1 << 3) | mask;
    let rem = formatData;

    for (let i = 0; i < 10; i += 1) {
      rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    }

    const formatBits = ((formatData << 10) | rem) ^ 0x5412;

    for (let i = 0; i <= 5; i += 1) {
      setFunction(8, i, qrGetBit(formatBits, i));
    }
    setFunction(8, 7, qrGetBit(formatBits, 6));
    setFunction(8, 8, qrGetBit(formatBits, 7));
    setFunction(7, 8, qrGetBit(formatBits, 8));
    for (let i = 9; i < 15; i += 1) {
      setFunction(14 - i, 8, qrGetBit(formatBits, i));
    }
    for (let i = 0; i < 8; i += 1) {
      setFunction(size - 1 - i, 8, qrGetBit(formatBits, i));
    }
    for (let i = 8; i < 15; i += 1) {
      setFunction(8, size - 15 + i, qrGetBit(formatBits, i));
    }
    setFunction(8, size - 8, true);
  }

  drawFormatBits(0);

  const codewords = qrAddErrorCorrection(dataCodewords, version);
  let bitIndex = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) {
      right = 5;
    }
    for (let vert = 0; vert < size; vert += 1) {
      for (let j = 0; j < 2; j += 1) {
        const x = right - j;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? size - 1 - vert : vert;
        if (!isFunction[y][x] && bitIndex < codewords.length * 8) {
          modules[y][x] = qrGetBit(
            codewords[Math.floor(bitIndex / 8)],
            7 - (bitIndex % 8),
          );
          bitIndex += 1;
        }
      }
    }
  }

  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      if (!isFunction[y][x] && (x + y) % 2 === 0) {
        modules[y][x] = !modules[y][x];
      }
    }
  }

  drawFormatBits(0);

  return modules;
}

function qrSvgDataUri(text) {
  const bytes = qrEncodeText(text);
  let version = 1;

  for (; version <= 40; version += 1) {
    const countBits = version <= 9 ? 8 : 16;
    if (4 + countBits + bytes.length * 8 <= qrDataCodewords(version) * 8) {
      break;
    }
  }

  if (version > 40) {
    return "";
  }

  const matrix = qrMakeMatrix(version, qrBuildDataCodewords(bytes, version));
  const border = 4;
  const size = matrix.length;
  const viewSize = size + border * 2;
  const path = [];

  matrix.forEach((row, y) => {
    row.forEach((dark, x) => {
      if (dark) {
        path.push(`M${x + border},${y + border}h1v1h-1z`);
      }
    });
  });

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${viewSize} ${viewSize}" shape-rendering="crispEdges"><path fill="#fff" d="M0 0h${viewSize}v${viewSize}H0z"/><path fill="#000" d="${path.join(" ")}"/></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const SERVER_STYLE_ID = "tachyon-server-styles";
const DEFAULT_SERVER_PROTOCOL = "tailscale";
const FALLBACK_SERVER_PROTOCOL = "vless";
const STREAM_PROTOCOLS = ["vless", "vmess", "trojan"];
const PORT_PROTOCOLS = [
  "shadowsocks",
  "socks",
  "vmess",
  "vless",
  "trojan",
  "hysteria2",
  "awg",
  "tuic",
  "anytls",
  "naive",
  "shadowtls",
  "fptn",
  "http",
  "mixed",
  "mieru",
  "trusttunnel",
  "tewfai",
  "masque",
  "openconnect",
];
const EXTENDED_PORT_PROTOCOLS = ["mtproto"];
const PASSWORD_PROTOCOLS = [
  "shadowsocks",
  "socks",
  "trojan",
  "hysteria2",
  "tuic",
  "anytls",
  "naive",
  "shadowtls",
  "fptn",
  "http",
  "mixed",
  "mieru",
  "trusttunnel",
  "masque",
];

const BASE_PROTOCOL_LABELS = {
  vless: "VLESS",
  shadowsocks: "Shadowsocks",
  socks: "SOCKS",
  vmess: "VMess",
  trojan: "Trojan",
  hysteria2: "Hysteria2",
  awg: "AmneziaWG",
};
const CORE_SERVER_PROTOCOL_LABELS = {
  tuic: "TUIC",
  anytls: "AnyTLS",
  naive: "NaiveProxy",
  shadowtls: "ShadowTLS",
  fptn: "FPTN",
  http: "HTTP",
  mixed: "Mixed (SOCKS/HTTP)",
  mieru: "Mieru",
  trusttunnel: "TrustTunnel",
  tewfai: "TewFai",
  masque: "MASQUE",
  openconnect: "OpenConnect",
};
const EXTENDED_PROTOCOL_LABELS = {
  mtproto: "MTProto",
};
const CUSTOM_PROTOCOL_LABELS = {
  json_inbound: "JSON Inbound",
};
const TAILSCALE_PROTOCOL_LABELS = {
  tailscale: "Tailscale",
};
const PROTOCOL_LABELS = {
  ...BASE_PROTOCOL_LABELS,
  ...CORE_SERVER_PROTOCOL_LABELS,
  ...EXTENDED_PROTOCOL_LABELS,
  ...CUSTOM_PROTOCOL_LABELS,
  ...TAILSCALE_PROTOCOL_LABELS,
};

const SECURITY_BY_PROTOCOL = {
  vless: ["reality", "tls", "none"],
  vmess: ["tls", "none"],
  trojan: ["tls", "none"],
  hysteria2: ["tls"],
  shadowsocks: ["none"],
  socks: ["none"],
  mtproto: ["none"],
  tailscale: ["none"],
  json_inbound: ["none"],
  awg: ["none"],
  tuic: ["tls"],
  anytls: ["tls"],
  naive: ["tls"],
  shadowtls: ["none"],
  fptn: ["tls"],
  http: ["none"],
  mixed: ["none"],
  mieru: ["none"],
  trusttunnel: ["tls"],
  tewfai: ["tls"],
  masque: ["tls"],
  openconnect: ["tls"],
};

function getSecurityLabel(security) {
  if (security === "reality") {
    return "Reality";
  }
  if (security === "tls") {
    return "TLS";
  }
  return _("None");
}

function injectServerStyles() {
  if (document.getElementById(SERVER_STYLE_ID)) {
    return;
  }

  document.head.appendChild(
    E(
      "style",
      { id: SERVER_STYLE_ID },
      `
.fkp-server-icon-button{box-sizing:border-box;vertical-align:middle;cursor:pointer}
.fkp-server-icon-button__glyph{display:inline-block;line-height:1;transform:scale(1.55);transform-origin:center;pointer-events:none}
.fkp-server-icon-button--done{outline:2px solid var(--success-color,#37a969);outline-offset:1px}
.fkp-server-validation-summary{margin:0 0 12px}
#cbi-${UCI_PACKAGE}-server > h3:nth-child(1){display:none}
#cbi-${UCI_PACKAGE}-server > .cbi-section-remove{margin-bottom:-32px}
#cbi-${UCI_PACKAGE}-server .cbi-section-actions > div{display:inline-flex;align-items:center;gap:4px}
#cbi-${UCI_PACKAGE}-server .cbi-section-actions{text-align:right}

.fkp-server-info-dialog,
.modal.fkp-server-info-dialog,
#modal_overlay > .modal.fkp-server-info-dialog{max-width:95vw !important;width:min(94vw, 880px) !important;box-sizing:border-box !important}
.fkp-server-info-modal{display:flex;flex-direction:column;gap:16px;width:100% !important;max-width:100% !important;box-sizing:border-box !important;margin:0 !important;overflow-x:hidden}
.fkp-server-info-modal__container{display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start;width:100% !important;max-width:100% !important;box-sizing:border-box !important}
.fkp-server-info-modal__qr-col{display:flex;flex-direction:column;align-items:center;gap:10px;flex:0 0 176px;max-width:100%;box-sizing:border-box}
.fkp-server-info-modal__qr-card{background:#ffffff;padding:8px;border-radius:12px;box-shadow:0 3px 12px rgba(0,0,0,0.12);border:1px solid rgba(128,128,128,0.18);display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box}
.fkp-server-info-modal__qr-image{width:160px;height:160px;max-width:min(180px, 60vw);display:block;image-rendering:pixelated}
.fkp-server-info-modal__qr-hint{font-size:11px;opacity:0.7;text-align:center;line-height:1.3;margin:0;font-weight:500}
.fkp-server-info-modal__details-col{display:flex;flex-direction:column;gap:14px;flex:1 1 0;min-width:0;max-width:100%;box-sizing:border-box !important;overflow:hidden}
.fkp-server-info-modal__details-grid{display:flex;flex-direction:column;gap:10px;background:rgba(128,128,128,0.06);padding:14px 16px;border:1px solid rgba(128,128,128,0.16);box-sizing:border-box !important;border-radius:8px;width:100% !important;max-width:100% !important}
.fkp-server-info-modal__detail-item{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;width:100% !important;max-width:100% !important;box-sizing:border-box}
.fkp-server-info-modal__detail-label{font-size:11px;opacity:0.65;text-transform:uppercase;letter-spacing:0.05em;font-weight:700;flex:0 0 auto}
.fkp-server-info-modal__detail-value{font-size:13px;font-weight:500;text-align:right;max-width:100%;overflow-wrap:anywhere;word-break:break-word}
.fkp-server-info-modal__detail-value--title{font-weight:600;font-size:14px}
.fkp-server-info-modal__detail-value--mono{font-family:var(--font-mono,monospace);font-size:12px;background:rgba(128,128,128,0.12);padding:2px 8px;border-radius:6px;border:1px solid rgba(128,128,128,0.15);word-break:break-all;overflow-wrap:anywhere;box-sizing:border-box}
.fkp-server-info-modal__badge{display:inline-flex;align-items:center;padding:3px 10px;font-size:11px;font-weight:600;border-radius:6px;border:1px solid var(--border-color,rgba(128,128,128,0.25));background:rgba(128,128,128,0.1);line-height:1.25;box-sizing:border-box}
.fkp-server-info-modal__warning{display:flex;align-items:flex-start;gap:8px;padding:10px 14px;border-radius:8px;background:rgba(234,179,8,0.1);border:1px solid rgba(234,179,8,0.3);color:var(--warning-color,#eab308);font-size:12px;line-height:1.45;box-sizing:border-box;margin:0 0 6px 0;max-width:100%;overflow-wrap:anywhere}
.fkp-server-info-modal__link-section{display:flex;flex-direction:column;gap:8px;box-sizing:border-box !important;width:100% !important;max-width:100% !important;min-width:0}
.fkp-server-info-modal__link{width:100% !important;max-width:100% !important;font-family:var(--font-mono,monospace);font-size:11px;padding:10px 12px;resize:vertical;min-height:64px;box-sizing:border-box !important;margin:0 !important;line-height:1.45;word-break:break-all;overflow-wrap:anywhere;white-space:pre-wrap;float:none !important;position:static !important;border-radius:6px !important;border:1px solid rgba(128,128,128,0.2) !important;background-color:rgba(128,128,128,0.05) !important;overflow-x:hidden !important}
.fkp-server-info-modal__copy-btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;align-self:flex-start;padding:4px 12px !important;font-size:12px !important;height:auto !important;min-height:28px !important;border-radius:6px !important;float:none !important;position:static !important;margin:0 !important;cursor:pointer}

@media (max-width:640px){
.fkp-server-info-modal{width:100% !important}
.fkp-server-info-modal__container{flex-direction:column;align-items:center;gap:18px}
.fkp-server-info-modal__qr-col{width:100%;max-width:180px;align-items:center}
.fkp-server-info-modal__details-col{width:100% !important;min-width:0}
.fkp-server-info-modal__details-grid{padding:12px}
.fkp-server-info-modal__detail-item{flex-wrap:wrap;gap:4px 8px}
}
`,
    ),
  );
}

function getFirstListValue(sectionId, option) {
  return asList(uci.get(UCI_PACKAGE, sectionId, option))[0] || "";
}

function getProtocol(sectionId) {
  return uci.get(UCI_PACKAGE, sectionId, "protocol") || DEFAULT_SERVER_PROTOCOL;
}

function getProtocolLabel(protocol) {
  return PROTOCOL_LABELS[protocol] || protocol || "";
}

function resetOptionValues(option) {
  option.keylist = [];
  option.vallist = [];
}

function addOptionValue(option, value, label) {
  if (option.keylist && option.keylist.indexOf(value) >= 0) {
    return;
  }

  option.value(value, label);
}

function normalizeServerCapabilities(capabilities) {
  const singBoxExtended = Boolean(capabilities?.singBoxExtended);
  const singBoxTachyonCore = Boolean(capabilities?.singBoxTachyonCore);

  return {
    singBoxExtended,
    singBoxTachyonCore,
    singBoxTailscale: capabilities?.singBoxTailscale !== false,
    // Server-side (inbound) XHTTP is only implemented in tachyon-core;
    // sing-box-lx and sing-box-extended only include v2rayxhttp.Client
    // (outbound) and fail `sing-box check` with
    // `create server transport: xhttp: unknown transport type: xhttp`.
    singBoxXhttp: singBoxTachyonCore,
  };
}

function getDefaultProtocolForCapabilities(capabilities) {
  return normalizeServerCapabilities(capabilities).singBoxTailscale
    ? DEFAULT_SERVER_PROTOCOL
    : FALLBACK_SERVER_PROTOCOL;
}

function populateProtocolValues(option, capabilities) {
  const normalized = normalizeServerCapabilities(capabilities);

  resetOptionValues(option);

  // Tailscale is offered unconditionally: the native tailscaled mode does not
  // depend on the sing-box build, only on the installable Tailscale component.
  Object.entries(TAILSCALE_PROTOCOL_LABELS).forEach(([value, label]) => {
    addOptionValue(option, value, label);
  });

  Object.entries(BASE_PROTOCOL_LABELS).forEach(([value, label]) => {
    addOptionValue(option, value, label);
  });

  if (normalized.singBoxExtended || normalized.singBoxTachyonCore) {
    Object.entries(CORE_SERVER_PROTOCOL_LABELS).forEach(([value, label]) => {
      addOptionValue(option, value, label);
    });
  } else {
    addOptionValue(option, "tuic", "TUIC");
    addOptionValue(option, "shadowtls", "ShadowTLS");
    addOptionValue(option, "http", "HTTP");
    addOptionValue(option, "mixed", "Mixed (SOCKS/HTTP)");
  }

  if (normalized.singBoxExtended) {
    Object.entries(EXTENDED_PROTOCOL_LABELS).forEach(([value, label]) => {
      addOptionValue(option, value, label);
    });
  }

  Object.entries(CUSTOM_PROTOCOL_LABELS).forEach(([value, label]) => {
    addOptionValue(option, value, label);
  });
}

function populateTransportValues(option, supportsXhttp) {
  resetOptionValues(option);

  addOptionValue(option, "tcp", "TCP");
  addOptionValue(option, "ws", "WebSocket");
  addOptionValue(option, "grpc", "gRPC");
  addOptionValue(option, "http", "HTTP");
  addOptionValue(option, "httpupgrade", "HTTPUpgrade");

  if (supportsXhttp) {
    addOptionValue(option, "xhttp", "XHTTP");
  }
}

function applyServerCapabilities(sectionRef, capabilities) {
  const options = sectionRef.serverCapabilityOptions;
  const normalized = normalizeServerCapabilities(capabilities);

  sectionRef.serverCapabilities = normalized;

  if (!options) {
    return;
  }

  if (options.protocol) {
    populateProtocolValues(options.protocol, normalized);
    options.protocol.default = getDefaultProtocolForCapabilities(normalized);
  }

  if (options.transport) {
    populateTransportValues(options.transport, normalized.singBoxXhttp);
  }
}

function getServerName(sectionId) {
  return (
    uci.get(UCI_PACKAGE, sectionId, "label") ||
    uci.get(UCI_PACKAGE, sectionId, "name") ||
    sectionId
  );
}

function getSocksUsername(sectionId) {
  return (
    uci.get(UCI_PACKAGE, sectionId, "server_username") ||
    getServerName(sectionId) ||
    sectionId
  );
}

function isSocksAuthenticationEnabled(sectionId) {
  const value = `${
    uci.get(UCI_PACKAGE, sectionId, "socks_auth_enabled") ?? "1"
  }`.toLowerCase();

  return !["0", "false", "no", "off"].includes(value);
}

function getDefaultSecurity(protocol) {
  if (protocol === "vless") {
    return "reality";
  }
  if (
    protocol === "trojan" ||
    protocol === "hysteria2" ||
    protocol === "tuic" ||
    protocol === "anytls" ||
    protocol === "naive" ||
    protocol === "fptn" ||
    protocol === "trusttunnel" ||
    protocol === "tewfai" ||
    protocol === "masque" ||
    protocol === "openconnect"
  ) {
    return "tls";
  }
  return "none";
}

function normalizeVlessFlow(flow) {
  return flow === "xtls-rprx-vision" ? flow : "";
}

function getEffectiveSecurity(sectionId) {
  const protocol = getProtocol(sectionId);
  const security = uci.get(UCI_PACKAGE, sectionId, "security");

  if (
    protocol === "shadowsocks" ||
    protocol === "socks" ||
    protocol === "mtproto" ||
    protocol === "tailscale" ||
    protocol === "json_inbound" ||
    protocol === "awg" ||
    protocol === "shadowtls" ||
    protocol === "http" ||
    protocol === "mixed" ||
    protocol === "mieru"
  ) {
    return "none";
  }
  if (
    protocol === "hysteria2" ||
    protocol === "tuic" ||
    protocol === "anytls" ||
    protocol === "naive" ||
    protocol === "fptn" ||
    protocol === "trusttunnel" ||
    protocol === "tewfai" ||
    protocol === "masque" ||
    protocol === "openconnect"
  ) {
    return "tls";
  }
  if (security === "reality" && protocol !== "vless") {
    return getDefaultSecurity(protocol);
  }

  return security || getDefaultSecurity(protocol);
}

function normalizeHost(host) {
  return `${host || ""}`.trim().replace(/^\[|\]$/g, "");
}

function getBrowserHost() {
  return normalizeHost(window.location.hostname || "");
}

function isIpv4(value) {
  return /^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}$/.test(
    value,
  );
}

function isIpv6(value) {
  const normalized = normalizeHost(value);
  if (!normalized.includes(":")) {
    return false;
  }

  try {
    new URL(`http://[${normalized}]/`);
    return true;
  } catch (_e) {
    return false;
  }
}

function formatHostForUri(host) {
  const normalized = normalizeHost(host);
  return isIpv6(normalized) ? `[${normalized}]` : normalized;
}

function isHostname(value) {
  const hostname = normalizeHost(value);
  if (hostname.length < 1 || hostname.length > 253 || hostname.endsWith(".")) {
    return false;
  }

  return hostname
    .split(".")
    .every((part) =>
      /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(part),
    );
}

function isHost(value) {
  const host = normalizeHost(value);
  return isIpv4(host) || isIpv6(host) || isHostname(host);
}

function isPrivateOrReservedIpv4(value) {
  if (!isIpv4(value)) {
    return true;
  }

  const octets = value.split(".").map((part) => parseInt(part, 10));
  const [a, b] = octets;

  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 192 && b === 0) ||
    (a === 192 && b === 2) ||
    (a === 198 && (b === 18 || b === 19 || b === 51)) ||
    (a === 203 && b === 0)
  );
}

function isPrivateOrReservedIp(value) {
  const normalized = normalizeHost(value).toLowerCase();
  if (isIpv4(normalized)) {
    return isPrivateOrReservedIpv4(normalized);
  }
  if (!isIpv6(normalized)) {
    return true;
  }

  return (
    normalized === "::" ||
    normalized === "::1" ||
    normalized.startsWith("fe80") ||
    normalized.startsWith("fc") ||
    normalized.startsWith("fd") ||
    normalized.startsWith("ff") ||
    normalized.startsWith("2001:db8")
  );
}

function getInterfaceIpAddresses(networkInterface) {
  const ipv4Values =
    networkInterface &&
    typeof networkInterface === "object" &&
    Array.isArray(networkInterface["ipv4-address"])
      ? networkInterface["ipv4-address"]
      : [];
  const ipv6Values =
    networkInterface &&
    typeof networkInterface === "object" &&
    Array.isArray(networkInterface["ipv6-address"])
      ? networkInterface["ipv6-address"]
      : [];

  return [...ipv4Values, ...ipv6Values]
    .map((address) =>
      normalizeHost(
        address && typeof address === "object" ? address.address : address,
      ),
    )
    .filter((address) => isIpv4(address) || isIpv6(address));
}

function chooseDefaultPublicHost(networkInterfaces) {
  const interfaces = Array.isArray(networkInterfaces) ? networkInterfaces : [];
  const upInterfaces = interfaces.filter(
    (networkInterface) => networkInterface && networkInterface.up !== false,
  );
  const publicIp = upInterfaces
    .flatMap(getInterfaceIpAddresses)
    .find((ip) => !isPrivateOrReservedIp(ip));

  if (publicIp) {
    return publicIp;
  }

  if (routerNetworkEnvCache) {
    if (routerNetworkEnvCache.has_ddns && routerNetworkEnvCache.ddns_domain) {
      return routerNetworkEnvCache.ddns_domain;
    }
    if (routerNetworkEnvCache.cached_external_ip) {
      return routerNetworkEnvCache.cached_external_ip;
    }
    if (
      routerNetworkEnvCache.public_host &&
      routerNetworkEnvCache.public_host !== routerNetworkEnvCache.lan_ip
    ) {
      return routerNetworkEnvCache.public_host;
    }
  }

  const wanInterface =
    upInterfaces.find((networkInterface) => {
      const name = `${networkInterface.interface || ""}`.toLowerCase();
      const device =
        `${networkInterface.device || networkInterface.l3_device || ""}`.toLowerCase();
      return (
        name.startsWith("wan") ||
        name.startsWith("wwan") ||
        device.startsWith("wan")
      );
    }) || {};
  const wanIp = getInterfaceIpAddresses(wanInterface).find(
    (ip) => ip !== "::1" && !ip.startsWith("127."),
  );

  if (wanIp) {
    return wanIp;
  }

  const lanInterface =
    upInterfaces.find((networkInterface) => {
      const name = `${networkInterface.interface || ""}`;
      const device = `${networkInterface.device || networkInterface.l3_device || ""}`;
      return name === "lan" || device === "br-lan";
    }) || {};
  const lanIp = getInterfaceIpAddresses(lanInterface).find(
    (ip) => ip !== "::1" && !ip.startsWith("127."),
  );

  if (lanIp) {
    return lanIp;
  }

  return (
    upInterfaces
      .flatMap(getInterfaceIpAddresses)
      .find((ip) => ip !== "::1" && !ip.startsWith("127.")) || getBrowserHost()
  );
}

function loadDefaultPublicHost() {
  if (defaultPublicHostCache != null) {
    return Promise.resolve(defaultPublicHostCache);
  }

  if (defaultPublicHostPromise) {
    return defaultPublicHostPromise;
  }

  defaultPublicHostPromise = fetchRouterNetworkEnv()
    .then((env) => {
      if (env && env.public_host) {
        defaultPublicHostCache = env.public_host;
        return defaultPublicHostCache;
      }
      return callNetworkInterfaceDump().then((networkInterfaces) => {
        defaultPublicHostCache = chooseDefaultPublicHost(networkInterfaces);
        return defaultPublicHostCache;
      });
    })
    .catch(() => getBrowserHost())
    .finally(() => {
      defaultPublicHostPromise = null;
    });

  return defaultPublicHostPromise;
}

function preloadServerModalData() {
  return Promise.all([fetchRouterNetworkEnv(), loadDefaultPublicHost()]).catch(
    () => null,
  );
}

function applyDefaultPublicHost(sectionId, host) {
  const normalizedHost = normalizeHost(host);
  const currentHost = normalizeHost(
    uci.get(UCI_PACKAGE, sectionId, "public_host"),
  );
  const browserHost = getBrowserHost();

  if (
    normalizedHost &&
    (!currentHost || currentHost === browserHost || currentHost === "127.0.0.1")
  ) {
    uci.set(UCI_PACKAGE, sectionId, "public_host", normalizedHost);
  }
}

function randomBytes(length) {
  const bytes = new Uint8Array(length);

  if (window.crypto && window.crypto.getRandomValues) {
    window.crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < length; i += 1) {
      bytes[i] = Math.floor(Math.random() * 256);
    }
  }

  return bytes;
}

function randomHex(byteLength) {
  return Array.from(randomBytes(byteLength))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function stringToHex(value) {
  return Array.from(unescape(encodeURIComponent(`${value || ""}`)))
    .map((char) => char.charCodeAt(0).toString(16).padStart(2, "0"))
    .join("");
}

function hexToString(value) {
  const hex = `${value || ""}`;
  if (!/^(?:[0-9a-fA-F]{2})+$/.test(hex)) {
    return "";
  }

  const bytes = hex.match(/../g).map((byte) => parseInt(byte, 16));
  try {
    return decodeURIComponent(
      escape(bytes.map((byte) => String.fromCharCode(byte)).join("")),
    );
  } catch (_error) {
    return "";
  }
}

function generateUuid() {
  if (window.crypto && window.crypto.randomUUID) {
    return window.crypto.randomUUID();
  }

  const bytes = randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");

  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function base64Encode(value) {
  return btoa(unescape(encodeURIComponent(value)));
}

function base64UrlEncode(value) {
  return base64Encode(value)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function generatePassword() {
  const binary = Array.from(randomBytes(18))
    .map((byte) => String.fromCharCode(byte))
    .join("");
  const b64 = typeof btoa === "function" ? btoa(binary) : window.btoa(binary);
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function generateBase64Key(byteLength) {
  const binary = Array.from(randomBytes(byteLength))
    .map((byte) => String.fromCharCode(byte))
    .join("");
  return typeof btoa === "function" ? btoa(binary) : window.btoa(binary);
}

function generateShadowsocksPassword(method) {
  const m = `${method || "aes-128-gcm"}`.toLowerCase();
  const keyBytes = m.includes("128") ? 16 : 32;
  return generateBase64Key(keyBytes);
}

function randomIntInRange(min, max) {
  const bytes = randomBytes(4);
  const val =
    ((bytes[0] << 24) >>> 0) +
    ((bytes[1] << 16) >>> 0) +
    ((bytes[2] << 8) >>> 0) +
    (bytes[3] >>> 0);
  return min + (val % (max - min + 1));
}

function getOpenconnectFlavorDefaults(flavor) {
  switch (flavor) {
    case "gp":
      return {
        userAgent: "PanGP/6.2.0-142 (Linux)",
        hostname: "gp-gateway",
        urlpath: "/ssl-vpn/login.esp",
      };
    case "nc":
      return {
        userAgent: " JunosPulse/9.1R11 (Linux)",
        hostname: "juniper-gw",
        urlpath: "/dana-na/auth/url_default/welcome.cgi",
      };
    case "f5":
      return {
        userAgent: "BIG-IP Edge Client/7240.2024",
        hostname: "f5-edge-gw",
        urlpath: "/my.policy",
      };
    case "fortinet":
      return {
        userAgent: "FortiSSLVPN (Linux)",
        hostname: "forti-gw",
        urlpath: "/remote/login",
      };
    case "pulse":
      return {
        userAgent: "Pulse-Secure/22.6R1 (Linux)",
        hostname: "pulse-gw",
        urlpath: "/dana-na/auth/url_default/welcome.cgi",
      };
    case "anyconnect":
    default:
      return {
        userAgent: "Open AnyConnect VPN Agent v9.12",
        hostname: "anyconnect-gw",
        urlpath: "/vpn",
      };
  }
}

function generateMtprotoSecret() {
  const secret = randomHex(16);
  return secret === "00000000000000000000000000000000"
    ? "11111111111111111111111111111111"
    : secret;
}

function randomPort() {
  const bytes = randomBytes(2);
  const value = (bytes[0] << 8) | bytes[1];
  return `${20000 + (value % 30000)}`;
}

function serverSafeName(sectionId) {
  return `${sectionId || "server"}`.replace(/[^A-Za-z0-9_.-]/g, "_");
}

function defaultTlsCertificatePath(sectionId) {
  return `/etc/tachyon/server-certs/${serverSafeName(sectionId)}.crt`;
}

function defaultTlsKeyPath(sectionId) {
  return `/etc/tachyon/server-certs/${serverSafeName(sectionId)}.key`;
}

function defaultTailscaleHostname(sectionId) {
  return `tachyon-${serverSafeName(sectionId)}`;
}

function setDefault(sectionId, key, value) {
  const current = uci.get(UCI_PACKAGE, sectionId, key);
  if (current == null || current === "") {
    uci.set(UCI_PACKAGE, sectionId, key, value);
  }
}

function setValue(sectionId, key, value) {
  uci.set(UCI_PACKAGE, sectionId, key, value);
}

function cloneUciState(value) {
  return value == null ? null : JSON.parse(JSON.stringify(value));
}

function isEmptyObject(value) {
  return value && Object.keys(value).length === 0;
}

function setUciSectionState(bucketName, sectionId, value) {
  const state = uci.state;

  if (!state) {
    return;
  }

  state[bucketName] ??= {};
  const bucket = state[bucketName];

  if (value == null) {
    delete bucket[UCI_PACKAGE]?.[sectionId];
    if (isEmptyObject(bucket[UCI_PACKAGE])) {
      delete bucket[UCI_PACKAGE];
    }
    return;
  }

  bucket[UCI_PACKAGE] ??= {};
  bucket[UCI_PACKAGE][sectionId] = cloneUciState(value);
}

function captureServerEditState(sectionId) {
  const state = uci.state;

  if (!state || state.creates?.[UCI_PACKAGE]?.[sectionId]) {
    return null;
  }

  return {
    sectionId,
    changes: cloneUciState(state.changes?.[UCI_PACKAGE]?.[sectionId]),
    deletes: cloneUciState(state.deletes?.[UCI_PACKAGE]?.[sectionId]),
  };
}

function restoreServerEditState(snapshot) {
  if (!snapshot) {
    return;
  }

  setUciSectionState("changes", snapshot.sectionId, snapshot.changes);
  setUciSectionState("deletes", snapshot.sectionId, snapshot.deletes);
}

function sanitizeUciDeletes(targetSectionId) {
  const state = uci.state;
  if (!state || !state.deletes?.[UCI_PACKAGE]) {
    return;
  }

  const creates = state.creates?.[UCI_PACKAGE] || {};
  const values = state.values?.[UCI_PACKAGE] || {};
  const deletes = state.deletes[UCI_PACKAGE];

  for (const sid in deletes) {
    if (creates[sid] || !values[sid]) {
      delete deletes[sid];
      continue;
    }

    if (deletes[sid] !== true && typeof deletes[sid] === "object") {
      for (const opt in deletes[sid]) {
        if (!values[sid].hasOwnProperty(opt)) {
          delete deletes[sid][opt];
        }
      }
      if (isEmptyObject(deletes[sid])) {
        delete deletes[sid];
      }
    }
  }

  if (
    targetSectionId &&
    (creates[targetSectionId] || !values[targetSectionId])
  ) {
    delete deletes[targetSectionId];
  }

  if (isEmptyObject(state.deletes[UCI_PACKAGE])) {
    delete state.deletes[UCI_PACKAGE];
  }
}

function ensureProtocolDefaults(sectionId, protocol, forceProtocolDefaults) {
  setValue(sectionId, "protocol", protocol);
  setDefault(sectionId, "enabled", "1");
  setDefault(sectionId, "label", sectionId);
  setDefault(sectionId, "routing_mode", "rules");
  setDefault(sectionId, "open_firewall_port", "1");

  if (protocol === "json_inbound") {
    setValue(sectionId, "security", getDefaultSecurity(protocol));
    return;
  }

  setDefault(sectionId, "listen", "0.0.0.0");
  let defaultPort = "443";
  if (
    routerNetworkEnvCache &&
    routerNetworkEnvCache.recommended_ports &&
    routerNetworkEnvCache.recommended_ports[protocol]
  ) {
    defaultPort = `${routerNetworkEnvCache.recommended_ports[protocol]}`;
  } else if (protocol === "awg") {
    defaultPort = "51820";
  } else if (protocol === "hysteria2") {
    defaultPort = "443";
  } else if (protocol === "tuic" || protocol === "mieru") {
    defaultPort = "8443";
  } else if (protocol === "shadowsocks") {
    defaultPort = "8388";
  } else if (protocol === "socks") {
    defaultPort = "1080";
  } else if (protocol === "http" || protocol === "mixed") {
    defaultPort = "8080";
  }
  setDefault(sectionId, "listen_port", defaultPort);

  if (defaultPublicHostCache) {
    setDefault(sectionId, "public_host", defaultPublicHostCache);
  }
  setDefault(
    sectionId,
    "tls_certificate_path",
    defaultTlsCertificatePath(sectionId),
  );
  setDefault(sectionId, "tls_key_path", defaultTlsKeyPath(sectionId));

  const terminatingSni =
    routerNetworkEnvCache && routerNetworkEnvCache.recommended_sni
      ? routerNetworkEnvCache.recommended_sni.terminating_tls
      : "tachyon.lan";

  if (forceProtocolDefaults) {
    setValue(sectionId, "security", getDefaultSecurity(protocol));
    setValue(sectionId, "transport", "tcp");
  } else {
    setDefault(sectionId, "security", getDefaultSecurity(protocol));
    setDefault(sectionId, "transport", "tcp");
  }

  if (protocol === "vless" || protocol === "vmess" || protocol === "tuic") {
    setDefault(sectionId, "server_uuid", generateUuid());
  }

  if (PASSWORD_PROTOCOLS.includes(protocol)) {
    setDefault(sectionId, "server_password", generatePassword());
  }

  if (
    protocol === "socks" ||
    protocol === "naive" ||
    protocol === "fptn" ||
    protocol === "http" ||
    protocol === "mixed" ||
    protocol === "mieru" ||
    protocol === "trusttunnel" ||
    protocol === "masque"
  ) {
    setDefault(sectionId, "server_username", getServerName(sectionId));
    if (protocol === "socks") {
      setDefault(sectionId, "socks_auth_enabled", "1");
    }
  }

  if (protocol === "mieru") {
    setDefault(sectionId, "mieru_transport", "TCP");
  }

  if (protocol === "trusttunnel") {
    setDefault(sectionId, "trusttunnel_quic", "0");
    setDefault(sectionId, "tls_server_name", terminatingSni);
  }

  if (protocol === "tuic") {
    setDefault(sectionId, "tuic_congestion_control", "bbr");
    setDefault(sectionId, "tls_server_name", terminatingSni);
  }

  if (protocol === "shadowtls") {
    setDefault(sectionId, "shadowtls_handshake_server", "www.microsoft.com");
    setDefault(sectionId, "shadowtls_handshake_server_port", "443");
    setDefault(sectionId, "shadowtls_version", "3");
  }

  if (
    protocol === "anytls" ||
    protocol === "naive" ||
    protocol === "fptn" ||
    protocol === "trojan"
  ) {
    setDefault(sectionId, "tls_server_name", terminatingSni);
  }

  if (protocol === "vless") {
    setDefault(sectionId, "vless_flow", "none");
    setDefault(sectionId, "tls_server_name", "www.microsoft.com");
    setDefault(sectionId, "client_fingerprint", "chrome");
    setDefault(sectionId, "reality_handshake_server", "www.microsoft.com");
    setDefault(sectionId, "reality_handshake_server_port", "443");
    setDefault(sectionId, "reality_short_id", randomHex(4));
    setDefault(sectionId, "reality_max_time_difference", "1m");
  }

  if (protocol === "vmess") {
    setDefault(sectionId, "vmess_alter_id", "0");
  }

  if (protocol === "shadowsocks") {
    const ssMethod =
      uci.get(UCI_PACKAGE, sectionId, "shadowsocks_method") || "aes-128-gcm";
    setDefault(sectionId, "shadowsocks_method", ssMethod);
    if (!uci.get(UCI_PACKAGE, sectionId, "server_password")) {
      setValue(
        sectionId,
        "server_password",
        generateShadowsocksPassword(ssMethod),
      );
    }
  }

  if (protocol === "tailscale") {
    setDefault(
      sectionId,
      "tailscale_control_url",
      "https://controlplane.tailscale.com",
    );
    setDefault(
      sectionId,
      "tailscale_hostname",
      defaultTailscaleHostname(sectionId),
    );
    setDefault(sectionId, "tailscale_advertise_exit_node", "1");
  }

  if (protocol === "hysteria2") {
    setDefault(sectionId, "hysteria2_obfs_type", "salamander");
    setDefault(sectionId, "hysteria2_obfs_password", generatePassword());
    setDefault(sectionId, "tls_server_name", terminatingSni);
  }

  if (protocol === "awg") {
    const awgNet =
      routerNetworkEnvCache && routerNetworkEnvCache.awg
        ? routerNetworkEnvCache.awg
        : {
            local_address: "10.8.0.1/24",
            client_address: "10.8.0.2/32",
            dns: "10.8.0.1",
            h1: "184920412",
            h2: "492019482",
            h3: "829401928",
            h4: "392019481",
          };
    setDefault(sectionId, "listen_port", "51820");
    setDefault(sectionId, "awg_local_address", awgNet.local_address);
    setDefault(sectionId, "awg_client_address", awgNet.client_address);
    setDefault(sectionId, "awg_dns", awgNet.dns);
    setDefault(sectionId, "awg_mtu", "1280");
    setDefault(sectionId, "awg_keepalive", "25");
    setDefault(sectionId, "awg_version", "2.0");
    setDefault(sectionId, "awg_jc", "4");
    setDefault(sectionId, "awg_jmin", "40");
    setDefault(sectionId, "awg_jmax", "70");
    setDefault(sectionId, "awg_s1", "0");
    setDefault(sectionId, "awg_s2", "0");
    setDefault(sectionId, "awg_s3", "0");
    setDefault(sectionId, "awg_s4", "0");
    setDefault(sectionId, "awg_h1", `${awgNet.h1}`);
    setDefault(sectionId, "awg_h2", `${awgNet.h2}`);
    setDefault(sectionId, "awg_h3", `${awgNet.h3}`);
    setDefault(sectionId, "awg_h4", `${awgNet.h4}`);
  }

  if (protocol === "mtproto") {
    setDefault(sectionId, "mtproto_secret", generateMtprotoSecret());
    setDefault(sectionId, "mtproto_faketls", "google.com");
    setDefault(sectionId, "mtproto_padding", "1");
    setDefault(sectionId, "mtproto_domain_fronting_port", "443");
    setDefault(sectionId, "mtproto_prefer_ip", "prefer-ipv4");
    setDefault(sectionId, "mtproto_tolerate_time_skewness", "3s");
    setDefault(sectionId, "mtproto_idle_timeout", "5m");
    setDefault(sectionId, "mtproto_handshake_timeout", "10s");
  }

  if (protocol === "tewfai") {
    setDefault(sectionId, "tewfai_uuid", generateUuid());
    setDefault(sectionId, "tewfai_password", generatePassword());
    setDefault(sectionId, "tewfai_inbound_transport", "tcp");
    setDefault(sectionId, "tewfai_inner_cipher", "aes-256-gcm");
    setDefault(sectionId, "tewfai_pqc_enabled", "1");
    setDefault(sectionId, "tewfai_handover_enabled", "1");
    setDefault(sectionId, "tewfai_fec_enabled", "0");
    setDefault(sectionId, "tewfai_shaper_enabled", "1");
    setDefault(sectionId, "tewfai_shaper_profile", "adaptive");
    setDefault(sectionId, "tewfai_mtu", "1400");
    setDefault(sectionId, "tls_server_name", terminatingSni);
  }

  if (protocol === "masque") {
    setDefault(sectionId, "masque_ipv4_pool", "172.16.0.0/24");
    setDefault(sectionId, "masque_ipv6_pool", "fd00:172:16::/64");
    setDefault(sectionId, "masque_mtu", "1400");
    setDefault(sectionId, "tls_server_name", terminatingSni);
  }

  if (protocol === "openconnect") {
    const ocFlavor =
      uci.get(UCI_PACKAGE, sectionId, "openconnect_flavor") || "anyconnect";
    const ocDefaults = getOpenconnectFlavorDefaults(ocFlavor);
    setDefault(sectionId, "openconnect_cookie", generatePassword());
    setDefault(sectionId, "openconnect_flavor", ocFlavor);
    setDefault(sectionId, "openconnect_user_agent", ocDefaults.userAgent);
    setDefault(sectionId, "openconnect_local_hostname", ocDefaults.hostname);
    setDefault(sectionId, "openconnect_urlpath", ocDefaults.urlpath);
    setDefault(sectionId, "openconnect_address", "172.16.1.2/24");
    setDefault(sectionId, "openconnect_mtu", "1400");
    setDefault(sectionId, "openconnect_ip", "0");
    setDefault(sectionId, "tls_server_name", terminatingSni);
  }
}

function parseLegacyServerUser(sectionId, protocol) {
  const entry = asList(uci.get(UCI_PACKAGE, sectionId, "server_users"))[0];
  if (!entry) {
    return null;
  }

  const parts = `${entry}`.split("|");
  return {
    name: parts.length > 1 ? parts[0].trim() : "client",
    credential: (parts.length > 1 ? parts[1] : parts[0] || "").trim(),
    extra: (parts[2] || "").trim(),
    protocol,
  };
}

function normalizeMtprotoBaseSecret(value) {
  const secret = `${value || ""}`.trim().toLowerCase();

  if (/^[0-9a-f]{32}$/.test(secret)) {
    return secret;
  }
  if (/^ee[0-9a-f]{32}(?:[0-9a-f]{2})+$/.test(secret)) {
    return secret.slice(2, 34);
  }

  return "";
}

function getMtprotoFaketlsFromSecret(value) {
  const secret = `${value || ""}`.trim().toLowerCase();

  if (!/^ee[0-9a-f]{32}(?:[0-9a-f]{2})+$/.test(secret)) {
    return "";
  }

  return hexToString(secret.slice(34));
}

function getMtprotoFaketls(sectionId) {
  return (
    uci.get(UCI_PACKAGE, sectionId, "mtproto_faketls") ||
    getMtprotoFaketlsFromSecret(
      uci.get(UCI_PACKAGE, sectionId, "mtproto_secret"),
    ) ||
    "google.com"
  );
}

function isMtprotoPaddingEnabled(sectionId) {
  return uci.get(UCI_PACKAGE, sectionId, "mtproto_padding") !== "0";
}

function buildMtprotoFullSecret(baseSecret, faketls, padding) {
  if (!padding) {
    return baseSecret;
  }

  return `ee${baseSecret}${stringToHex(faketls || "google.com")}`;
}

function countryCodeToFlagEmoji(code) {
  const clean = `${code || ""}`.trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(clean)) return "";
  return String.fromCodePoint(
    0x1f1e6 + clean.charCodeAt(0) - 65,
    0x1f1e6 + clean.charCodeAt(1) - 65,
  );
}

function getServerIdentity(sectionId) {
  const protocol = getProtocol(sectionId);
  const legacy = parseLegacyServerUser(sectionId, protocol);
  const rawName = getServerName(sectionId);
  const countryCode =
    uci.get(UCI_PACKAGE, sectionId, "server_country") ||
    (routerNetworkEnvCache && routerNetworkEnvCache.country_code) ||
    "RU";
  const flag = countryCodeToFlagEmoji(countryCode);
  const hasFlag = /[\u{1F1E6}-\u{1F1FF}]{2}/u.test(rawName);
  const name = flag && !hasFlag ? `${flag} ${rawName}` : rawName;
  const uuid =
    uci.get(UCI_PACKAGE, sectionId, "server_uuid") || legacy?.credential || "";
  const password =
    uci.get(UCI_PACKAGE, sectionId, "server_password") ||
    (PASSWORD_PROTOCOLS.includes(protocol) ? legacy?.credential : "") ||
    "";
  const mtprotoSecret =
    normalizeMtprotoBaseSecret(
      uci.get(UCI_PACKAGE, sectionId, "mtproto_secret"),
    ) ||
    normalizeMtprotoBaseSecret(
      protocol === "mtproto" ? legacy?.credential : "",
    ) ||
    "";

  return {
    name,
    username: getSocksUsername(sectionId),
    uuid,
    password,
    mtprotoSecret,
    mtprotoFaketls: getMtprotoFaketls(sectionId),
    mtprotoPadding: isMtprotoPaddingEnabled(sectionId),
    flow: normalizeVlessFlow(
      uci.get(UCI_PACKAGE, sectionId, "vless_flow") ||
        (protocol === "vless" ? legacy?.extra : "") ||
        "",
    ),
  };
}

function encodeQuery(params) {
  return Object.entries(params)
    .filter(([, value]) => value != null && value !== "")
    .map(
      ([key, value]) =>
        `${encodeURIComponent(key)}=${encodeURIComponent(`${value}`)}`,
    )
    .join("&");
}

function getPublicHost(sectionId, options = {}) {
  if (options && options.hostOverride) {
    return options.hostOverride;
  }
  return (
    uci.get(UCI_PACKAGE, sectionId, "public_host") ||
    defaultPublicHostCache ||
    window.location.hostname ||
    ""
  );
}

function getServerPort(sectionId) {
  const configured = uci.get(UCI_PACKAGE, sectionId, "listen_port");
  if (configured) {
    return `${configured}`;
  }
  const protocol = getProtocol(sectionId);
  if (
    routerNetworkEnvCache &&
    routerNetworkEnvCache.recommended_ports &&
    routerNetworkEnvCache.recommended_ports[protocol]
  ) {
    return `${routerNetworkEnvCache.recommended_ports[protocol]}`;
  }
  if (protocol === "awg") return "51820";
  if (protocol === "tuic" || protocol === "mieru") return "8443";
  if (protocol === "shadowsocks") return "8388";
  if (protocol === "socks") return "1080";
  if (protocol === "http" || protocol === "mixed") return "8080";
  return "443";
}

function getTransportParams(sectionId, params) {
  const transport = uci.get(UCI_PACKAGE, sectionId, "transport") || "tcp";
  params.type = transport === "raw" ? "tcp" : transport;

  if (transport === "ws" || transport === "httpupgrade") {
    params.path = uci.get(UCI_PACKAGE, sectionId, "transport_path") || "";
    params.host = uci.get(UCI_PACKAGE, sectionId, "transport_host") || "";
  } else if (transport === "xhttp") {
    params.path = uci.get(UCI_PACKAGE, sectionId, "transport_path") || "/";
    params.host = uci.get(UCI_PACKAGE, sectionId, "transport_host") || "";
    params.mode =
      uci.get(UCI_PACKAGE, sectionId, "transport_xhttp_mode") || "auto";
  } else if (transport === "grpc") {
    params.serviceName =
      uci.get(UCI_PACKAGE, sectionId, "transport_service_name") || "";
  } else if (transport === "http") {
    params.path = uci.get(UCI_PACKAGE, sectionId, "transport_path") || "";
    params.host = asList(
      uci.get(UCI_PACKAGE, sectionId, "transport_hosts"),
    ).join(",");
  }

  return transport;
}

function buildVlessTrojanLink(sectionId, identity, options = {}) {
  const protocol = getProtocol(sectionId);
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const security = getEffectiveSecurity(sectionId);
  const tlsServerName =
    uci.get(UCI_PACKAGE, sectionId, "tls_server_name") ||
    uci.get(UCI_PACKAGE, sectionId, "reality_handshake_server") ||
    "";
  const params = { security };
  const credential = protocol === "vless" ? identity.uuid : identity.password;

  getTransportParams(sectionId, params);

  if (protocol === "vless") {
    params.encryption = "none";
  }

  if (security === "tls" || security === "reality") {
    params.sni = tlsServerName;
    params.alpn = asList(uci.get(UCI_PACKAGE, sectionId, "tls_alpn")).join(",");
  }

  if (security === "tls") {
    if (
      shouldUseGeneratedTlsCertificatePin(sectionId) ||
      (options && options.tlsCertificateSha256)
    ) {
      params.insecure = "1";
      params.allowInsecure = "1";
    }
    if (options && options.tlsCertificateSha256) {
      params.pcs = normalizeSha256(options.tlsCertificateSha256);
    }
  }

  if (security === "reality") {
    params.pbk = uci.get(UCI_PACKAGE, sectionId, "reality_public_key") || "";
    params.sid = getFirstListValue(sectionId, "reality_short_id");
    params.fp =
      uci.get(UCI_PACKAGE, sectionId, "client_fingerprint") || "chrome";
  }

  if (protocol === "vless" && identity.flow) {
    params.flow = identity.flow;
  }

  const query = encodeQuery(params);
  return `${protocol}://${encodeURIComponent(credential)}@${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildVmessLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const security = getEffectiveSecurity(sectionId);
  const transportParams = {};
  const transport = getTransportParams(sectionId, transportParams);
  if (
    security === "reality" &&
    (!uci.get(UCI_PACKAGE, sectionId, "reality_public_key") ||
      !getFirstListValue(sectionId, "reality_short_id"))
  ) {
    return "";
  }

  const payload = {
    v: "2",
    ps: identity.name || sectionId,
    add: host,
    port,
    id: identity.uuid,
    aid: uci.get(UCI_PACKAGE, sectionId, "vmess_alter_id") || "0",
    scy: "auto",
    net: transport === "tcp" ? "tcp" : transport,
    type: "none",
    host: transportParams.host || "",
    path: transportParams.path || transportParams.serviceName || "",
    tls: security === "tls" ? "tls" : "",
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || "",
    alpn: asList(uci.get(UCI_PACKAGE, sectionId, "tls_alpn")).join(","),
  };

  if (security === "tls") {
    const certificatePin = normalizeSha256(options.tlsCertificateSha256);
    if (shouldUseGeneratedTlsCertificatePin(sectionId) || certificatePin) {
      payload.allowInsecure = 1;
    }
    if (certificatePin) {
      payload.pcs = certificatePin;
    }
  }

  return `vmess://${base64Encode(JSON.stringify(payload))}`;
}

function buildShadowsocksLink(sectionId, identity, options = {}) {
  const method =
    uci.get(UCI_PACKAGE, sectionId, "shadowsocks_method") || "aes-128-gcm";
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "8388");
  const userInfo = base64UrlEncode(`${method}:${identity.password}`);

  return `ss://${userInfo}@${uriHost}:${port}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildSocksLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "1080");
  const username = identity.username || identity.name || sectionId;
  const userInfo = isSocksAuthenticationEnabled(sectionId)
    ? `${encodeURIComponent(username)}:${encodeURIComponent(identity.password)}@`
    : "";

  return `socks5://${userInfo}${uriHost}:${port}#${encodeURIComponent(identity.name || sectionId)}`;
}

function normalizeSha256(value) {
  const normalized = `${value || ""}`.trim().replace(/:/g, "").toLowerCase();
  return /^[0-9a-f]{64}$/.test(normalized) ? normalized : "";
}

function shouldUseGeneratedTlsCertificatePin(sectionId) {
  const certificatePath = `${
    uci.get(UCI_PACKAGE, sectionId, "tls_certificate_path") ||
    defaultTlsCertificatePath(sectionId)
  }`.trim();

  return !/^\/etc\/(acme|letsencrypt|ssl\/certs)\//.test(certificatePath);
}

function loadGeneratedTlsCertificatePin(sectionId) {
  if (!shouldUseGeneratedTlsCertificatePin(sectionId)) {
    return Promise.resolve("");
  }

  return fs
    .exec("/usr/bin/tachyon", ["get_tls_certificate_sha256", sectionId])
    .then((response) => {
      if ((response.code ?? 0) !== 0 || !response.stdout) {
        throw new Error(response.stderr || response.stdout || "");
      }

      const data = JSON.parse(response.stdout);
      if (!data.success) {
        throw new Error(data.message || "");
      }

      return normalizeSha256(data.sha256);
    })
    .catch((error) => {
      console.warn(
        error?.message || "Failed to read generated TLS certificate pin",
        error,
      );
      return "";
    });
}

function buildHysteria2Link(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const certificatePin = normalizeSha256(options.tlsCertificateSha256);
  const obfsType = uci.get(UCI_PACKAGE, sectionId, "hysteria2_obfs_type") || "";
  const params = {
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || "",
  };

  if (certificatePin) {
    params.insecure = "1";
    params.pinSHA256 = certificatePin;
  } else if (shouldUseGeneratedTlsCertificatePin(sectionId)) {
    params.insecure = "1";
  }

  if (obfsType === "salamander") {
    params.obfs = obfsType;
    params["obfs-password"] =
      uci.get(UCI_PACKAGE, sectionId, "hysteria2_obfs_password") || "";
  }

  const query = encodeQuery(params);

  return `hysteria2://${encodeURIComponent(identity.password)}@${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildMtprotoLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const secret = buildMtprotoFullSecret(
    identity.mtprotoSecret,
    identity.mtprotoFaketls,
    identity.mtprotoPadding,
  );
  const query = encodeQuery({
    server: host,
    port,
    secret,
  });

  return `https://t.me/proxy?${query}`;
}

function buildTuicLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "8443");
  const certificatePin = normalizeSha256(options.tlsCertificateSha256);
  const cc =
    uci.get(UCI_PACKAGE, sectionId, "tuic_congestion_control") || "bbr";
  const params = {
    congestion_control: cc,
    alpn: "h3",
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || host,
  };
  if (certificatePin) {
    params.insecure = "1";
    params.pcs = certificatePin;
  } else if (shouldUseGeneratedTlsCertificatePin(sectionId)) {
    params.insecure = "1";
  }
  const query = encodeQuery(params);
  return `tuic://${encodeURIComponent(identity.uuid)}:${encodeURIComponent(identity.password)}@${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildAnytlsLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const certificatePin = normalizeSha256(options.tlsCertificateSha256);
  const params = {
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || host,
  };
  if (certificatePin) {
    params.insecure = "1";
    params.pcs = certificatePin;
  } else if (shouldUseGeneratedTlsCertificatePin(sectionId)) {
    params.insecure = "1";
  }
  const query = encodeQuery(params);
  return `anytls://${encodeURIComponent(identity.password)}@${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildNaiveLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const username = identity.username || identity.name || sectionId;
  const certificatePin = normalizeSha256(options.tlsCertificateSha256);
  const params = {
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || host,
  };
  if (certificatePin) {
    params.pcs = certificatePin;
  }
  const query = encodeQuery(params);
  return `naive+https://${encodeURIComponent(username)}:${encodeURIComponent(identity.password)}@${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildShadowtlsLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const handshakeServer =
    uci.get(UCI_PACKAGE, sectionId, "shadowtls_handshake_server") ||
    "www.microsoft.com";
  const version = uci.get(UCI_PACKAGE, sectionId, "shadowtls_version") || "3";
  const query = encodeQuery({
    sni: handshakeServer,
    version: version,
  });
  return `shadowtls://${encodeURIComponent(identity.password)}@${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildFptnPayload(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const port = parseInt(
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
      (typeof getServerPort === "function" ? getServerPort(sectionId) : "443"),
    10,
  );
  const username = identity.username || identity.name || sectionId;
  const serverName = identity.name || getServerName(sectionId) || sectionId;
  return {
    version: 1,
    service_name: "Tachyon",
    username: username,
    password: identity.password || "",
    servers: [
      {
        name: serverName,
        host: host,
        port: port,
        md5_fingerprint: "",
      },
    ],
    censored_zone_servers: [],
  };
}

function buildFptnToken(sectionId, identity, options = {}) {
  const payload = buildFptnPayload(sectionId, identity, options);
  const b64 = base64Encode(JSON.stringify(payload)).replace(/=+$/, "");
  return `fptn:${b64}`;
}

function buildFptnLink(sectionId, identity, options = {}) {
  const payload = buildFptnPayload(sectionId, identity, options);
  const b64 = base64Encode(JSON.stringify(payload)).replace(/=+$/, "");
  const serverName = identity.name || getServerName(sectionId) || sectionId;
  return `fptn://${b64}#${encodeURIComponent(serverName)}`;
}

function buildHttpLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "8080");
  const username = identity.username || identity.name || sectionId;
  const userInfo = identity.password
    ? `${encodeURIComponent(username)}:${encodeURIComponent(identity.password)}@`
    : "";
  return `http://${userInfo}${uriHost}:${port}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildMixedLink(sectionId, identity, options = {}) {
  return buildSocksLink(sectionId, identity, options);
}

function buildMieruLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "8443");
  const username = identity.username || identity.name || sectionId;
  const transport = uci.get(UCI_PACKAGE, sectionId, "mieru_transport") || "TCP";
  const query = encodeQuery({
    port,
    protocol: transport,
    profile: identity.name || sectionId,
  });
  return `mierus://${encodeURIComponent(username)}:${encodeURIComponent(identity.password)}@${uriHost}${query ? `?${query}` : ""}`;
}

function buildTrusttunnelLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const username = identity.username || identity.name || sectionId;
  const certificatePin = normalizeSha256(options.tlsCertificateSha256);
  const params = {
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || host,
    alpn: asList(uci.get(UCI_PACKAGE, sectionId, "tls_alpn")).join(","),
  };
  if (certificatePin) {
    params.insecure = "1";
    params.pcs = certificatePin;
  } else if (shouldUseGeneratedTlsCertificatePin(sectionId)) {
    params.insecure = "1";
  }
  if (uci.get(UCI_PACKAGE, sectionId, "trusttunnel_quic") === "1") {
    params.quic = "1";
  }
  const query = encodeQuery(params);
  return `trusttunnel://${encodeURIComponent(username)}:${encodeURIComponent(identity.password)}@${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildTewfaiLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const uuid =
    uci.get(UCI_PACKAGE, sectionId, "tewfai_uuid") || identity.uuid || "";
  if (!uuid) return "";
  const pwd = uci.get(UCI_PACKAGE, sectionId, "tewfai_password") || "";
  const cred = pwd
    ? `${encodeURIComponent(uuid)}:${encodeURIComponent(pwd)}`
    : encodeURIComponent(uuid);
  const certificatePin = normalizeSha256(options.tlsCertificateSha256);
  const params = {
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || host,
    alpn: asList(uci.get(UCI_PACKAGE, sectionId, "tls_alpn")).join(","),
  };
  if (certificatePin) {
    params.insecure = "1";
    params.pcs = certificatePin;
  } else if (shouldUseGeneratedTlsCertificatePin(sectionId)) {
    params.insecure = "1";
  }
  const transports = asList(
    uci.get(UCI_PACKAGE, sectionId, "tewfai_inbound_transport"),
  )
    .map((tr) => {
      if (tr === "quic" || tr === "h3_stream" || tr === "h3_datagram")
        return "quic";
      if (tr === "tcp" || tr === "raw_tls" || tr === "h2" || tr === "ws")
        return "tcp";
      return "";
    })
    .filter((v, idx, arr) => v && arr.indexOf(v) === idx);
  if (transports.includes("quic") && !transports.includes("tcp")) {
    transports.push("tcp");
  }
  if (transports.length > 0) {
    params.transport = transports.join(",");
  }
  const innerCipher =
    uci.get(UCI_PACKAGE, sectionId, "tewfai_inner_cipher") || "";
  if (innerCipher) {
    params.inner_cipher = innerCipher;
  }
  if (uci.get(UCI_PACKAGE, sectionId, "tewfai_pqc_enabled") === "1") {
    params.pqc = "1";
  }
  if (uci.get(UCI_PACKAGE, sectionId, "tewfai_handover_enabled") === "1") {
    params.handover = "1";
  }
  if (uci.get(UCI_PACKAGE, sectionId, "tewfai_fec_enabled") === "1") {
    params.fec = "1";
  }
  if (uci.get(UCI_PACKAGE, sectionId, "tewfai_shaper_enabled") === "1") {
    params.shaper = "1";
    const shaperProfile =
      uci.get(UCI_PACKAGE, sectionId, "tewfai_shaper_profile") || "";
    if (shaperProfile) {
      params.shaper_profile = shaperProfile;
    }
  }
  const query = encodeQuery(params);
  return `tewfai://${cred}@${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildMasqueLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const certificatePin = normalizeSha256(options.tlsCertificateSha256);
  const params = {
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || host,
    alpn: asList(uci.get(UCI_PACKAGE, sectionId, "tls_alpn")).join(","),
    profile: "standard",
    uri: `https://${uriHost}:${port}/.well-known/masque/ip/*/*/`,
  };
  if (certificatePin) {
    params.insecure = "1";
    params.pcs = certificatePin;
  } else if (shouldUseGeneratedTlsCertificatePin(sectionId)) {
    params.insecure = "1";
  }
  const pool4 = getFirstListValue(sectionId, "masque_ipv4_pool");
  if (pool4) params.ip = pool4;
  const pool6 = getFirstListValue(sectionId, "masque_ipv6_pool");
  if (pool6) params.ipv6 = pool6;
  const mtu = uci.get(UCI_PACKAGE, sectionId, "masque_mtu") || "";
  if (mtu) params.mtu = mtu;
  const query = encodeQuery(params);
  return `masque://${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildOpenconnectLink(sectionId, identity, options = {}) {
  const host = getPublicHost(sectionId, options);
  const uriHost = formatHostForUri(host);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const cookie = uci.get(UCI_PACKAGE, sectionId, "openconnect_cookie") || "";
  const username = identity.username || identity.name || sectionId;
  const auth = identity.password
    ? `${encodeURIComponent(username)}:${encodeURIComponent(identity.password)}@`
    : cookie
      ? `${encodeURIComponent(cookie)}@`
      : "";
  if (!auth) return "";
  const certificatePin = normalizeSha256(options.tlsCertificateSha256);
  const params = {
    sni: uci.get(UCI_PACKAGE, sectionId, "tls_server_name") || host,
    alpn: asList(uci.get(UCI_PACKAGE, sectionId, "tls_alpn")).join(","),
  };
  if (certificatePin) {
    params.insecure = "1";
    params.pcs = certificatePin;
  } else if (shouldUseGeneratedTlsCertificatePin(sectionId)) {
    params.insecure = "1";
  }
  const flavor = uci.get(UCI_PACKAGE, sectionId, "openconnect_flavor") || "";
  if (flavor) params.flavor = flavor;
  if (cookie) params.cookie = cookie;
  const urlpath = uci.get(UCI_PACKAGE, sectionId, "openconnect_urlpath") || "";
  if (urlpath) params.urlpath = urlpath;
  const address = uci.get(UCI_PACKAGE, sectionId, "openconnect_address") || "";
  if (address) params.address = address;
  const mtu = uci.get(UCI_PACKAGE, sectionId, "openconnect_mtu") || "";
  if (mtu) params.mtu = mtu;
  if (uci.get(UCI_PACKAGE, sectionId, "openconnect_ip") === "1") {
    params.ip = "1";
  }
  if (uci.get(UCI_PACKAGE, sectionId, "openconnect_esp") === "1") {
    params.esp = "1";
  }
  if (uci.get(UCI_PACKAGE, sectionId, "openconnect_dtls") === "1") {
    params.dtls = "1";
  }
  const query = encodeQuery(params);
  return `openconnect://${auth}${uriHost}:${port}${query ? `?${query}` : ""}#${encodeURIComponent(identity.name || sectionId)}`;
}

function buildAwgClientConfig(sectionId, targetVersion, options = {}) {
  const host = getPublicHost(sectionId, options);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "51820");
  const clientPrivateKey =
    uci.get(UCI_PACKAGE, sectionId, "awg_client_private_key") || "";
  const serverPublicKey =
    uci.get(UCI_PACKAGE, sectionId, "awg_server_public_key") ||
    uci.get(UCI_PACKAGE, sectionId, "awg_peer_public_key") ||
    "";
  const presharedKey =
    uci.get(UCI_PACKAGE, sectionId, "awg_preshared_key") || "";
  const clientAddress =
    uci.get(UCI_PACKAGE, sectionId, "awg_client_address") || "10.0.0.2/32";
  const mtu = uci.get(UCI_PACKAGE, sectionId, "awg_mtu") || "1280";
  const keepalive = uci.get(UCI_PACKAGE, sectionId, "awg_keepalive") || "25";
  const dns = uci.get(UCI_PACKAGE, sectionId, "awg_dns") || "10.0.0.1";

  const effectiveVer =
    targetVersion || uci.get(UCI_PACKAGE, sectionId, "awg_version") || "2.0";

  let conf = `[Interface]\nAddress = ${clientAddress}\nPrivateKey = ${clientPrivateKey}\nDNS = ${dns}\nMTU = ${mtu}\n`;

  if (effectiveVer === "wg") {
    // Pure WireGuard without obfuscation headers
  } else if (effectiveVer === "1.0") {
    // AWG 1.0: Only Jc, Jmin, Jmax, S1, S2, H1, H2, H3, H4
    const jc = uci.get(UCI_PACKAGE, sectionId, "awg_jc") || "4";
    const jmin = uci.get(UCI_PACKAGE, sectionId, "awg_jmin") || "40";
    const jmax = uci.get(UCI_PACKAGE, sectionId, "awg_jmax") || "70";
    const s1 = uci.get(UCI_PACKAGE, sectionId, "awg_s1") || "0";
    const s2 = uci.get(UCI_PACKAGE, sectionId, "awg_s2") || "0";
    const h1 = uci.get(UCI_PACKAGE, sectionId, "awg_h1") || "1";
    const h2 = uci.get(UCI_PACKAGE, sectionId, "awg_h2") || "2";
    const h3 = uci.get(UCI_PACKAGE, sectionId, "awg_h3") || "3";
    const h4 = uci.get(UCI_PACKAGE, sectionId, "awg_h4") || "4";
    conf += `Jc = ${jc}\nJmin = ${jmin}\nJmax = ${jmax}\nS1 = ${s1}\nS2 = ${s2}\nH1 = ${h1}\nH2 = ${h2}\nH3 = ${h3}\nH4 = ${h4}\n`;
  } else {
    // AWG 2.0 / 3.0 / 3.1
    const jc = uci.get(UCI_PACKAGE, sectionId, "awg_jc") || "4";
    const jmin = uci.get(UCI_PACKAGE, sectionId, "awg_jmin") || "40";
    const jmax = uci.get(UCI_PACKAGE, sectionId, "awg_jmax") || "70";
    const s1 = uci.get(UCI_PACKAGE, sectionId, "awg_s1") || "0";
    const s2 = uci.get(UCI_PACKAGE, sectionId, "awg_s2") || "0";
    const s3 = uci.get(UCI_PACKAGE, sectionId, "awg_s3") || "0";
    const s4 = uci.get(UCI_PACKAGE, sectionId, "awg_s4") || "0";
    const h1 = uci.get(UCI_PACKAGE, sectionId, "awg_h1") || "1";
    const h2 = uci.get(UCI_PACKAGE, sectionId, "awg_h2") || "2";
    const h3 = uci.get(UCI_PACKAGE, sectionId, "awg_h3") || "3";
    const h4 = uci.get(UCI_PACKAGE, sectionId, "awg_h4") || "4";
    const i1 = uci.get(UCI_PACKAGE, sectionId, "awg_i1") || "";
    const i2 = uci.get(UCI_PACKAGE, sectionId, "awg_i2") || "";
    const i3 = uci.get(UCI_PACKAGE, sectionId, "awg_i3") || "";
    const i4 = uci.get(UCI_PACKAGE, sectionId, "awg_i4") || "";
    const i5 = uci.get(UCI_PACKAGE, sectionId, "awg_i5") || "";
    const j1 = uci.get(UCI_PACKAGE, sectionId, "awg_j1") || "";
    const j2 = uci.get(UCI_PACKAGE, sectionId, "awg_j2") || "";
    const j3 = uci.get(UCI_PACKAGE, sectionId, "awg_j3") || "";
    const itime = uci.get(UCI_PACKAGE, sectionId, "awg_itime") || "";

    conf += `Jc = ${jc}\nJmin = ${jmin}\nJmax = ${jmax}\nS1 = ${s1}\nS2 = ${s2}\nS3 = ${s3}\nS4 = ${s4}\nH1 = ${h1}\nH2 = ${h2}\nH3 = ${h3}\nH4 = ${h4}\n`;
    if (i1) conf += `I1 = ${i1}\n`;
    if (i2) conf += `I2 = ${i2}\n`;
    if (i3) conf += `I3 = ${i3}\n`;
    if (i4) conf += `I4 = ${i4}\n`;
    if (i5) conf += `I5 = ${i5}\n`;
    if (j1) conf += `J1 = ${j1}\n`;
    if (j2) conf += `J2 = ${j2}\n`;
    if (j3) conf += `J3 = ${j3}\n`;
    if (itime) conf += `Itime = ${itime}\n`;

    if (effectiveVer === "3.0" || effectiveVer === "3.1") {
      const hpk =
        uci.get(UCI_PACKAGE, sectionId, "awg_header_protection_key") || "";
      const cpa =
        uci.get(UCI_PACKAGE, sectionId, "awg_content_padding_addition") || "";
      if (hpk) conf += `HeaderProtectionKey = ${hpk}\n`;
      if (cpa) conf += `ContentPaddingAddition = ${cpa}\n`;
    }
    if (effectiveVer === "3.1") {
      const rka = uci.get(UCI_PACKAGE, sectionId, "awg_rekey_after_time") || "";
      const rkt = uci.get(UCI_PACKAGE, sectionId, "awg_rekey_timeout") || "";
      const rja =
        uci.get(UCI_PACKAGE, sectionId, "awg_reject_after_time") || "";
      const kpt =
        uci.get(UCI_PACKAGE, sectionId, "awg_keepalive_timeout") || "";
      const mha =
        uci.get(UCI_PACKAGE, sectionId, "awg_max_handshake_attempts") || "";
      if (rka) conf += `RekeyAfterTime = ${rka}\n`;
      if (rkt) conf += `RekeyTimeout = ${rkt}\n`;
      if (rja) conf += `RejectAfterTime = ${rja}\n`;
      if (kpt) conf += `KeepaliveTimeout = ${kpt}\n`;
      if (mha) conf += `MaxHandshakeAttempts = ${mha}\n`;
    }
  }

  conf += `\n[Peer]\nPublicKey = ${serverPublicKey}\nEndpoint = ${host}:${port}\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = ${keepalive}\n`;
  if (presharedKey) conf += `PresharedKey = ${presharedKey}\n`;

  return conf;
}

function buildClientLink(sectionId, options = {}) {
  const protocol = getProtocol(sectionId);
  const identity = getServerIdentity(sectionId);

  if (protocol === "tailscale" || protocol === "json_inbound") {
    return "";
  }

  if (protocol === "awg") {
    return buildAwgClientConfig(sectionId, options.awgVersion, options);
  }

  if (
    ((protocol === "vless" || protocol === "vmess" || protocol === "tuic") &&
      !identity.uuid) ||
    (PASSWORD_PROTOCOLS.includes(protocol) &&
      protocol !== "masque" &&
      !identity.password) ||
    (protocol === "mtproto" && !identity.mtprotoSecret) ||
    (protocol === "tewfai" &&
      !(uci.get(UCI_PACKAGE, sectionId, "tewfai_uuid") || identity.uuid)) ||
    (protocol === "openconnect" &&
      !(
        uci.get(UCI_PACKAGE, sectionId, "openconnect_cookie") ||
        identity.password
      ))
  ) {
    return "";
  }

  if (
    protocol === "vless" &&
    getEffectiveSecurity(sectionId) === "reality" &&
    (!uci.get(UCI_PACKAGE, sectionId, "reality_public_key") ||
      !getFirstListValue(sectionId, "reality_short_id"))
  ) {
    return "";
  }

  switch (protocol) {
    case "shadowsocks":
      return buildShadowsocksLink(sectionId, identity, options);
    case "socks":
      return buildSocksLink(sectionId, identity, options);
    case "vmess":
      return buildVmessLink(sectionId, identity, options);
    case "trojan":
      return buildVlessTrojanLink(sectionId, identity, options);
    case "hysteria2":
      return buildHysteria2Link(sectionId, identity, options);
    case "tuic":
      return buildTuicLink(sectionId, identity, options);
    case "anytls":
      return buildAnytlsLink(sectionId, identity, options);
    case "naive":
      return buildNaiveLink(sectionId, identity, options);
    case "shadowtls":
      return buildShadowtlsLink(sectionId, identity, options);
    case "fptn":
      return buildFptnLink(sectionId, identity, options);
    case "http":
      return buildHttpLink(sectionId, identity, options);
    case "mixed":
      return buildMixedLink(sectionId, identity, options);
    case "mtproto":
      return buildMtprotoLink(sectionId, identity, options);
    case "mieru":
      return buildMieruLink(sectionId, identity, options);
    case "trusttunnel":
      return buildTrusttunnelLink(sectionId, identity, options);
    case "tewfai":
      return buildTewfaiLink(sectionId, identity, options);
    case "masque":
      return buildMasqueLink(sectionId, identity, options);
    case "openconnect":
      return buildOpenconnectLink(sectionId, identity, options);
    case "awg":
      return buildAwgClientConfig(sectionId, options.awgVersion, options);
    case "vless":
    default:
      return buildVlessTrojanLink(sectionId, identity, options);
  }
}

function buildClientLinkContext(sectionId) {
  const protocol = getProtocol(sectionId);
  const security = getEffectiveSecurity(sectionId);
  const certificatePinExpected =
    [
      "hysteria2",
      "tuic",
      "anytls",
      "naive",
      "trojan",
      "fptn",
      "vless",
      "vmess",
      "trusttunnel",
      "tewfai",
      "masque",
      "openconnect",
    ].includes(protocol) &&
    security === "tls" &&
    shouldUseGeneratedTlsCertificatePin(sectionId);

  if (!certificatePinExpected) {
    return Promise.resolve({
      link: buildClientLink(sectionId),
      certificatePinExpected,
      tlsCertificateSha256: "",
    });
  }

  return loadGeneratedTlsCertificatePin(sectionId).then(
    (tlsCertificateSha256) => ({
      link: buildClientLink(sectionId, { tlsCertificateSha256 }),
      certificatePinExpected,
      tlsCertificateSha256,
    }),
  );
}

function svgEl(tag, attrs = {}, children = []) {
  const element = document.createElementNS("http://www.w3.org/2000/svg", tag);
  Object.entries(attrs).forEach(([key, value]) => {
    if (value != null) {
      element.setAttribute(key, `${value}`);
    }
  });
  (Array.isArray(children) ? children : [children])
    .filter(Boolean)
    .forEach((child) => element.appendChild(child));
  return element;
}

function iconSvg(name) {
  const attrs = {
    viewBox: "0 0 24 24",
    width: "16",
    height: "16",
    fill: "none",
    stroke: "currentColor",
    "stroke-width": "2",
    "stroke-linecap": "round",
    "stroke-linejoin": "round",
    "aria-hidden": "true",
    focusable: "false",
  };

  if (name === "copy") {
    return svgEl("svg", attrs, [
      svgEl("rect", {
        x: "9",
        y: "9",
        width: "13",
        height: "13",
        rx: "2",
        ry: "2",
      }),
      svgEl("path", {
        d: "M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1",
      }),
    ]);
  }

  if (name === "check") {
    return svgEl("svg", attrs, [
      svgEl("polyline", { points: "20 6 9 17 4 12" }),
    ]);
  }

  if (name === "info") {
    return svgEl("svg", attrs, [
      svgEl("circle", { cx: "12", cy: "12", r: "10" }),
      svgEl("path", { d: "M12 16v-4" }),
      svgEl("path", { d: "M12 8h.01" }),
    ]);
  }

  return svgEl("svg", attrs, [
    svgEl("rect", { x: "3", y: "3", width: "5", height: "5" }),
    svgEl("rect", { x: "16", y: "3", width: "5", height: "5" }),
    svgEl("rect", { x: "3", y: "16", width: "5", height: "5" }),
    svgEl("path", {
      d: "M16 16h1v1h-1zM20 16h1v1h-1zM16 20h1v1h-1zM20 20h1v1h-1zM18 18h1v1h-1z",
    }),
  ]);
}

function copyText(text) {
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.style.position = "fixed";
  textarea.style.top = "0";
  textarea.style.left = "0";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();

  try {
    document.execCommand("copy");
    main.showToast(_("Copied"), "success");
  } catch (error) {
    main.showToast(_("Failed to copy!"), "error");
    console.warn("Failed to copy server client link", error);
  }

  document.body.removeChild(textarea);
}

function getServerHostChoices(sectionId) {
  const configured = normalizeHost(
    uci.get(UCI_PACKAGE, sectionId, "public_host"),
  );
  const env = routerNetworkEnvCache || {};
  const choices = [];
  const seen = new Set();
  const add = (host, label) => {
    const h = normalizeHost(host);
    if (!h || seen.has(h)) return;
    seen.add(h);
    choices.push({ host: h, label });
  };

  if (env.has_ddns && env.ddns_domain) {
    add(env.ddns_domain, `${_("External (DDNS)")}: ${env.ddns_domain}`);
  }
  if (env.cached_external_ip) {
    add(
      env.cached_external_ip,
      `${_("External (WAN)")}: ${env.cached_external_ip}`,
    );
  }
  if (Array.isArray(env.wan_ips)) {
    env.wan_ips.forEach((ip) => {
      add(ip, `${_("External (WAN)")}: ${ip}`);
    });
  }
  if (env.lan_ip) {
    add(env.lan_ip, `${_("Local (LAN)")}: ${env.lan_ip}`);
  }
  if (configured) {
    add(
      configured,
      isPrivateOrReservedIp(configured) && isIpv4(configured)
        ? `${_("Local (LAN)")}: ${configured}`
        : `${_("External")}: ${configured}`,
    );
  }
  const browserHost = getBrowserHost();
  if (
    browserHost &&
    browserHost !== "localhost" &&
    browserHost !== "127.0.0.1"
  ) {
    add(
      browserHost,
      isPrivateOrReservedIp(browserHost) && isIpv4(browserHost)
        ? `${_("Local (LAN)")}: ${browserHost}`
        : `${_("Address")}: ${browserHost}`,
    );
  }
  return choices;
}

function renderInfoClientLink(sectionId, linkContext = {}) {
  const protocol = getProtocol(sectionId);
  const security = getEffectiveSecurity(sectionId);
  let activeHost = getPublicHost(sectionId);
  const port =
    uci.get(UCI_PACKAGE, sectionId, "listen_port") ||
    (typeof getServerPort === "function" ? getServerPort(sectionId) : "443");
  const name = getServerName(sectionId);
  const identity = getServerIdentity(sectionId);
  const hostChoices = getServerHostChoices(sectionId);

  let activeAwgVersion =
    uci.get(UCI_PACKAGE, sectionId, "awg_version") || "2.0";

  const computeLink = (hostOverride) =>
    protocol === "awg"
      ? buildAwgClientConfig(sectionId, activeAwgVersion, { hostOverride })
      : buildClientLink(sectionId, {
          tlsCertificateSha256: linkContext.tlsCertificateSha256 || "",
          hostOverride,
        });

  let currentLink = computeLink(activeHost);

  if (!currentLink && protocol !== "fptn") {
    return E(
      "div",
      {
        class: "alert-message warning",
        style: "margin: 1rem 0; text-align: left;",
      },
      [
        E("strong", {}, _("Client link is not available yet")),
        E(
          "div",
          { style: "margin-top: 0.5rem;" },
          _(
            "Server configuration is incomplete. Please edit the server settings and apply changes.",
          ),
        ),
      ],
    );
  }

  let fptnQrMode = "link";
  const qrUri =
    protocol === "fptn"
      ? qrSvgDataUri(
          buildFptnLink(sectionId, identity, { hostOverride: activeHost }),
        )
      : qrSvgDataUri(currentLink || "");

  const securitySuffix =
    security && security !== "none" ? ` + ${getSecurityLabel(security)}` : "";
  const protocolText = `${getProtocolLabel(protocol)}${securitySuffix}`;
  const certificatePinWarning =
    protocol === "hysteria2" &&
    linkContext.certificatePinExpected &&
    !linkContext.tlsCertificateSha256
      ? E(
          "div",
          { class: "fkp-server-info-modal__warning alert-message warning" },
          _(
            "Certificate pin is unavailable. Apply or restart the server to generate the default certificate, then open this dialog again.",
          ),
        )
      : "";

  let qrImg = E("img", {
    class: "fkp-server-info-modal__qr-image",
    src: qrUri,
    alt: _("Client link QR code"),
  });

  const qrCard = E(
    "div",
    { class: "fkp-server-info-modal__qr-card" },
    qrUri ? qrImg : E("em", {}, _("QR code is too large")),
  );

  const qrColChildren = [
    qrCard,
    qrUri
      ? E("span", { class: "fkp-server-info-modal__qr-hint" }, _("QR code"))
      : "",
  ];

  if (protocol === "fptn") {
    const btnLink = E(
      "button",
      {
        class: "btn cbi-button cbi-button-action",
        type: "button",
        style: "padding:2px 8px;font-size:11px;",
        click: (ev) => {
          ev.preventDefault();
          fptnQrMode = "link";
          btnLink.className = "btn cbi-button cbi-button-action";
          btnToken.className = "btn cbi-button cbi-button-neutral";
          qrImg.src = qrSvgDataUri(
            buildFptnLink(sectionId, identity, { hostOverride: activeHost }),
          );
        },
      },
      _("QR: Link"),
    );

    const btnToken = E(
      "button",
      {
        class: "btn cbi-button cbi-button-neutral",
        type: "button",
        style: "padding:2px 8px;font-size:11px;",
        click: (ev) => {
          ev.preventDefault();
          fptnQrMode = "token";
          btnToken.className = "btn cbi-button cbi-button-action";
          btnLink.className = "btn cbi-button cbi-button-neutral";
          qrImg.src = qrSvgDataUri(
            buildFptnToken(sectionId, identity, { hostOverride: activeHost }),
          );
        },
      },
      _("QR: Token"),
    );

    qrColChildren.push(
      E(
        "div",
        {
          style: "display:flex;gap:4px;margin-top:8px;justify-content:center;",
        },
        [btnLink, btnToken],
      ),
    );
  }

  const qrCol = E(
    "div",
    { class: "fkp-server-info-modal__qr-col" },
    qrColChildren,
  );

  const addressValueNode = E(
    "span",
    {
      class:
        "fkp-server-info-modal__detail-value fkp-server-info-modal__detail-value--mono",
    },
    `${activeHost}:${port}`,
  );

  const detailsGrid = E(
    "div",
    { class: "fkp-server-info-modal__details-grid" },
    [
      E("div", { class: "fkp-server-info-modal__detail-item" }, [
        E(
          "span",
          { class: "fkp-server-info-modal__detail-label" },
          _("Server name"),
        ),
        E(
          "span",
          {
            class:
              "fkp-server-info-modal__detail-value fkp-server-info-modal__detail-value--title",
          },
          name,
        ),
      ]),
      E("div", { class: "fkp-server-info-modal__detail-item" }, [
        E("span", { class: "fkp-server-info-modal__detail-label" }, _("Type")),
        E(
          "span",
          {
            class:
              "fkp-server-info-modal__detail-value fkp-server-info-modal__badge",
          },
          protocolText,
        ),
      ]),
      E("div", { class: "fkp-server-info-modal__detail-item" }, [
        E(
          "span",
          { class: "fkp-server-info-modal__detail-label" },
          _("Address"),
        ),
        addressValueNode,
      ]),
    ],
  );

  const linkSection = E("div", {
    class: "fkp-server-info-modal__link-section",
  });

  let onHostChange = null;
  if (hostChoices.length > 1) {
    const hostBar = E("div", {
      style: "display:flex;gap:6px;margin-bottom:8px;flex-wrap:wrap;",
    });
    const hostBtns = {};
    hostChoices.forEach((choice) => {
      const btn = E(
        "button",
        {
          class: `btn cbi-button ${choice.host === activeHost ? "cbi-button-action" : "cbi-button-neutral"}`,
          type: "button",
          style: "padding:3px 10px;font-size:12px;",
          click: (ev) => {
            ev.preventDefault();
            activeHost = choice.host;
            Object.entries(hostBtns).forEach(([h, b]) => {
              b.className = `btn cbi-button ${h === activeHost ? "cbi-button-action" : "cbi-button-neutral"}`;
            });
            addressValueNode.textContent = `${activeHost}:${port}`;
            if (typeof onHostChange === "function") {
              onHostChange(activeHost);
            }
          },
        },
        choice.label,
      );
      hostBtns[choice.host] = btn;
      hostBar.appendChild(btn);
    });
    linkSection.appendChild(
      E(
        "span",
        { class: "fkp-server-info-modal__detail-label" },
        _("Router address"),
      ),
    );
    linkSection.appendChild(hostBar);
  }

  if (protocol === "fptn") {
    let fptnToken = buildFptnToken(sectionId, identity, {
      hostOverride: activeHost,
    });
    let fptnLink = buildFptnLink(sectionId, identity, {
      hostOverride: activeHost,
    });

    linkSection.appendChild(
      E(
        "span",
        { class: "fkp-server-info-modal__detail-label" },
        _("Access Token (FPTN)"),
      ),
    );
    const tokenTextarea = E(
      "textarea",
      {
        class: "cbi-input-textarea fkp-server-info-modal__link",
        readonly: "readonly",
        rows: 3,
        click: (ev) => ev.currentTarget.select(),
      },
      fptnToken,
    );
    linkSection.appendChild(tokenTextarea);

    const tokenBtnRow = E(
      "div",
      { style: "display:flex;gap:6px;margin-bottom:12px;margin-top:4px;" },
      [
        E(
          "button",
          {
            class:
              "btn cbi-button cbi-button-action fkp-server-info-modal__copy-btn",
            type: "button",
            click: (ev) => {
              ev.preventDefault();
              copyText(fptnToken);
            },
          },
          [iconSvg("copy"), " ", E("span", {}, _("Copy Token"))],
        ),
      ],
    );
    linkSection.appendChild(tokenBtnRow);

    linkSection.appendChild(
      E(
        "span",
        { class: "fkp-server-info-modal__detail-label" },
        _("Client link"),
      ),
    );
    const linkTextarea = E(
      "textarea",
      {
        class: "cbi-input-textarea fkp-server-info-modal__link",
        readonly: "readonly",
        rows: 2,
        click: (ev) => ev.currentTarget.select(),
      },
      fptnLink,
    );
    linkSection.appendChild(linkTextarea);

    const linkBtnRow = E(
      "div",
      { style: "display:flex;gap:6px;margin-top:4px;" },
      [
        E(
          "button",
          {
            class:
              "btn cbi-button cbi-button-neutral fkp-server-info-modal__copy-btn",
            type: "button",
            click: (ev) => {
              ev.preventDefault();
              copyText(fptnLink);
            },
          },
          [iconSvg("copy"), " ", E("span", {}, _("Copy Link"))],
        ),
      ],
    );
    linkSection.appendChild(linkBtnRow);
    onHostChange = (nextHost) => {
      fptnToken = buildFptnToken(sectionId, identity, {
        hostOverride: nextHost,
      });
      fptnLink = buildFptnLink(sectionId, identity, { hostOverride: nextHost });
      tokenTextarea.value = fptnToken;
      linkTextarea.value = fptnLink;
      const newQr = qrSvgDataUri(fptnQrMode === "token" ? fptnToken : fptnLink);
      if (newQr) qrImg.src = newQr;
    };
  } else if (protocol === "awg") {
    const awgVersions = [
      { id: "2.0", label: "AmneziaWG 2.0" },
      { id: "1.0", label: "AmneziaWG 1.0" },
      { id: "3.0", label: "AmneziaWG 3.0" },
      { id: "wg", label: "WireGuard" },
    ];

    const versionBar = E("div", {
      style: "display:flex;gap:6px;margin-bottom:8px;flex-wrap:wrap;",
    });

    const confTextarea = E(
      "textarea",
      {
        class: "cbi-input-textarea fkp-server-info-modal__link",
        readonly: "readonly",
        rows: 6,
        style: "font-family:monospace;font-size:11px;",
        click: (ev) => ev.currentTarget.select(),
      },
      currentLink,
    );

    const vBtns = {};

    const selectVersion = (vId) => {
      activeAwgVersion = vId;
      Object.entries(vBtns).forEach(([id, b]) => {
        if (id === vId) {
          b.className = "btn cbi-button cbi-button-action";
        } else {
          b.className = "btn cbi-button cbi-button-neutral";
        }
      });
      currentLink = buildAwgClientConfig(sectionId, activeAwgVersion, {
        hostOverride: activeHost,
      });
      confTextarea.value = currentLink;
      const newQr = qrSvgDataUri(currentLink);
      if (newQr) qrImg.src = newQr;
    };

    onHostChange = (nextHost) => {
      currentLink = buildAwgClientConfig(sectionId, activeAwgVersion, {
        hostOverride: nextHost,
      });
      confTextarea.value = currentLink;
      const newQr = qrSvgDataUri(currentLink);
      if (newQr) qrImg.src = newQr;
    };

    awgVersions.forEach((v) => {
      const btn = E(
        "button",
        {
          class: `btn cbi-button ${v.id === activeAwgVersion ? "cbi-button-action" : "cbi-button-neutral"}`,
          type: "button",
          style: "padding:3px 10px;font-size:12px;",
          click: (ev) => {
            ev.preventDefault();
            selectVersion(v.id);
          },
        },
        v.label,
      );
      vBtns[v.id] = btn;
      versionBar.appendChild(btn);
    });

    linkSection.appendChild(
      E(
        "span",
        { class: "fkp-server-info-modal__detail-label" },
        _("Protocol Version"),
      ),
    );
    linkSection.appendChild(versionBar);

    linkSection.appendChild(
      E(
        "span",
        { class: "fkp-server-info-modal__detail-label" },
        _("Configuration File"),
      ),
    );
    linkSection.appendChild(confTextarea);

    const btnRow = E("div", { style: "display:flex;gap:6px;margin-top:6px;" }, [
      E(
        "button",
        {
          class:
            "btn cbi-button cbi-button-neutral fkp-server-info-modal__copy-btn",
          type: "button",
          click: (ev) => {
            ev.preventDefault();
            copyText(currentLink);
          },
        },
        [iconSvg("copy"), " ", E("span", {}, _("Copy"))],
      ),
      E(
        "button",
        {
          class:
            "btn cbi-button cbi-button-action fkp-server-info-modal__copy-btn",
          type: "button",
          click: (ev) => {
            ev.preventDefault();
            const blob = new Blob([currentLink], {
              type: "text/plain;charset=utf-8",
            });
            const url = URL.createObjectURL(blob);
            const a = document.createElement("a");
            a.href = url;
            a.download = `${name || "amneziawg"}_${activeAwgVersion}.conf`;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
          },
        },
        [E("span", {}, _("Download .conf"))],
      ),
    ]);
    linkSection.appendChild(btnRow);
  } else {
    linkSection.appendChild(
      E(
        "span",
        { class: "fkp-server-info-modal__detail-label" },
        _("Client link"),
      ),
    );
    if (certificatePinWarning) {
      linkSection.appendChild(certificatePinWarning);
    }
    const linkTextarea = E(
      "textarea",
      {
        class: "cbi-input-textarea fkp-server-info-modal__link",
        readonly: "readonly",
        rows: 3,
        click: (ev) => ev.currentTarget.select(),
      },
      currentLink,
    );
    linkSection.appendChild(linkTextarea);

    onHostChange = (nextHost) => {
      currentLink = computeLink(nextHost);
      linkTextarea.value = currentLink;
      const newQr = qrSvgDataUri(currentLink);
      if (newQr) qrImg.src = newQr;
    };

    const btnRow = E("div", { style: "display:flex;gap:6px;margin-top:6px;" }, [
      E(
        "button",
        {
          class:
            "btn cbi-button cbi-button-neutral fkp-server-info-modal__copy-btn",
          type: "button",
          click: (ev) => {
            ev.preventDefault();
            copyText(currentLink);
          },
        },
        [iconSvg("copy"), " ", E("span", {}, _("Copy"))],
      ),
    ]);
    linkSection.appendChild(btnRow);
  }

  const detailsCol = E("div", { class: "fkp-server-info-modal__details-col" }, [
    detailsGrid,
    linkSection,
  ]);

  return E("div", { class: "fkp-server-info-modal__container" }, [
    qrCol,
    detailsCol,
  ]);
}

function showServerInfoModal(sectionId) {
  const modalContent = E("div", { class: "fkp-server-info-modal" }, [
    E("em", {}, _("Loading client link...")),
  ]);

  ui.showModal(
    _("Server information"),
    [
      modalContent,
      E("div", { class: "button-row" }, [
        E(
          "button",
          {
            class: "btn cbi-button cbi-button-neutral",
            type: "button",
            click: () => ui.hideModal(),
          },
          _("Close"),
        ),
      ]),
    ],
    "fkp-server-info-dialog",
  );

  prepareServerModal(sectionId)
    .then(() => buildClientLinkContext(sectionId))
    .then((linkContext) => {
      modalContent.innerHTML = "";
      modalContent.appendChild(renderInfoClientLink(sectionId, linkContext));
    })
    .catch((error) => {
      console.warn(error?.message || "Failed to build client link", error);
      modalContent.innerHTML = "";
      modalContent.appendChild(renderInfoClientLink(sectionId));
    });
}

function getServerEditButtonText() {
  return _("Edit");
}

function renderServerRowActions(sectionRef, sectionId) {
  const editLabel = getServerEditButtonText();
  const deleteLabel = _("Delete");
  const infoLabel = _("Information");
  const tdEl = E(
    "td",
    { class: "td cbi-section-table-cell nowrap cbi-section-actions" },
    E("div"),
  );
  const actionsEl = tdEl.lastElementChild;
  const actionButtons = [];

  if (!["tailscale", "json_inbound"].includes(getProtocol(sectionId))) {
    actionButtons.push(
      E(
        "button",
        {
          type: "button",
          title: infoLabel,
          "aria-label": infoLabel,
          class: "cbi-button center fkp-server-icon-button",
          style: "display:inline-block;",
          click: (ev) => {
            ev.preventDefault();
            ev.stopPropagation();
            showServerInfoModal(sectionId);
          },
        },
        E("span", { class: "fkp-server-icon-button__glyph" }, "\u24D8"),
      ),
    );
  }

  dom.append(actionsEl, [
    ...actionButtons,
    E(
      "button",
      {
        title: editLabel,
        class: "btn cbi-button cbi-button-edit",
        click: ui.createHandlerFn(
          sectionRef,
          "renderMoreOptionsModal",
          sectionId,
        ),
      },
      editLabel,
    ),
  ]);

  if (sectionRef.addremove) {
    dom.append(
      actionsEl,
      E(
        "button",
        {
          title: deleteLabel,
          class: "btn cbi-button cbi-button-remove",
          click: ui.createHandlerFn(sectionRef, "handleRemove", sectionId),
          disabled: sectionRef.map.readonly || null,
        },
        deleteLabel,
      ),
    );
  }

  return tdEl;
}

function validatePort(_sectionId, value) {
  const port = parseInt(value, 10);
  if (!/^[0-9]+$/.test(value) || port < 1 || port > 65535) {
    return _("Port must be between 1 and 65535");
  }
  return true;
}

function validateOptionalPort(_sectionId, value) {
  if (isEmptyValue(value)) return true;
  return validatePort(_sectionId, value);
}

function validatePositiveInteger(_sectionId, value) {
  if (isEmptyValue(value)) {
    return _("This field is required");
  }
  const n = parseInt(value, 10);
  if (!/^[0-9]+$/.test(`${value}`) || isNaN(n) || n <= 0) {
    return _("Value must be a positive integer");
  }
  return true;
}

function isEmptyValue(value) {
  return (
    value == null ||
    value === "" ||
    (Array.isArray(value) &&
      value.filter((item) => item != null && item !== "").length === 0)
  );
}

function validateRequired(_sectionId, value) {
  return isEmptyValue(value) ? _("This field is required") : true;
}

function validateRequiredText(_sectionId, value) {
  if (isEmptyValue(value)) {
    return _("This field is required");
  }

  return /[\u0000-\u001F\u007F]/.test(`${value}`)
    ? _("Value must not contain control characters")
    : true;
}

function isRoutingSectionAction(action) {
  return ROUTING_SECTION_ACTIONS.indexOf(`${action || ""}`) !== -1;
}

function loadRoutingSectionChoices(option) {
  const sections = option.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};

  option.keylist = [];
  option.vallist = [];

  for (const sectionName in sections) {
    const section = sections[sectionName];

    if (
      section[".type"] === "section" &&
      section.enabled !== "0" &&
      isRoutingSectionAction(section.action)
    ) {
      option.keylist.push(sectionName);
      option.vallist.push(section.label || sectionName);
    }
  }

  return Promise.resolve();
}

function loadServerTableOptions(sectionRef) {
  const sectionIds = sectionRef.cfgsections();
  const tasks = [];

  for (let i = 0; i < sectionIds.length; i += 1) {
    const sectionId = sectionIds[i];

    for (let j = 0; j < sectionRef.children.length; j += 1) {
      const option = sectionRef.children[j];

      if (option.disable || option.modalonly) {
        continue;
      }

      tasks.push(
        Promise.resolve(option.load.call(option, sectionId)).then((value) => {
          option.cfgvalue(sectionId, value);
        }),
      );
    }
  }

  return Promise.all(tasks);
}

function validateHost(_sectionId, value) {
  return isHost(value) ? true : _("Use a domain name or IP address");
}

function validateOptionalHost(_sectionId, value) {
  return isEmptyValue(value) || isHost(value)
    ? true
    : _("Use a domain name or IP address");
}

function validateListenAddress(_sectionId, value) {
  const address = normalizeHost(value);
  return address === "0.0.0.0" ||
    address === "::" ||
    isIpv4(address) ||
    isIpv6(address)
    ? true
    : _("Use an IP listen address");
}

function validateOptionalIp(_sectionId, value) {
  const address = normalizeHost(value);
  return isEmptyValue(value) || isIpv4(address) || isIpv6(address)
    ? true
    : _("Use an IP address");
}

function validateFilePath(_sectionId, value) {
  const path = `${value || ""}`;

  if (isEmptyValue(path)) {
    return _("This field is required");
  }

  const validation = main.validatePath(path);
  return validation.valid && path !== "/" && !path.endsWith("/")
    ? true
    : _("Specify a file path");
}

function validateTlsCertificatePath(sectionId, value) {
  const result = validateFilePath(sectionId, value);
  if (result !== true) {
    return result;
  }

  return `${value}` ===
    `${uci.get(UCI_PACKAGE, sectionId, "tls_key_path") || ""}`
    ? _("Specify different files")
    : true;
}

function validateTlsKeyPath(sectionId, value) {
  const result = validateFilePath(sectionId, value);
  if (result !== true) {
    return result;
  }

  return `${value}` ===
    `${uci.get(UCI_PACKAGE, sectionId, "tls_certificate_path") || ""}`
    ? _("Specify different files")
    : true;
}

function validateHttpUrl(_sectionId, value) {
  try {
    const url = new URL(`${value || ""}`);
    return (url.protocol === "http:" || url.protocol === "https:") &&
      isHost(url.hostname)
      ? true
      : _("Use an HTTP or HTTPS URL");
  } catch (_err) {
    return _("Use an HTTP or HTTPS URL");
  }
}

function validateInboundJson(_sectionId, value) {
  if (isEmptyValue(value)) {
    return _("Inbound JSON cannot be empty");
  }

  try {
    const parsed = JSON.parse(`${value}`);
    return parsed &&
      typeof parsed === "object" &&
      !Array.isArray(parsed) &&
      typeof parsed.type === "string" &&
      parsed.type
      ? true
      : _("Inbound JSON must be an object with a type field");
  } catch (_err) {
    return _("Invalid JSON format");
  }
}

function validateDurationValue(value) {
  return /^([0-9]+(ns|us|ms|s|m|h))+$/.test(`${value || ""}`);
}

function validateRequiredDuration(_sectionId, value) {
  return validateDurationValue(value)
    ? true
    : _("Use a duration like 30s, 5m, or 1h30m");
}

function validateOptionalNonNegativeInteger(_sectionId, value) {
  return isEmptyValue(value) || /^[0-9]+$/.test(`${value}`)
    ? true
    : _("Use a non-negative integer");
}

function validateTransportPath(_sectionId, value) {
  return isEmptyValue(value) || `${value}`.startsWith("/")
    ? true
    : _("Transport path must start with /");
}

function validateOptionalHostList(_sectionId, value) {
  const values = Array.isArray(value) ? value : [value];
  const invalid = values
    .filter((item) => item != null && item !== "")
    .some((item) => !isHost(item));

  return invalid ? _("Use a domain name or IP address") : true;
}

function validateGrpcServiceName(_sectionId, value) {
  return isEmptyValue(value) || /^[A-Za-z0-9_.-]+$/.test(`${value}`)
    ? true
    : _("Use letters, digits, dots, underscores, or hyphens");
}

function isIpv6Literal(value) {
  return isIpv6(value);
}

function normalizeCidrOrIp(value) {
  const normalized = `${value || ""}`.trim();
  if (!normalized.includes("/") && isIpv4(normalized)) {
    return `${normalized}/32`;
  }
  if (!normalized.includes("/") && isIpv6Literal(normalized)) {
    return `${normalized}/128`;
  }
  return normalized;
}

function validateOptionalCidr(value) {
  if (isEmptyValue(value)) {
    return true;
  }

  const values = Array.isArray(value) ? value : [value];
  const invalid = values
    .filter((item) => item != null && item !== "")
    .some((item) => {
      const [address, prefix, extra] = `${item}`.split("/");
      if (extra != null || prefix == null || !/^[0-9]+$/.test(prefix)) {
        return true;
      }
      const prefixNumber = parseInt(prefix, 10);
      if (isIpv4(address)) {
        return prefixNumber < 0 || prefixNumber > 32;
      }
      if (isIpv6Literal(address)) {
        return prefixNumber < 0 || prefixNumber > 128;
      }
      return true;
    });

  return invalid
    ? _("Use CIDR prefixes like 192.168.1.0/24 or 2001:db8::/32")
    : true;
}

function validateOptionalCidrOrIp(value) {
  if (isEmptyValue(value)) {
    return true;
  }
  const values = Array.isArray(value) ? value : [value];
  const invalid = values
    .filter((item) => item != null && item !== "")
    .some((item) => validateOptionalCidr(normalizeCidrOrIp(item)) !== true);

  return invalid
    ? _(
        "Use CIDR prefixes or IP addresses like 192.168.1.0/24, 192.168.1.10, or 2001:db8::1",
      )
    : true;
}

function validateShortId(_sectionId, value) {
  if (isEmptyValue(value)) {
    return _("This field is required");
  }

  const values = Array.isArray(value) ? value : [value];
  const invalid = values
    .filter((item) => item != null && item !== "")
    .some((item) => !/^[0-9a-fA-F]{1,8}$/.test(`${item}`));

  if (invalid) {
    return _("Reality short ID must contain 1-8 hex digits");
  }
  return true;
}

function validateMtprotoSecret(_sectionId, value) {
  const secret = normalizeMtprotoBaseSecret(value);

  if (!secret) {
    return _("Use 32 hex characters");
  }
  if (secret === "00000000000000000000000000000000") {
    return _("Use a non-zero secret");
  }

  return true;
}

function validateSecurity(sectionId, value) {
  const protocol = getProtocol(sectionId);
  const selectedSecurity = value || getDefaultSecurity(protocol);
  const supportedSecurity = SECURITY_BY_PROTOCOL[protocol] || ["none"];

  return supportedSecurity.includes(selectedSecurity)
    ? true
    : _("Unsupported security mode for this protocol");
}

function getWidget(sectionId, option) {
  return document.getElementById(
    `widget.cbid.${UCI_PACKAGE}.${sectionId}.${option}`,
  );
}

function getControlWidget(sectionId, option) {
  const widget = getWidget(sectionId, option);

  if (!widget) {
    return null;
  }

  if (/^(INPUT|SELECT|TEXTAREA)$/.test(widget.tagName)) {
    return widget;
  }

  return typeof widget.querySelector === "function"
    ? widget.querySelector("input:not([type='hidden']), select, textarea")
    : null;
}

function getSelectWidget(sectionId, option) {
  const widget = getControlWidget(sectionId, option);

  return widget && widget.tagName === "SELECT" ? widget : null;
}

function setWidgetValue(sectionId, option, value) {
  const container = getWidget(sectionId, option);
  const widget = getControlWidget(sectionId, option);

  uci.set(UCI_PACKAGE, sectionId, option, value);

  if (container && typeof dom.findClassInstance === "function") {
    const instance = dom.findClassInstance(container);
    if (instance && typeof instance.setValue === "function") {
      instance.setValue(value);
      container.classList.remove("cbi-input-invalid");
      if (widget) {
        widget.classList.remove("cbi-input-invalid");
      }
      return;
    }
  }

  if (!widget) {
    return;
  }

  if (widget.type === "checkbox") {
    widget.checked = value === "1" || value === true || value === "true";
  } else {
    widget.value = value;
  }
  widget.classList.remove("cbi-input-invalid");
  widget.dispatchEvent(new Event("input", { bubbles: true }));
  widget.dispatchEvent(new Event("change", { bubbles: true }));
}

function populateListenAddressChoices(option, env) {
  resetOptionValues(option);
  addOptionValue(option, "0.0.0.0", `${_("All IPv4 interfaces")} (0.0.0.0)`);
  addOptionValue(option, "::", `${_("All IPv4/IPv6 interfaces")} (::)`);

  const lanIp = normalizeHost(env?.lan_ip);
  if (lanIp) {
    addOptionValue(option, lanIp, `${_("Local (LAN)")} — ${lanIp}`);
  }

  if (Array.isArray(env?.wan_ips)) {
    for (const rawIp of env.wan_ips) {
      const wanIp = normalizeHost(rawIp);
      if (wanIp) {
        addOptionValue(
          option,
          wanIp,
          `${_("External (WAN interface)")} — ${wanIp}`,
        );
      }
    }
  }

  addOptionValue(option, "127.0.0.1", `${_("Localhost")} (127.0.0.1)`);
}

function populatePublicHostChoices(option, env) {
  resetOptionValues(option);

  const ddnsDomain = normalizeHost(env?.ddns_domain);
  if (ddnsDomain) {
    addOptionValue(
      option,
      ddnsDomain,
      `${_("External (DDNS)")} — ${ddnsDomain}`,
    );
  }

  const cachedExternalIp = normalizeHost(env?.cached_external_ip);
  if (cachedExternalIp) {
    addOptionValue(
      option,
      cachedExternalIp,
      `${_("External (WAN IP)")} — ${cachedExternalIp}`,
    );
  }

  if (Array.isArray(env?.wan_ips)) {
    for (const rawIp of env.wan_ips) {
      const wanIp = normalizeHost(rawIp);
      if (wanIp) {
        addOptionValue(
          option,
          wanIp,
          `${_("External (WAN interface)")} — ${wanIp}`,
        );
      }
    }
  }

  const lanIp = normalizeHost(env?.lan_ip);
  if (lanIp) {
    addOptionValue(option, lanIp, `${_("Local (LAN)")} — ${lanIp}`);
  }

  const browserHost = getBrowserHost();
  if (browserHost) {
    addOptionValue(
      option,
      browserHost,
      `${_("Current router address")} — ${browserHost}`,
    );
  }
}

function renderSecurityChoices(select, protocol, selectedSecurity) {
  select.replaceChildren(
    ...(SECURITY_BY_PROTOCOL[protocol] || ["none"]).map((security) =>
      E(
        "option",
        {
          value: security,
          selected: security === selectedSecurity ? "" : null,
        },
        getSecurityLabel(security),
      ),
    ),
  );
}

function syncSecurityChoices(sectionId) {
  const protocol = getProtocol(sectionId);
  const select = getSelectWidget(sectionId, "security");
  const selectedSecurity =
    uci.get(UCI_PACKAGE, sectionId, "security") || getDefaultSecurity(protocol);
  const nextSecurity =
    validateSecurity(sectionId, selectedSecurity) === true
      ? selectedSecurity
      : getDefaultSecurity(protocol);

  if (select) {
    renderSecurityChoices(select, protocol, nextSecurity);
    if (
      Array.from(select.options).some((option) => option.value === nextSecurity)
    ) {
      select.value = nextSecurity;
    }
  }

  if (selectedSecurity !== nextSecurity) {
    uci.set(UCI_PACKAGE, sectionId, "security", nextSecurity);
  }

  if (select) {
    select.dispatchEvent(new Event("input", { bubbles: true }));
    select.dispatchEvent(new Event("change", { bubbles: true }));
  }
}

function syncProtocolWidgetValues(sectionId, _protocol) {
  const optionsToSync = [
    "listen",
    "listen_port",
    "security",
    "server_username",
    "server_password",
    "server_uuid",
    "tls_server_name",
    "tls_certificate_path",
    "tls_key_path",
    "public_host",
    "vless_flow",
    "reality_handshake_server",
    "reality_handshake_server_port",
    "reality_short_id",
    "reality_max_time_difference",
    "client_fingerprint",
    "hysteria2_obfs_type",
    "hysteria2_obfs_password",
    "tuic_congestion_control",
    "shadowtls_handshake_server",
    "shadowtls_handshake_server_port",
    "shadowtls_version",
    "shadowsocks_method",
    "mieru_transport",
    "trusttunnel_quic",
    "tewfai_uuid",
    "tewfai_password",
    "tewfai_inbound_transport",
    "masque_ipv4_pool",
    "masque_ipv6_pool",
    "masque_mtu",
    "openconnect_cookie",
    "openconnect_flavor",
    "openconnect_user_agent",
    "openconnect_local_hostname",
    "openconnect_urlpath",
    "openconnect_address",
    "openconnect_mtu",
    "openconnect_ip",
    "openconnect_esp",
    "openconnect_dtls",
    "awg_local_address",
    "awg_client_address",
    "awg_dns",
    "awg_mtu",
    "awg_keepalive",
    "awg_version",
    "awg_jc",
    "awg_jmin",
    "awg_jmax",
    "awg_s1",
    "awg_s2",
    "awg_s3",
    "awg_s4",
    "awg_h1",
    "awg_h2",
    "awg_h3",
    "awg_h4",
    "tailscale_control_url",
    "tailscale_hostname",
    "tailscale_advertise_exit_node",
    "mtproto_secret",
    "mtproto_faketls",
    "mtproto_padding",
    "mtproto_domain_fronting_port",
    "mtproto_prefer_ip",
    "mtproto_tolerate_time_skewness",
    "mtproto_idle_timeout",
    "mtproto_handshake_timeout",
  ];

  for (const opt of optionsToSync) {
    const val = uci.get(UCI_PACKAGE, sectionId, opt);
    if (val != null && val !== "") {
      const widget = getControlWidget(sectionId, opt);
      if (widget && (!widget.value || widget.value === "")) {
        setWidgetValue(sectionId, opt, val);
      }
    }
  }
}

function getModalNode() {
  return (
    document.querySelector("#modal_overlay .modal.cbi-modal") ||
    document.querySelector(".modal.cbi-modal") ||
    document.querySelector("#modal_overlay .modal") ||
    document.querySelector(".cbi-modal")
  );
}

function clearServerValidationMessage() {
  const modal = getModalNode();

  if (modal) {
    modal
      .querySelectorAll(".fkp-server-validation-summary")
      .forEach((node) => node.remove());
  }
}

function showServerValidationMessage(error) {
  const modal = getModalNode();

  if (!modal) {
    return;
  }

  clearServerValidationMessage();

  const message = error?.message || "";
  const summary = E(
    "div",
    {
      class: "alert-message warning fkp-server-validation-summary",
    },
    [
      E("strong", {}, _("Cannot save server")),
      E("div", {}, _("Fix the highlighted fields and save again.")),
      message ? E("small", {}, message) : "",
    ],
  );
  const buttonRow = modal.querySelector(".button-row");
  modal.insertBefore(summary, buttonRow || modal.firstChild);

  const invalidInput = modal.querySelector(".cbi-input-invalid");
  if (invalidInput) {
    invalidInput.scrollIntoView({ block: "center", behavior: "smooth" });
    invalidInput.focus({ preventScroll: true });
  }
}

function hasRealityKeypair(sectionId) {
  return (
    !!uci.get(UCI_PACKAGE, sectionId, "reality_private_key") &&
    !!uci.get(UCI_PACKAGE, sectionId, "reality_public_key")
  );
}

function generateRealityKeypair(sectionId) {
  return fs
    .exec("/usr/bin/tachyon", ["generate_reality_keypair"])
    .then((response) => {
      if ((response.code ?? 0) !== 0 || !response.stdout) {
        throw new Error(response.stderr || response.stdout || "");
      }

      const data = JSON.parse(response.stdout);
      if (!data.success || !data.private_key || !data.public_key) {
        throw new Error(data.message || "");
      }

      setWidgetValue(sectionId, "reality_private_key", data.private_key);
      setWidgetValue(sectionId, "reality_public_key", data.public_key);
    })
    .catch((error) => {
      console.warn(
        error?.message || "Failed to generate Reality key pair",
        error,
      );
    });
}

function generateRealityKeypairIfMissing(sectionId) {
  return hasRealityKeypair(sectionId)
    ? Promise.resolve()
    : generateRealityKeypair(sectionId);
}

function shouldGenerateRealityKeypair(sectionId) {
  return (
    getProtocol(sectionId) === "vless" &&
    getEffectiveSecurity(sectionId) === "reality"
  );
}

function generateAwgKeypair(sectionId) {
  return fs
    .exec("/usr/bin/tachyon", ["generate_wg_keypair"])
    .then((response) => {
      const text = response?.stdout || "";
      const matchPriv = text.match(/PrivateKey:\s*([^\s]+)/);
      const matchPub = text.match(/PublicKey:\s*([^\s]+)/);
      if (matchPriv && matchPub) {
        return {
          private_key: matchPriv[1],
          public_key: matchPub[1],
        };
      }
      return null;
    })
    .catch(() => null);
}

function generateAwgKeypairsIfMissing(sectionId) {
  const currentServerPriv = uci.get(UCI_PACKAGE, sectionId, "awg_private_key");
  const currentPeerPub = uci.get(UCI_PACKAGE, sectionId, "awg_peer_public_key");
  if (currentServerPriv && currentPeerPub) {
    return Promise.resolve();
  }

  return Promise.all([
    generateAwgKeypair(sectionId),
    generateAwgKeypair(sectionId),
  ]).then(([srvPair, cliPair]) => {
    if (srvPair) {
      uci.set(UCI_PACKAGE, sectionId, "awg_private_key", srvPair.private_key);
      uci.set(
        UCI_PACKAGE,
        sectionId,
        "awg_server_public_key",
        srvPair.public_key,
      );
      setWidgetValue(sectionId, "awg_private_key", srvPair.private_key);
      setWidgetValue(sectionId, "awg_server_public_key", srvPair.public_key);
    }
    if (cliPair) {
      uci.set(
        UCI_PACKAGE,
        sectionId,
        "awg_client_private_key",
        cliPair.private_key,
      );
      uci.set(
        UCI_PACKAGE,
        sectionId,
        "awg_peer_public_key",
        cliPair.public_key,
      );
      setWidgetValue(sectionId, "awg_client_private_key", cliPair.private_key);
      setWidgetValue(sectionId, "awg_peer_public_key", cliPair.public_key);
    }
  });
}

function generateTlsCertificateIfMissing(sectionId) {
  return fs
    .exec("/usr/bin/tachyon", ["generate_tls_keypair", sectionId])
    .catch(() => null);
}

function getCurrentOptionValue(sectionId, option, fallback = "") {
  const container = getWidget(sectionId, option);
  if (
    container &&
    typeof dom !== "undefined" &&
    typeof dom.findClassInstance === "function"
  ) {
    const instance = dom.findClassInstance(container);
    if (instance && typeof instance.getValue === "function") {
      const val = instance.getValue();
      if (val != null && val !== "") {
        return Array.isArray(val) ? val[0] : `${val}`;
      }
    }
  }
  const widget = getControlWidget(sectionId, option);
  if (widget) {
    if (widget.type === "checkbox") {
      return widget.checked ? "1" : "0";
    }
    if (widget.value != null && widget.value !== "") {
      return `${widget.value}`;
    }
  }
  const uciVal = uci.get(UCI_PACKAGE, sectionId, option);
  if (uciVal != null && uciVal !== "") {
    return Array.isArray(uciVal) ? uciVal[0] : `${uciVal}`;
  }
  return fallback;
}

function autoConfigureStreamTransport(
  sectionId,
  protocol,
  security,
  transport,
  hostSni,
  forceOverwrite = true,
) {
  const tr = `${transport || "tcp"}`.toLowerCase();
  const sni = hostSni || "www.microsoft.com";
  const applyVal = (opt, val) => {
    if (forceOverwrite || !uci.get(UCI_PACKAGE, sectionId, opt)) {
      setWidgetValue(sectionId, opt, val);
    }
  };

  setWidgetValue(sectionId, "transport", tr);

  if (tr === "tcp") {
    if (protocol === "vless") {
      setWidgetValue(
        sectionId,
        "vless_flow",
        security === "reality" || security === "tls"
          ? "xtls-rprx-vision"
          : "none",
      );
    }
    if (security === "tls") {
      applyVal("tls_alpn", ["h2", "http/1.1"]);
    }
    return;
  }

  // Non-TCP stream transports do not support xtls-rprx-vision
  if (protocol === "vless") {
    setWidgetValue(sectionId, "vless_flow", "none");
  }

  if (tr === "ws") {
    applyVal("transport_path", `/${protocol}-ws-${randomHex(3)}`);
    applyVal("transport_host", sni);
    if (security === "tls") {
      applyVal("tls_alpn", ["http/1.1"]);
    }
  } else if (tr === "http") {
    applyVal("transport_path", `/${protocol}-h2-${randomHex(3)}`);
    applyVal("transport_hosts", [sni]);
    if (security === "tls") {
      applyVal("tls_alpn", ["h2", "http/1.1"]);
    }
  } else if (tr === "httpupgrade") {
    applyVal("transport_path", `/${protocol}-up-${randomHex(3)}`);
    applyVal("transport_host", sni);
    if (security === "tls") {
      applyVal("tls_alpn", ["http/1.1"]);
    }
  } else if (tr === "grpc") {
    applyVal("transport_service_name", `${protocol}_grpc_${randomHex(3)}`);
    if (security === "tls") {
      applyVal("tls_alpn", ["h2"]);
    }
  } else if (tr === "xhttp") {
    applyVal("transport_path", `/${protocol}-xhttp-${randomHex(3)}`);
    applyVal("transport_host", sni);
    const xhttpMode = getCurrentOptionValue(
      sectionId,
      "transport_xhttp_mode",
      "auto",
    );
    setWidgetValue(sectionId, "transport_xhttp_mode", xhttpMode || "auto");
    if (security === "tls") {
      applyVal("tls_alpn", ["h2", "http/1.1"]);
    }
  }
}

function autoConfigureServer(sectionId) {
  const protocol = getCurrentOptionValue(
    sectionId,
    "protocol",
    getProtocol(sectionId),
  );
  uci.set(UCI_PACKAGE, sectionId, "protocol", protocol);
  clearServerValidationMessage();

  setWidgetValue(sectionId, "enabled", "1");
  setWidgetValue(sectionId, "routing_mode", "rules");
  setWidgetValue(sectionId, "open_firewall_port", "1");
  setWidgetValue(sectionId, "listen", "0.0.0.0");

  fetchRouterNetworkEnv().then((env) => {
    env = env || {};
    const recPorts = env.recommended_ports || {};
    const recSni = env.recommended_sni || {};
    const awgEnv = env.awg || {};

    const publicHost =
      env.public_host ||
      env.ddns_domain ||
      env.cached_external_ip ||
      (Array.isArray(env.wan_ips) && env.wan_ips[0]) ||
      env.lan_ip ||
      getBrowserHost();
    setWidgetValue(sectionId, "public_host", publicHost);
    setWidgetValue(
      sectionId,
      "server_country",
      getCurrentOptionValue(
        sectionId,
        "server_country",
        env.country_code || "RU",
      ),
    );

    let chosenPort = recPorts[protocol] ? `${recPorts[protocol]}` : "443";
    if (protocol === "awg") {
      chosenPort = "51820";
    } else if (protocol === "hysteria2") {
      chosenPort = recPorts.hysteria2 ? `${recPorts.hysteria2}` : "443";
    } else if (protocol === "tuic") {
      chosenPort = "8443";
    } else if (protocol === "shadowsocks") {
      chosenPort = "8388";
    } else if (protocol === "socks") {
      chosenPort = "1080";
    } else if (protocol === "http" || protocol === "mixed") {
      chosenPort = "8080";
    } else if (protocol === "mieru") {
      chosenPort = recPorts.mieru ? `${recPorts.mieru}` : "2012";
    } else if (protocol === "trusttunnel") {
      chosenPort = recPorts.trusttunnel ? `${recPorts.trusttunnel}` : "9443";
    } else if (protocol === "tewfai") {
      chosenPort = recPorts.tewfai ? `${recPorts.tewfai}` : "10443";
    } else if (protocol === "masque") {
      chosenPort = recPorts.masque ? `${recPorts.masque}` : "11443";
    } else if (protocol === "openconnect") {
      chosenPort = recPorts.openconnect ? `${recPorts.openconnect}` : "12443";
    }

    const serverSections = uci.sections(UCI_PACKAGE, "server") || [];
    const usedPorts = new Set([1602, 1053, 5354]);
    for (const s of serverSections) {
      if (s[".name"] === sectionId) continue;
      const p = uci.get(UCI_PACKAGE, s[".name"], "listen_port");
      if (p) usedPorts.add(parseInt(p, 10));
    }
    let pNum = parseInt(chosenPort, 10) || 443;
    while (usedPorts.has(pNum) && pNum < 65535) {
      pNum = pNum === 443 ? 8443 : pNum + 1;
    }
    chosenPort = `${pNum}`;

    if (protocol !== "tailscale" && protocol !== "json_inbound") {
      setWidgetValue(sectionId, "listen_port", chosenPort);
    }

    const certPath = defaultTlsCertificatePath(sectionId);
    const keyPath = defaultTlsKeyPath(sectionId);
    const terminatingSni =
      recSni.terminating_tls ||
      (env.has_ddns && env.ddns_domain ? env.ddns_domain : "tachyon.lan");
    const decoySni = "www.microsoft.com";
    let needsTlsCert = false;

    if (protocol === "vless") {
      let security = getCurrentOptionValue(sectionId, "security", "reality");
      if (!["reality", "tls", "none"].includes(security)) {
        security = "reality";
      }
      const transport = getCurrentOptionValue(sectionId, "transport", "tcp");
      setWidgetValue(sectionId, "security", security);
      syncSecurityChoices(sectionId);
      setWidgetValue(sectionId, "server_uuid", generateUuid());

      if (security === "reality") {
        setWidgetValue(sectionId, "tls_server_name", decoySni);
        setWidgetValue(sectionId, "client_fingerprint", "chrome");
        setWidgetValue(sectionId, "reality_handshake_server", decoySni);
        setWidgetValue(sectionId, "reality_handshake_server_port", "443");
        setWidgetValue(sectionId, "reality_short_id", randomHex(4));
        setWidgetValue(sectionId, "reality_max_time_difference", "1m");
        generateRealityKeypair(sectionId);
      } else if (security === "tls") {
        setWidgetValue(sectionId, "tls_server_name", terminatingSni);
        setWidgetValue(sectionId, "tls_certificate_path", certPath);
        setWidgetValue(sectionId, "tls_key_path", keyPath);
        needsTlsCert = true;
      }

      autoConfigureStreamTransport(
        sectionId,
        "vless",
        security,
        transport,
        security === "reality" ? decoySni : terminatingSni,
        true,
      );
    } else if (protocol === "vmess") {
      let security = getCurrentOptionValue(sectionId, "security", "none");
      if (!["tls", "none"].includes(security)) {
        security = "none";
      }
      const transport = getCurrentOptionValue(sectionId, "transport", "tcp");
      setWidgetValue(sectionId, "security", security);
      syncSecurityChoices(sectionId);
      setWidgetValue(sectionId, "server_uuid", generateUuid());
      setWidgetValue(sectionId, "vmess_alter_id", "0");

      if (security === "tls") {
        setWidgetValue(sectionId, "tls_server_name", terminatingSni);
        setWidgetValue(sectionId, "tls_certificate_path", certPath);
        setWidgetValue(sectionId, "tls_key_path", keyPath);
        needsTlsCert = true;
      }

      autoConfigureStreamTransport(
        sectionId,
        "vmess",
        security,
        transport,
        terminatingSni,
        true,
      );
    } else if (protocol === "trojan") {
      let security = getCurrentOptionValue(sectionId, "security", "tls");
      if (!["tls", "none"].includes(security)) {
        security = "tls";
      }
      const transport = getCurrentOptionValue(sectionId, "transport", "tcp");
      setWidgetValue(sectionId, "security", security);
      syncSecurityChoices(sectionId);
      setWidgetValue(sectionId, "server_password", generatePassword());

      if (security === "tls") {
        setWidgetValue(sectionId, "tls_server_name", terminatingSni);
        setWidgetValue(sectionId, "tls_certificate_path", certPath);
        setWidgetValue(sectionId, "tls_key_path", keyPath);
        needsTlsCert = true;
      }

      autoConfigureStreamTransport(
        sectionId,
        "trojan",
        security,
        transport,
        terminatingSni,
        true,
      );
    } else if (protocol === "awg") {
      let localAddr = awgEnv.local_address || "10.8.0.1/24";
      let cliAddr = awgEnv.client_address || "10.8.0.2/32";
      const dnsAddr = awgEnv.dns || env.lan_ip || "10.8.0.1";
      const awgVer = getCurrentOptionValue(sectionId, "awg_version", "2.0");
      const h1 = `${randomIntInRange(100000000, 500000000)}`;
      const h2 = `${randomIntInRange(500000001, 900000000)}`;
      const h3 = `${randomIntInRange(900000001, 1400000000)}`;
      const h4 = `${randomIntInRange(1400000001, 2000000000)}`;

      const usedSubnets = new Set();
      for (const s of serverSections) {
        if (s[".name"] === sectionId) continue;
        const la = uci.get(UCI_PACKAGE, s[".name"], "awg_local_address");
        if (la) usedSubnets.add(la);
      }
      if (usedSubnets.has(localAddr)) {
        for (let idx = 1; idx < 100; idx++) {
          const candidate = localAddr
            .replace(/\.8\.0\.1\//, `.8.${idx}.1/`)
            .replace(/\.16\.8\.1\//, `.16.${8 + idx}.1/`);
          if (!usedSubnets.has(candidate)) {
            localAddr = candidate;
            cliAddr = cliAddr
              .replace(/\.8\.0\.2\//, `.8.${idx}.2/`)
              .replace(/\.16\.8\.2\//, `.16.${8 + idx}.2/`);
            break;
          }
        }
      }

      setWidgetValue(sectionId, "awg_local_address", localAddr);
      setWidgetValue(sectionId, "awg_client_address", cliAddr);
      setWidgetValue(sectionId, "awg_dns", dnsAddr);
      setWidgetValue(sectionId, "awg_mtu", "1280");
      setWidgetValue(sectionId, "awg_keepalive", "25");
      setWidgetValue(sectionId, "awg_version", awgVer);
      setWidgetValue(sectionId, "awg_preshared_key", generateBase64Key(32));
      setWidgetValue(sectionId, "awg_jc", `${randomIntInRange(4, 7)}`);
      setWidgetValue(sectionId, "awg_jmin", "40");
      setWidgetValue(sectionId, "awg_jmax", "70");
      setWidgetValue(sectionId, "awg_s1", `${randomIntInRange(15, 45)}`);
      setWidgetValue(sectionId, "awg_s2", `${randomIntInRange(15, 45)}`);
      setWidgetValue(sectionId, "awg_s3", "0");
      setWidgetValue(sectionId, "awg_s4", "0");
      setWidgetValue(sectionId, "awg_h1", h1);
      setWidgetValue(sectionId, "awg_h2", h2);
      setWidgetValue(sectionId, "awg_h3", h3);
      setWidgetValue(sectionId, "awg_h4", h4);

      if (awgVer === "3.0" || awgVer === "3.1") {
        setWidgetValue(
          sectionId,
          "awg_header_protection_key",
          generateBase64Key(32),
        );
        setWidgetValue(sectionId, "awg_content_padding_addition", "38-104");
      }
      if (awgVer === "3.1") {
        setWidgetValue(sectionId, "awg_rekey_after_time", "120");
        setWidgetValue(sectionId, "awg_rekey_timeout", "5");
        setWidgetValue(sectionId, "awg_reject_after_time", "180");
        setWidgetValue(sectionId, "awg_keepalive_timeout", "10");
        setWidgetValue(sectionId, "awg_max_handshake_attempts", "10");
      }

      Promise.all([
        generateAwgKeypair(sectionId),
        generateAwgKeypair(sectionId),
      ]).then(([srvPair, cliPair]) => {
        if (srvPair) {
          uci.set(
            UCI_PACKAGE,
            sectionId,
            "awg_private_key",
            srvPair.private_key,
          );
          uci.set(
            UCI_PACKAGE,
            sectionId,
            "awg_server_public_key",
            srvPair.public_key,
          );
          setWidgetValue(sectionId, "awg_private_key", srvPair.private_key);
          setWidgetValue(
            sectionId,
            "awg_server_public_key",
            srvPair.public_key,
          );
        }
        if (cliPair) {
          uci.set(
            UCI_PACKAGE,
            sectionId,
            "awg_client_private_key",
            cliPair.private_key,
          );
          uci.set(
            UCI_PACKAGE,
            sectionId,
            "awg_peer_public_key",
            cliPair.public_key,
          );
          setWidgetValue(
            sectionId,
            "awg_client_private_key",
            cliPair.private_key,
          );
          setWidgetValue(sectionId, "awg_peer_public_key", cliPair.public_key);
        }
      });
    } else if (protocol === "hysteria2") {
      setWidgetValue(sectionId, "server_password", generatePassword());
      setWidgetValue(sectionId, "hysteria2_obfs_type", "salamander");
      setWidgetValue(sectionId, "hysteria2_obfs_password", generatePassword());
      setWidgetValue(sectionId, "tls_server_name", terminatingSni);
      setWidgetValue(sectionId, "tls_alpn", ["h3"]);
      setWidgetValue(sectionId, "tls_certificate_path", certPath);
      setWidgetValue(sectionId, "tls_key_path", keyPath);
      needsTlsCert = true;
    } else if (protocol === "tuic") {
      const cc = getCurrentOptionValue(
        sectionId,
        "tuic_congestion_control",
        "bbr",
      );
      setWidgetValue(sectionId, "server_uuid", generateUuid());
      setWidgetValue(sectionId, "server_password", generatePassword());
      setWidgetValue(sectionId, "tuic_congestion_control", cc || "bbr");
      setWidgetValue(sectionId, "tls_server_name", terminatingSni);
      setWidgetValue(sectionId, "tls_alpn", ["h3"]);
      setWidgetValue(sectionId, "tls_certificate_path", certPath);
      setWidgetValue(sectionId, "tls_key_path", keyPath);
      needsTlsCert = true;
    } else if (protocol === "anytls") {
      setWidgetValue(sectionId, "server_password", generatePassword());
      setWidgetValue(sectionId, "tls_server_name", terminatingSni);
      setWidgetValue(sectionId, "tls_certificate_path", certPath);
      setWidgetValue(sectionId, "tls_key_path", keyPath);
      needsTlsCert = true;
    } else if (protocol === "naive") {
      setWidgetValue(
        sectionId,
        "server_username",
        getServerName(sectionId) || "tachyon",
      );
      setWidgetValue(sectionId, "server_password", generatePassword());
      setWidgetValue(sectionId, "tls_server_name", terminatingSni);
      setWidgetValue(sectionId, "tls_alpn", ["h2", "http/1.1"]);
      setWidgetValue(sectionId, "tls_certificate_path", certPath);
      setWidgetValue(sectionId, "tls_key_path", keyPath);
      needsTlsCert = true;
    } else if (protocol === "shadowtls") {
      const stlsVer = getCurrentOptionValue(
        sectionId,
        "shadowtls_version",
        "3",
      );
      setWidgetValue(sectionId, "server_password", generatePassword());
      setWidgetValue(sectionId, "shadowtls_handshake_server", decoySni);
      setWidgetValue(sectionId, "shadowtls_handshake_server_port", "443");
      setWidgetValue(sectionId, "shadowtls_version", stlsVer || "3");
    } else if (protocol === "fptn") {
      setWidgetValue(
        sectionId,
        "server_username",
        getServerName(sectionId) || "tachyon",
      );
      setWidgetValue(sectionId, "server_password", generatePassword());
      setWidgetValue(sectionId, "tls_server_name", terminatingSni);
      setWidgetValue(sectionId, "tls_certificate_path", certPath);
      setWidgetValue(sectionId, "tls_key_path", keyPath);
      needsTlsCert = true;
    } else if (protocol === "mieru") {
      const mieruTr = getCurrentOptionValue(
        sectionId,
        "mieru_transport",
        "TCP",
      );
      setWidgetValue(sectionId, "security", "none");
      syncSecurityChoices(sectionId);
      setWidgetValue(
        sectionId,
        "server_username",
        getServerName(sectionId) || "tachyon",
      );
      setWidgetValue(sectionId, "server_password", generatePassword());
      setWidgetValue(
        sectionId,
        "mieru_transport",
        mieruTr === "UDP" ? "UDP" : "TCP",
      );
    } else if (protocol === "trusttunnel") {
      const useQuic = getCurrentOptionValue(sectionId, "trusttunnel_quic", "0");
      setWidgetValue(sectionId, "security", "tls");
      syncSecurityChoices(sectionId);
      setWidgetValue(
        sectionId,
        "server_username",
        getServerName(sectionId) || "tachyon",
      );
      setWidgetValue(sectionId, "server_password", generatePassword());
      setWidgetValue(
        sectionId,
        "trusttunnel_quic",
        useQuic === "1" ? "1" : "0",
      );
      setWidgetValue(sectionId, "tls_server_name", terminatingSni);
      setWidgetValue(
        sectionId,
        "tls_alpn",
        useQuic === "1" ? ["h3"] : ["h2", "http/1.1"],
      );
      setWidgetValue(sectionId, "tls_certificate_path", certPath);
      setWidgetValue(sectionId, "tls_key_path", keyPath);
      needsTlsCert = true;
    } else if (protocol === "tewfai") {
      const tewfaiTr = getCurrentOptionValue(
        sectionId,
        "tewfai_inbound_transport",
        "tcp",
      );
      const innerCipher = getCurrentOptionValue(
        sectionId,
        "tewfai_inner_cipher",
        "aes-256-gcm",
      );
      setWidgetValue(sectionId, "security", "tls");
      syncSecurityChoices(sectionId);
      setWidgetValue(sectionId, "tewfai_uuid", generateUuid());
      setWidgetValue(sectionId, "tewfai_password", generatePassword());
      setWidgetValue(
        sectionId,
        "tewfai_inbound_transport",
        tewfaiTr === "quic" ? "quic" : "tcp",
      );
      setWidgetValue(sectionId, "tewfai_inner_cipher", innerCipher);
      setWidgetValue(sectionId, "tewfai_pqc_enabled", "1");
      setWidgetValue(sectionId, "tewfai_handover_enabled", "1");
      setWidgetValue(sectionId, "tewfai_fec_enabled", "0");
      setWidgetValue(sectionId, "tewfai_shaper_enabled", "1");
      setWidgetValue(sectionId, "tewfai_shaper_profile", "adaptive");
      setWidgetValue(sectionId, "tewfai_mtu", "1400");
      setWidgetValue(sectionId, "tls_server_name", terminatingSni);
      setWidgetValue(
        sectionId,
        "tls_alpn",
        tewfaiTr === "quic" ? ["h3"] : ["h2", "http/1.1"],
      );
      setWidgetValue(sectionId, "tls_certificate_path", certPath);
      setWidgetValue(sectionId, "tls_key_path", keyPath);
      needsTlsCert = true;
    } else if (protocol === "masque") {
      const usedPools = new Set();
      for (const s of serverSections) {
        if (s[".name"] === sectionId) continue;
        const p4 = getFirstListValue(s[".name"], "masque_ipv4_pool");
        if (p4) usedPools.add(p4);
      }
      let poolIdx = 0;
      let pool4 = "172.16.0.0/24";
      while (usedPools.has(pool4) && poolIdx < 200) {
        poolIdx++;
        pool4 = `172.16.${poolIdx}.0/24`;
      }
      const pool6 = `fd00:172:16:${poolIdx}::/64`;

      setWidgetValue(sectionId, "security", "tls");
      syncSecurityChoices(sectionId);
      setWidgetValue(
        sectionId,
        "server_username",
        getServerName(sectionId) || "tachyon",
      );
      setWidgetValue(sectionId, "server_password", generatePassword());
      setWidgetValue(sectionId, "masque_ipv4_pool", pool4);
      setWidgetValue(sectionId, "masque_ipv6_pool", pool6);
      setWidgetValue(sectionId, "masque_mtu", "1400");
      setWidgetValue(sectionId, "tls_server_name", terminatingSni);
      setWidgetValue(sectionId, "tls_alpn", ["h3"]);
      setWidgetValue(sectionId, "tls_certificate_path", certPath);
      setWidgetValue(sectionId, "tls_key_path", keyPath);
      needsTlsCert = true;
    } else if (protocol === "openconnect") {
      const ocFlavor = getCurrentOptionValue(
        sectionId,
        "openconnect_flavor",
        "anyconnect",
      );
      const ocDefaults = getOpenconnectFlavorDefaults(ocFlavor);
      const usedOcAddrs = new Set();
      for (const s of serverSections) {
        if (s[".name"] === sectionId) continue;
        const oa = uci.get(UCI_PACKAGE, s[".name"], "openconnect_address");
        if (oa) usedOcAddrs.add(oa);
      }
      let ocIdx = 0;
      let ocAddr = "10.9.0.2/24";
      while (usedOcAddrs.has(ocAddr) && ocIdx < 200) {
        ocIdx++;
        ocAddr = `10.9.${ocIdx}.2/24`;
      }

      setWidgetValue(sectionId, "security", "tls");
      syncSecurityChoices(sectionId);
      setWidgetValue(sectionId, "openconnect_cookie", generatePassword());
      setWidgetValue(sectionId, "openconnect_flavor", ocFlavor);
      setWidgetValue(sectionId, "openconnect_user_agent", ocDefaults.userAgent);
      setWidgetValue(
        sectionId,
        "openconnect_local_hostname",
        ocDefaults.hostname,
      );
      setWidgetValue(sectionId, "openconnect_urlpath", ocDefaults.urlpath);
      setWidgetValue(sectionId, "openconnect_address", ocAddr);
      setWidgetValue(sectionId, "openconnect_mtu", "1400");
      setWidgetValue(
        sectionId,
        "openconnect_ip",
        getCurrentOptionValue(sectionId, "openconnect_ip", "0"),
      );
      setWidgetValue(
        sectionId,
        "openconnect_esp",
        getCurrentOptionValue(sectionId, "openconnect_esp", "0"),
      );
      setWidgetValue(
        sectionId,
        "openconnect_dtls",
        getCurrentOptionValue(sectionId, "openconnect_dtls", "0"),
      );
      setWidgetValue(sectionId, "tls_server_name", terminatingSni);
      setWidgetValue(sectionId, "tls_certificate_path", certPath);
      setWidgetValue(sectionId, "tls_key_path", keyPath);
      needsTlsCert = true;
    } else if (protocol === "shadowsocks") {
      const ssMethod = getCurrentOptionValue(
        sectionId,
        "shadowsocks_method",
        "aes-128-gcm",
      );
      setWidgetValue(sectionId, "shadowsocks_method", ssMethod);
      setWidgetValue(
        sectionId,
        "server_password",
        generateShadowsocksPassword(ssMethod),
      );
    } else if (protocol === "socks") {
      setWidgetValue(sectionId, "socks_auth_enabled", "1");
      setWidgetValue(
        sectionId,
        "server_username",
        getServerName(sectionId) || "tachyon",
      );
      setWidgetValue(sectionId, "server_password", generatePassword());
    } else if (protocol === "http" || protocol === "mixed") {
      setWidgetValue(
        sectionId,
        "server_username",
        getServerName(sectionId) || "tachyon",
      );
      setWidgetValue(sectionId, "server_password", generatePassword());
    } else if (protocol === "mtproto") {
      setWidgetValue(sectionId, "mtproto_secret", generateMtprotoSecret());
      setWidgetValue(sectionId, "mtproto_faketls", "google.com");
      setWidgetValue(sectionId, "mtproto_padding", "1");
      setWidgetValue(sectionId, "mtproto_domain_fronting_port", "443");
      setWidgetValue(sectionId, "mtproto_prefer_ip", "prefer-ipv4");
      setWidgetValue(sectionId, "mtproto_tolerate_time_skewness", "3s");
      setWidgetValue(sectionId, "mtproto_idle_timeout", "5m");
      setWidgetValue(sectionId, "mtproto_handshake_timeout", "10s");
    } else if (protocol === "tailscale") {
      setWidgetValue(
        sectionId,
        "tailscale_control_url",
        "https://controlplane.tailscale.com",
      );
      setWidgetValue(
        sectionId,
        "tailscale_hostname",
        defaultTailscaleHostname(sectionId),
      );
      setWidgetValue(sectionId, "tailscale_advertise_exit_node", "1");
      setWidgetValue(sectionId, "tailscale_auto_firewall", "1");
      setWidgetValue(sectionId, "tailscale_mode", "singbox");
    } else if (protocol === "json_inbound") {
      const sampleInbound = {
        type: "vless",
        tag: `server-${sectionId}-in`,
        listen: "0.0.0.0",
        listen_port: parseInt(chosenPort, 10) || 14443,
        users: [
          {
            name: getServerName(sectionId) || sectionId,
            uuid: generateUuid(),
          },
        ],
      };
      setWidgetValue(
        sectionId,
        "inbound_json",
        JSON.stringify(sampleInbound, null, 2),
      );
    }

    if (needsTlsCert) {
      generateTlsCertificateIfMissing(sectionId);
    }

    const modal = getModalNode();
    if (modal) {
      modal
        .querySelectorAll(".cbi-input-invalid")
        .forEach((node) => node.classList.remove("cbi-input-invalid"));
    }

    if (typeof main !== "undefined" && typeof main.showToast === "function") {
      main.showToast(_("Server configuration generated"), "success");
    }
  });
}

function prepareServerModal(sectionId) {
  const protocol = getProtocol(sectionId);

  if (
    ["vless", "vmess", "tuic"].includes(protocol) &&
    !uci.get(UCI_PACKAGE, sectionId, "server_uuid")
  ) {
    setDefault(sectionId, "server_uuid", generateUuid());
  }

  if (
    PASSWORD_PROTOCOLS.includes(protocol) &&
    !uci.get(UCI_PACKAGE, sectionId, "server_password")
  ) {
    setDefault(sectionId, "server_password", generatePassword());
  }

  if (
    protocol === "tewfai" &&
    !uci.get(UCI_PACKAGE, sectionId, "tewfai_uuid")
  ) {
    setDefault(sectionId, "tewfai_uuid", generateUuid());
  }

  if (
    protocol === "openconnect" &&
    !uci.get(UCI_PACKAGE, sectionId, "openconnect_cookie")
  ) {
    setDefault(sectionId, "openconnect_cookie", generatePassword());
  }

  if (
    protocol === "vless" &&
    getEffectiveSecurity(sectionId) === "reality" &&
    !getFirstListValue(sectionId, "reality_short_id")
  ) {
    setDefault(sectionId, "reality_short_id", randomHex(4));
  }

  if (!uci.get(UCI_PACKAGE, sectionId, "listen_port")) {
    setDefault(sectionId, "listen_port", getServerPort(sectionId));
  }

  const tasks = [fetchRouterNetworkEnv()];

  if (shouldGenerateRealityKeypair(sectionId)) {
    tasks.push(generateRealityKeypairIfMissing(sectionId));
  }
  if (protocol === "awg") {
    tasks.push(generateAwgKeypairsIfMissing(sectionId));
  }
  if (getEffectiveSecurity(sectionId) === "tls") {
    tasks.push(generateTlsCertificateIfMissing(sectionId));
  }
  if (!defaultPublicHostCache && typeof loadDefaultPublicHost === "function") {
    tasks.push(
      loadDefaultPublicHost()
        .then((host) => applyDefaultPublicHost(sectionId, host))
        .catch(() => null),
    );
  }

  return Promise.all(tasks).then(() => null);
}

function addStreamDepends(option) {
  STREAM_PROTOCOLS.forEach((protocol) => option.depends("protocol", protocol));
}

function addPortProtocolDepends(option, singBoxExtended) {
  PORT_PROTOCOLS.forEach((protocol) => option.depends("protocol", protocol));
  if (singBoxExtended) {
    EXTENDED_PORT_PROTOCOLS.forEach((protocol) =>
      option.depends("protocol", protocol),
    );
  }
}

function addTlsDepends(option) {
  option.depends({ protocol: "vless", security: "tls" });
  option.depends({ protocol: "vmess", security: "tls" });
  option.depends({ protocol: "trojan", security: "tls" });
  option.depends("protocol", "hysteria2");
  option.depends("protocol", "tuic");
  option.depends("protocol", "anytls");
  option.depends("protocol", "naive");
  option.depends("protocol", "fptn");
  option.depends("protocol", "trusttunnel");
  option.depends("protocol", "tewfai");
  option.depends("protocol", "masque");
  option.depends("protocol", "openconnect");
}

function addRealityDepends(option) {
  option.depends({ protocol: "vless", security: "reality" });
}

function addTailscaleDepends(option) {
  option.depends("protocol", "tailscale");
}

function addMtprotoDepends(option) {
  option.depends("protocol", "mtproto");
}

function configureServerTextareaOption(option) {
  const originalRenderWidget = option.renderWidget;

  option.renderWidget = function (sectionId, optionIndex, cfgvalue) {
    const node = originalRenderWidget.call(
      this,
      sectionId,
      optionIndex,
      cfgvalue,
    );
    const textarea =
      node && typeof node.querySelector === "function"
        ? node.querySelector("textarea")
        : node;

    if (textarea) {
      textarea.setAttribute("spellcheck", "false");
      textarea.setAttribute("autocomplete", "off");
      textarea.setAttribute("autocorrect", "off");
      textarea.setAttribute("autocapitalize", "off");
      textarea.setAttribute("data-gramm", "false");
      textarea.setAttribute("data-gramm_editor", "false");
      textarea.setAttribute("data-enable-grammarly", "false");
      textarea.style.resize = "vertical";
      textarea.style.maxWidth = "100%";
    }

    return node;
  };
}

function configureServerSection(sectionRef, options = {}) {
  sectionRef.sortable = false;
  sectionRef.nodescriptions = true;
  sectionRef.load = function () {
    // The main page table renders only non-modal fields; full server defaults
    // are loaded by LuCI's cloned modal map when the user opens Add/Edit.
    return loadServerTableOptions(this);
  };

  sectionRef.renderMoreOptionsModal = function (sectionId, ev) {
    sanitizeUciDeletes(sectionId);
    this.serverEditSnapshots ??= {};
    this.serverEditSnapshots[sectionId] = captureServerEditState(sectionId);

    const capabilitiesTask =
      typeof options.loadCapabilities === "function"
        ? options.loadCapabilities()
        : Promise.resolve();

    return Promise.resolve(capabilitiesTask)
      .then(() => prepareServerModal(sectionId))
      .then(() =>
        form.GridSection.prototype.renderMoreOptionsModal.call(
          this,
          sectionId,
          ev,
        ),
      );
  };

  sectionRef.handleAdd = function (_ev, name) {
    const configName = this.uciconfig ?? this.map.config;
    const sectionId = this.map.data.add(configName, this.sectiontype, name);
    const mapNode = this.getPreviousModalMap();
    const prevMap = mapNode ? dom.findClassInstance(mapNode) : this.map;

    prevMap.addedSection = sectionId;
    sanitizeUciDeletes(sectionId);

    const capabilitiesTask =
      typeof options.loadCapabilities === "function"
        ? options.loadCapabilities()
        : Promise.resolve(this.serverCapabilities);

    return Promise.resolve(capabilitiesTask).then((capabilities) => {
      if (capabilities) {
        this.serverCapabilities = normalizeServerCapabilities(capabilities);
      }

      ensureProtocolDefaults(
        sectionId,
        getDefaultProtocolForCapabilities(this.serverCapabilities),
        true,
      );

      loadDefaultPublicHost()
        .then((host) => applyDefaultPublicHost(sectionId, host))
        .catch(() => null);

      return this.renderMoreOptionsModal(sectionId);
    });
  };

  sectionRef.handleModalCancel = function (modalMap, ev, isSaving) {
    const sectionId = modalMap?.section;
    const snapshot = sectionId ? this.serverEditSnapshots?.[sectionId] : null;

    if (sectionId && this.serverEditSnapshots) {
      delete this.serverEditSnapshots[sectionId];
    }

    if (!isSaving) {
      restoreServerEditState(snapshot);
    }

    sanitizeUciDeletes(sectionId);

    return form.GridSection.prototype.handleModalCancel
      .call(this, modalMap, ev, isSaving)
      .then((res) => {
        if (typeof main.renderServerTabInboundsOverview === "function") {
          main.renderServerTabInboundsOverview();
        }
        return res;
      });
  };

  sectionRef.handleModalSave = function (modalMap, ev) {
    clearServerValidationMessage();

    const targetMap =
      modalMap ||
      (typeof this.getActiveModalMap === "function"
        ? dom.findClassInstance(this.getActiveModalMap())
        : null);

    if (!targetMap) {
      return Promise.resolve();
    }

    const targetSectionId =
      targetMap.section || targetMap.children?.[0]?.section;

    sanitizeUciDeletes(targetSectionId);

    const origCallDelete = uci.callDelete;
    if (typeof origCallDelete === "function") {
      uci.callDelete = function (config, section, options) {
        if (config === UCI_PACKAGE) {
          const creates = uci.state?.creates?.[UCI_PACKAGE];
          const values = uci.state?.values?.[UCI_PACKAGE];
          if (creates?.[section] || !values?.[section]) {
            return Promise.resolve(0);
          }
        }
        return origCallDelete.apply(this, arguments).catch((err) => {
          const msg = typeof err?.message === "string" ? err.message : "";
          // ubus code 4 is UBUS_STATUS_NOT_FOUND. The numeric code survives
          // translation; the text after the colon does not, so it only counts
          // when the message carries no code at all (older transports). A code
          // that is present but different is authoritative, and the trailing
          // \b keeps "ubus code 40"/"41" from matching this guard.
          const coded = /\bubus code \d+\b/.test(msg);
          if (
            config === UCI_PACKAGE &&
            (/\bubus code 4\b/.test(msg) ||
              (!coded &&
                (msg.includes("Ресурс не найден") ||
                  msg.includes("Not found"))))
          ) {
            return 0;
          }
          return Promise.reject(err);
        });
      };
    }

    const beforeUciSave = () => {
      sanitizeUciDeletes(targetSectionId);
    };

    let saveTasks;
    try {
      saveTasks = targetMap.save(beforeUciSave, true);
    } catch (e) {
      if (origCallDelete) {
        uci.callDelete = origCallDelete;
      }
      return Promise.reject(e);
    }

    let curr = targetMap;
    while (curr.parent) {
      curr = curr.parent;
      saveTasks = saveTasks
        .then(curr.load.bind(curr))
        .then(curr.reset.bind(curr));
    }

    return saveTasks
      .then(() => this.handleModalCancel(targetMap, ev, true))
      .catch((error) => showServerValidationMessage(error))
      .finally(() => {
        if (origCallDelete) {
          uci.callDelete = origCallDelete;
        }
      });
  };

  sectionRef.renderRowActions = function (sectionId) {
    return renderServerRowActions(this, sectionId);
  };

  if (typeof main.registerServerSectionController === "function") {
    main.registerServerSectionController(sectionRef, {
      showServerInfoModal: (sectionId) => showServerInfoModal(sectionId),
      showSubscriptionModal: () => showSubscriptionModal(sectionRef),
    });
  }
}

function createServerContent(section, options = {}) {
  injectServerStyles();
  const capabilities = normalizeServerCapabilities(options);
  const singBoxXhttp = capabilities.singBoxXhttp;
  const singBoxTailscale = capabilities.singBoxTailscale;
  section.serverCapabilityOptions = {};
  section.serverCapabilities = capabilities;

  let o = section.option(form.Flag, "enabled", _("Enable"));
  o.default = "1";
  o.rmempty = false;
  o.editable = true;
  o.width = "6rem";

  o = section.option(form.DummyValue, "_protocol_display", _("Protocol"));
  o.rawhtml = true;
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    return getProtocolLabel(getProtocol(sectionId));
  };
  o.textvalue = function (sectionId) {
    return getProtocolLabel(getProtocol(sectionId));
  };
  o.width = "7rem";

  o = section.option(form.Value, "label", _("Server name"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.onchange = function (_ev, sectionId, value) {
    const previousLabel = getServerName(sectionId);
    const currentUsername =
      uci.get(UCI_PACKAGE, sectionId, "server_username") || "";

    uci.set(UCI_PACKAGE, sectionId, "label", value);

    if (
      getProtocol(sectionId) === "socks" &&
      (!currentUsername ||
        currentUsername === previousLabel ||
        currentUsername === sectionId)
    ) {
      const nextUsername = value || sectionId;
      uci.set(UCI_PACKAGE, sectionId, "server_username", nextUsername);
      setWidgetValue(sectionId, "server_username", nextUsername);
    }
  };

  o = section.option(
    form.Value,
    "server_country",
    _("Server country"),
    _(
      "Two-letter ISO country code (e.g. RU, NL, DE) advertised as a flag emoji in client links and subscriptions.",
    ),
  );
  o.default = "RU";
  o.modalonly = true;
  o.rmempty = true;
  o.placeholder = "RU";
  [
    ["RU", "🇷🇺 Россия (RU)"],
    ["NL", "🇳🇱 Нидерланды (NL)"],
    ["DE", "🇩🇪 Германия (DE)"],
    ["FI", "🇫🇮 Финляндия (FI)"],
    ["US", "🇺🇸 США (US)"],
    ["GB", "🇬🇧 Великобритания (GB)"],
    ["FR", "🇫🇷 Франция (FR)"],
    ["SE", "🇸🇪 Швеция (SE)"],
    ["PL", "🇵🇱 Польша (PL)"],
    ["TR", "🇹🇷 Турция (TR)"],
    ["KZ", "🇰🇿 Казахстан (KZ)"],
    ["BY", "🇧🇾 Беларусь (BY)"],
    ["UA", "🇺🇦 Украина (UA)"],
    ["AE", "🇦🇪 ОАЭ (AE)"],
    ["SG", "🇸🇬 Сингапур (SG)"],
    ["JP", "🇯🇵 Япония (JP)"],
    ["HK", "🇭🇰 Гонконг (HK)"],
    ["AT", "🇦🇹 Австрия (AT)"],
    ["CH", "🇨🇭 Швейцария (CH)"],
    ["LT", "🇱🇹 Литва (LT)"],
    ["LV", "🇱🇻 Латвия (LV)"],
    ["EE", "🇪🇪 Эстония (EE)"],
  ].forEach(([code, label]) => o.value(code, label));

  o = section.option(form.ListValue, "protocol", _("Protocol"));
  section.serverCapabilityOptions.protocol = o;
  populateProtocolValues(o, capabilities);
  o.default = getDefaultProtocolForCapabilities(capabilities);
  o.rmempty = false;
  o.modalonly = true;
  o.validate = function (sectionId, value) {
    const normalized = normalizeServerCapabilities(
      section.serverCapabilities || capabilities,
    );
    if (normalized.singBoxTachyonCore && value === "mtproto") {
      return _("MTProto is not implemented in tachyon-core yet");
    }
    return validateRequired.call(this, sectionId, value);
  };
  const originalProtocolRenderWidget = o.renderWidget;
  o.renderWidget = function (sectionId, optionIndex, cfgvalue) {
    const node = originalProtocolRenderWidget.apply(this, arguments);
    const normalized = normalizeServerCapabilities(
      section.serverCapabilities || capabilities,
    );
    if (normalized.singBoxTachyonCore) {
      Promise.resolve(node).then((elem) => {
        if (!elem) return;
        const disabledItems = elem.querySelectorAll
          ? elem.querySelectorAll(
              '[data-value="mtproto"], option[value="mtproto"]',
            )
          : [];
        disabledItems.forEach((opt) => {
          opt.disabled = true;
          opt.setAttribute("disabled", "disabled");
          opt.classList.add("disabled");
        });
      });
    }
    return node;
  };
  o.onchange = function (_ev, sectionId, value) {
    ensureProtocolDefaults(sectionId, value, true);
    syncSecurityChoices(sectionId);
    syncProtocolWidgetValues(sectionId, value);
    if (value === "vless" && getEffectiveSecurity(sectionId) === "reality") {
      generateRealityKeypairIfMissing(sectionId);
    }
    if (value === "awg") {
      generateAwgKeypairsIfMissing(sectionId);
    }
    if (getEffectiveSecurity(sectionId) === "tls") {
      generateTlsCertificateIfMissing(sectionId);
    }
  };

  o = section.option(form.Button, "_autoconfig", _("Auto-configuration"));
  o.inputtitle = _("Auto-configure (Generate all in 1 click)");
  o.inputstyle = "action primary";
  o.modalonly = true;
  o.onclick = function (_ev, sectionId) {
    autoConfigureServer(sectionId);
  };

  o = section.option(
    form.Flag,
    "open_firewall_port",
    _("Open firewall port"),
    _(
      "Automatically allow inbound WAN traffic to the server port in nftables firewall",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.modalonly = true;
  addPortProtocolDepends(o, true);

  o = section.option(
    form.Value,
    "listen",
    _("Listen address"),
    _(
      "Choose whether this server listens on all interfaces, only Local (LAN), or a specific External (WAN) interface IP.",
    ),
  );
  o.default = "0.0.0.0";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateListenAddress;
  addPortProtocolDepends(o, true);
  populateListenAddressChoices(o, routerNetworkEnvCache);
  o.load = function (sectionId) {
    return fetchRouterNetworkEnv().then((env) => {
      populateListenAddressChoices(this, env);
      return uci.get(UCI_PACKAGE, sectionId, "listen") || "0.0.0.0";
    });
  };

  o = section.option(form.Value, "listen_port", _("Listen port"));
  o.default = "443";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validatePort;
  addPortProtocolDepends(o, true);

  o = section.option(
    form.Value,
    "public_host",
    _("Public host"),
    _(
      "Select the Local (LAN) or External (WAN / DDNS) router address advertised in client connection links and QR codes.",
    ),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHost;
  addPortProtocolDepends(o, true);
  populatePublicHostChoices(o, routerNetworkEnvCache);
  o.load = function (sectionId) {
    return Promise.all([loadDefaultPublicHost(), fetchRouterNetworkEnv()]).then(
      ([host, env]) => {
        populatePublicHostChoices(this, env);
        applyDefaultPublicHost(sectionId, host);
        return uci.get(UCI_PACKAGE, sectionId, "public_host") || host || "";
      },
    );
  };

  o = section.option(form.ListValue, "routing_mode", _("Routing mode"));
  o.value("rules", _("Rules"));
  o.value("direct", _("Direct"));
  o.value("section", _("Selected section"));
  o.default = "rules";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;

  o = section.option(form.ListValue, "routing_section", _("Routing section"));
  o.depends("routing_mode", "section");
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  o.cfgvalue = function (sectionId) {
    return uci.get(UCI_PACKAGE, sectionId, "routing_section");
  };
  o.load = function () {
    return loadRoutingSectionChoices(this);
  };

  o = section.option(
    form.Flag,
    "isolate_lan_for_users",
    _("Restrict LAN access for specific users"),
    _(
      "Blocks access to private/LAN IP addresses (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, etc.) for selected users before applying routing mode.",
    ),
  );
  o.modalonly = true;
  o.rmempty = true;

  o = section.option(
    form.DynamicList,
    "isolated_users",
    _("Restricted users (auth_user)"),
    _(
      "User names (e.g. from VLESS/Trojan/SS/JSON inbound users) that are forbidden from reaching LAN subnets. Leave empty to restrict all users on this inbound.",
    ),
  );
  o.depends("isolate_lan_for_users", "1");
  o.modalonly = true;
  o.rmempty = true;

  o = section.option(
    form.TextValue,
    "inbound_json",
    _("Inbound JSON"),
    _("Enter a complete sing-box inbound object"),
  );
  o.depends("protocol", "json_inbound");
  o.rows = 10;
  o.wrap = "soft";
  o.textarea = true;
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateInboundJson;
  configureServerTextareaOption(o);

  o = section.option(form.ListValue, "security", _("Security"));
  o.value("reality", "Reality");
  o.value("tls", "TLS");
  o.value("none", _("None"));
  o.default = "reality";
  o.rmempty = false;
  o.modalonly = true;
  addStreamDepends(o);
  o.depends("protocol", "hysteria2");
  o.validate = validateSecurity;
  o.onchange = function (_ev, sectionId, value) {
    if (value === "reality") {
      generateRealityKeypairIfMissing(sectionId);
    } else if (value === "tls") {
      if (!uci.get(UCI_PACKAGE, sectionId, "tls_certificate_path")) {
        setWidgetValue(
          sectionId,
          "tls_certificate_path",
          defaultTlsCertificatePath(sectionId),
        );
      }
      if (!uci.get(UCI_PACKAGE, sectionId, "tls_key_path")) {
        setWidgetValue(sectionId, "tls_key_path", defaultTlsKeyPath(sectionId));
      }
      generateTlsCertificateIfMissing(sectionId);
    }
  };
  {
    const originalRenderWidget = o.renderWidget;
    o.renderWidget = function (sectionId, optionIndex, cfgvalue) {
      const node = originalRenderWidget.call(
        this,
        sectionId,
        optionIndex,
        cfgvalue,
      );
      window.setTimeout(() => syncSecurityChoices(sectionId), 0);
      return node;
    };
  }

  o = section.option(form.Value, "tls_server_name", _("Server name / SNI"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHost;
  o.load = function (sectionId) {
    const current = normalizeHost(
      uci.get(UCI_PACKAGE, sectionId, "tls_server_name"),
    );
    if (current) {
      return current;
    }

    const fallback = "www.microsoft.com";
    uci.set(UCI_PACKAGE, sectionId, "tls_server_name", fallback);
    return fallback;
  };
  addTlsDepends(o);
  addRealityDepends(o);

  o = section.option(form.MultiValue, "tls_alpn", _("ALPN"));
  o.value("h3", "h3");
  o.value("h2", "h2");
  o.value("http/1.1", "http/1.1");
  o.create = false;
  o.rmempty = true;
  o.modalonly = true;
  addTlsDepends(o);
  addRealityDepends(o);

  o = section.option(form.Value, "tls_certificate_path", _("Certificate path"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateTlsCertificatePath;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "tls_certificate_path");
    if (current) {
      return current;
    }
    const value = defaultTlsCertificatePath(sectionId);
    uci.set(UCI_PACKAGE, sectionId, "tls_certificate_path", value);
    return value;
  };
  addTlsDepends(o);

  o = section.option(form.Value, "tls_key_path", _("Key path"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateTlsKeyPath;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "tls_key_path");
    if (current) {
      return current;
    }
    const value = defaultTlsKeyPath(sectionId);
    uci.set(UCI_PACKAGE, sectionId, "tls_key_path", value);
    return value;
  };
  addTlsDepends(o);

  o = section.option(
    form.Value,
    "reality_handshake_server",
    _("Reality fake site"),
  );
  o.default = "www.microsoft.com";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHost;
  addRealityDepends(o);

  o = section.option(
    form.Value,
    "reality_handshake_server_port",
    _("Reality fake site port"),
  );
  o.default = "443";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validatePort;
  addRealityDepends(o);

  o = section.option(
    form.Value,
    "reality_private_key",
    _("Reality private key"),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  addRealityDepends(o);

  o = section.option(form.Value, "reality_public_key", _("Reality public key"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  addRealityDepends(o);

  o = section.option(form.Value, "reality_short_id", _("Reality short ID"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateShortId;
  o.load = function (sectionId) {
    const current = getFirstListValue(sectionId, "reality_short_id");
    if (current) {
      uci.set(UCI_PACKAGE, sectionId, "reality_short_id", current);
      return current;
    }
    const value = randomHex(4);
    uci.set(UCI_PACKAGE, sectionId, "reality_short_id", value);
    return value;
  };
  addRealityDepends(o);

  o = section.option(
    form.Value,
    "reality_max_time_difference",
    _("Reality max time difference"),
  );
  o.default = "1m";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredDuration;
  addRealityDepends(o);

  o = section.option(
    form.ListValue,
    "client_fingerprint",
    _("Client fingerprint"),
  );
  ["chrome", "firefox", "edge", "safari", "ios", "android", "random"].forEach(
    (value) => o.value(value, value),
  );
  o.default = "chrome";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;
  addRealityDepends(o);

  o = section.option(form.ListValue, "transport", _("Transport"));
  section.serverCapabilityOptions.transport = o;
  populateTransportValues(o, singBoxXhttp);
  o.default = "tcp";
  o.rmempty = false;
  o.modalonly = true;
  addStreamDepends(o);
  o.onchange = function (_ev, sectionId, value) {
    const protocol = getCurrentOptionValue(
      sectionId,
      "protocol",
      getProtocol(sectionId),
    );
    const security = getCurrentOptionValue(
      sectionId,
      "security",
      getEffectiveSecurity(sectionId),
    );
    const sni =
      getCurrentOptionValue(sectionId, "tls_server_name", "") ||
      (security === "reality" ? "www.microsoft.com" : "tachyon.lan");
    autoConfigureStreamTransport(
      sectionId,
      protocol,
      security,
      value,
      sni,
      false,
    );
  };

  o = section.option(form.Value, "transport_path", _("Transport path"));
  o.modalonly = true;
  o.validate = validateTransportPath;
  o.depends({ protocol: "vless", transport: "ws" });
  o.depends({ protocol: "vmess", transport: "ws" });
  o.depends({ protocol: "trojan", transport: "ws" });
  o.depends({ protocol: "vless", transport: "http" });
  o.depends({ protocol: "vmess", transport: "http" });
  o.depends({ protocol: "trojan", transport: "http" });
  o.depends({ protocol: "vless", transport: "httpupgrade" });
  o.depends({ protocol: "vmess", transport: "httpupgrade" });
  o.depends({ protocol: "trojan", transport: "httpupgrade" });
  o.depends({ protocol: "vless", transport: "xhttp" });
  o.depends({ protocol: "vmess", transport: "xhttp" });
  o.depends({ protocol: "trojan", transport: "xhttp" });

  o = section.option(form.Value, "transport_host", _("Transport host"));
  o.modalonly = true;
  o.validate = validateOptionalHost;
  o.depends({ protocol: "vless", transport: "ws" });
  o.depends({ protocol: "vmess", transport: "ws" });
  o.depends({ protocol: "trojan", transport: "ws" });
  o.depends({ protocol: "vless", transport: "httpupgrade" });
  o.depends({ protocol: "vmess", transport: "httpupgrade" });
  o.depends({ protocol: "trojan", transport: "httpupgrade" });
  o.depends({ protocol: "vless", transport: "xhttp" });
  o.depends({ protocol: "vmess", transport: "xhttp" });
  o.depends({ protocol: "trojan", transport: "xhttp" });

  o = section.option(form.ListValue, "transport_xhttp_mode", _("XHTTP mode"));
  o.value("auto", "auto");
  o.value("packet-up", "packet-up");
  o.value("stream-up", "stream-up");
  o.value("stream-one", "stream-one");
  o.default = "auto";
  o.rmempty = false;
  o.modalonly = true;
  o.depends({ protocol: "vless", transport: "xhttp" });
  o.depends({ protocol: "vmess", transport: "xhttp" });
  o.depends({ protocol: "trojan", transport: "xhttp" });

  o = section.option(form.DynamicList, "transport_hosts", _("HTTP hosts"));
  o.modalonly = true;
  o.validate = validateOptionalHostList;
  o.depends({ protocol: "vless", transport: "http" });
  o.depends({ protocol: "vmess", transport: "http" });
  o.depends({ protocol: "trojan", transport: "http" });

  o = section.option(form.Value, "transport_service_name", _("gRPC service"));
  o.modalonly = true;
  o.validate = validateGrpcServiceName;
  o.depends({ protocol: "vless", transport: "grpc" });
  o.depends({ protocol: "vmess", transport: "grpc" });
  o.depends({ protocol: "trojan", transport: "grpc" });

  o = section.option(form.ListValue, "shadowsocks_method", _("Method"));
  o.value("aes-128-gcm", "aes-128-gcm");
  o.value("aes-256-gcm", "aes-256-gcm");
  o.value("chacha20-ietf-poly1305", "chacha20-ietf-poly1305");
  o.value("xchacha20-ietf-poly1305", "xchacha20-ietf-poly1305");
  o.value("2022-blake3-aes-128-gcm", "2022-blake3-aes-128-gcm");
  o.value("2022-blake3-aes-256-gcm", "2022-blake3-aes-256-gcm");
  o.value("2022-blake3-chacha20-poly1305", "2022-blake3-chacha20-poly1305");
  o.default = "aes-128-gcm";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;
  o.depends("protocol", "shadowsocks");
  o.onchange = function (_ev, sectionId, value) {
    setWidgetValue(
      sectionId,
      "server_password",
      generateShadowsocksPassword(value),
    );
  };

  o = section.option(
    form.Flag,
    "socks_auth_enabled",
    _("Enable authentication"),
  );
  o.default = "1";
  o.rmempty = false;
  o.modalonly = true;
  o.depends("protocol", "socks");

  o = section.option(form.Value, "server_uuid", _("UUID"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "server_uuid");
    if (current) return current;
    const value = generateUuid();
    uci.set(UCI_PACKAGE, sectionId, "server_uuid", value);
    return value;
  };
  o.depends("protocol", "vless");
  o.depends("protocol", "vmess");
  o.depends("protocol", "tuic");

  o = section.option(form.Value, "server_username", _("Username"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "server_username");
    if (current) {
      return current;
    }

    const value = getServerName(sectionId);
    uci.set(UCI_PACKAGE, sectionId, "server_username", value);
    return value;
  };
  o.depends({ protocol: "socks", socks_auth_enabled: "1" });
  o.depends("protocol", "naive");
  o.depends("protocol", "fptn");
  o.depends("protocol", "http");
  o.depends("protocol", "mixed");
  o.depends("protocol", "mieru");
  o.depends("protocol", "trusttunnel");
  o.depends("protocol", "masque");

  o = section.option(form.Value, "server_password", _("Password"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "server_password");
    if (current) {
      return current;
    }

    const value = generatePassword();
    uci.set(UCI_PACKAGE, sectionId, "server_password", value);
    return value;
  };
  o.depends({ protocol: "socks", socks_auth_enabled: "1" });
  o.depends("protocol", "shadowsocks");
  o.depends("protocol", "trojan");
  o.depends("protocol", "hysteria2");
  o.depends("protocol", "tuic");
  o.depends("protocol", "anytls");
  o.depends("protocol", "naive");
  o.depends("protocol", "shadowtls");
  o.depends("protocol", "fptn");
  o.depends("protocol", "http");
  o.depends("protocol", "mixed");
  o.depends("protocol", "mieru");
  o.depends("protocol", "trusttunnel");
  o.depends("protocol", "masque");

  o = section.option(form.ListValue, "mieru_transport", _("Mieru Transport"));
  o.value("TCP", "TCP");
  o.value("UDP", "UDP");
  o.default = "TCP";
  o.modalonly = true;
  o.depends("protocol", "mieru");

  o = section.option(form.Flag, "trusttunnel_quic", _("Use QUIC (HTTP/3)"));
  o.default = "0";
  o.modalonly = true;
  o.depends("protocol", "trusttunnel");

  o = section.option(form.Value, "tewfai_uuid", _("UUID / Password"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "tewfai_uuid");
    if (current) return current;
    const value = generateUuid();
    uci.set(UCI_PACKAGE, sectionId, "tewfai_uuid", value);
    return value;
  };
  o.depends("protocol", "tewfai");

  o = section.option(
    form.Value,
    "tewfai_password",
    _("Password (optional second PSK)"),
  );
  o.modalonly = true;
  o.rmempty = true;
  o.depends("protocol", "tewfai");

  o = section.option(
    form.ListValue,
    "tewfai_inbound_transport",
    _("Transport"),
  );
  o.value("tcp", "TCP");
  o.value("quic", "QUIC");
  o.default = "tcp";
  o.rmempty = true;
  o.modalonly = true;
  o.depends("protocol", "tewfai");
  o.onchange = function (_ev, sectionId, value) {
    setWidgetValue(
      sectionId,
      "tls_alpn",
      value === "quic" ? ["h3"] : ["h2", "http/1.1"],
    );
  };

  o = section.option(form.ListValue, "tewfai_inner_cipher", _("Inner cipher"));
  o.value("aes-256-gcm", "AES-256-GCM");
  o.value("none", _("None (TLS/QUIC only)"));
  o.default = "aes-256-gcm";
  o.rmempty = true;
  o.modalonly = true;
  o.depends("protocol", "tewfai");

  o = section.option(
    form.Flag,
    "tewfai_pqc_enabled",
    _("Post-Quantum (PQC ML-KEM)"),
  );
  o.default = "1";
  o.modalonly = true;
  o.depends("protocol", "tewfai");

  o = section.option(
    form.Flag,
    "tewfai_handover_enabled",
    _("Seamless Handover"),
  );
  o.default = "1";
  o.modalonly = true;
  o.depends("protocol", "tewfai");

  o = section.option(
    form.Flag,
    "tewfai_fec_enabled",
    _("Forward Error Correction (FEC)"),
  );
  o.default = "0";
  o.modalonly = true;
  o.depends("protocol", "tewfai");

  o = section.option(form.Flag, "tewfai_shaper_enabled", _("Traffic Shaper"));
  o.default = "1";
  o.modalonly = true;
  o.depends("protocol", "tewfai");

  o = section.option(
    form.ListValue,
    "tewfai_shaper_profile",
    _("Shaper Profile"),
  );
  o.value("adaptive", _("Adaptive"));
  o.value("fixed", _("Fixed"));
  o.value("off", _("Off"));
  o.default = "adaptive";
  o.modalonly = true;
  o.depends({ protocol: "tewfai", tewfai_shaper_enabled: "1" });

  o = section.option(form.Value, "tewfai_mtu", _("MTU"));
  o.modalonly = true;
  o.rmempty = true;
  o.placeholder = "1400";
  o.validate = validateOptionalPort;
  o.depends("protocol", "tewfai");

  o = section.option(form.Value, "masque_ipv4_pool", _("IPv4 pool (CIDR)"));
  o.modalonly = true;
  o.rmempty = true;
  o.placeholder = "172.16.0.0/24";
  o.depends("protocol", "masque");

  o = section.option(form.Value, "masque_ipv6_pool", _("IPv6 pool (CIDR)"));
  o.modalonly = true;
  o.rmempty = true;
  o.depends("protocol", "masque");

  o = section.option(form.Value, "masque_mtu", _("MTU"));
  o.modalonly = true;
  o.rmempty = true;
  o.placeholder = "1400";
  o.validate = validateOptionalPort;
  o.depends("protocol", "masque");

  // ── OpenConnect server (tachyon-core inbound) ─────────────────────────────
  o = section.option(form.Value, "openconnect_cookie", _("Cookie"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "openconnect_cookie");
    if (current) return current;
    const value = generatePassword();
    uci.set(UCI_PACKAGE, sectionId, "openconnect_cookie", value);
    return value;
  };
  o.depends("protocol", "openconnect");

  o = section.option(
    form.ListValue,
    "openconnect_flavor",
    _("Flavor"),
    _("VPN client flavor the inbound emulates"),
  );
  o.value("anyconnect", "Cisco AnyConnect");
  o.value("gp", "GlobalProtect");
  o.value("nc", "Juniper NC");
  o.value("f5", "F5");
  o.value("fortinet", "Fortinet");
  o.value("pulse", "Pulse");
  o.default = "anyconnect";
  o.modalonly = true;
  o.depends("protocol", "openconnect");
  o.onchange = function (_ev, sectionId, value) {
    const defaults = getOpenconnectFlavorDefaults(value);
    setWidgetValue(sectionId, "openconnect_user_agent", defaults.userAgent);
    setWidgetValue(sectionId, "openconnect_local_hostname", defaults.hostname);
    setWidgetValue(sectionId, "openconnect_urlpath", defaults.urlpath);
  };

  o = section.option(form.Value, "openconnect_user_agent", _("User-Agent"));
  o.modalonly = true;
  o.rmempty = true;
  o.depends("protocol", "openconnect");

  o = section.option(
    form.Value,
    "openconnect_local_hostname",
    _("Local hostname"),
  );
  o.modalonly = true;
  o.rmempty = true;
  o.depends("protocol", "openconnect");

  o = section.option(form.Value, "openconnect_urlpath", _("URL path"));
  o.modalonly = true;
  o.rmempty = true;
  o.depends("protocol", "openconnect");

  o = section.option(form.Value, "openconnect_address", _("Client address"));
  o.modalonly = true;
  o.rmempty = true;
  o.depends("protocol", "openconnect");

  o = section.option(form.Value, "openconnect_mtu", _("MTU"));
  o.modalonly = true;
  o.rmempty = true;
  o.placeholder = "1400";
  o.validate = validateOptionalPort;
  o.depends("protocol", "openconnect");

  o = section.option(form.Flag, "openconnect_ip", _("IP tunnel mode"));
  o.default = "0";
  o.modalonly = true;
  o.depends("protocol", "openconnect");

  o = section.option(
    form.Flag,
    "openconnect_esp",
    _("Use ESP (needs IP mode)"),
  );
  o.default = "0";
  o.modalonly = true;
  o.depends("protocol", "openconnect");

  o = section.option(
    form.Flag,
    "openconnect_dtls",
    _("Use DTLS (anyconnect only)"),
  );
  o.default = "0";
  o.modalonly = true;
  o.depends("protocol", "openconnect");

  o = section.option(
    form.ListValue,
    "tuic_congestion_control",
    _("Congestion control"),
  );
  o.value("bbr", "BBR");
  o.value("cubic", "Cubic");
  o.value("new_reno", "New Reno");
  o.default = "bbr";
  o.modalonly = true;
  o.depends("protocol", "tuic");

  o = section.option(
    form.Value,
    "shadowtls_handshake_server",
    _("Handshake server"),
  );
  o.default = "www.microsoft.com";
  o.modalonly = true;
  o.depends("protocol", "shadowtls");

  o = section.option(
    form.Value,
    "shadowtls_handshake_server_port",
    _("Handshake server port"),
  );
  o.default = "443";
  o.modalonly = true;
  o.validate = validatePort;
  o.depends("protocol", "shadowtls");

  o = section.option(
    form.ListValue,
    "shadowtls_version",
    _("ShadowTLS version"),
  );
  o.value("3", "v3");
  o.value("2", "v2");
  o.default = "3";
  o.modalonly = true;
  o.depends("protocol", "shadowtls");

  o = section.option(form.Value, "vmess_alter_id", _("Alter ID"));
  o.default = "0";
  o.rmempty = false;
  o.modalonly = true;
  o.depends("protocol", "vmess");
  o.validate = function (_sectionId, value) {
    if (value == null || value === "") {
      return _("This field is required");
    }
    return /^[0-9]+$/.test(value) ? true : _("Use a non-negative integer");
  };

  o = section.option(form.ListValue, "vless_flow", _("VLESS flow"));
  o.value("none", _("None"));
  o.value("xtls-rprx-vision", "xtls-rprx-vision");
  o.default = "none";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;
  o.depends("protocol", "vless");

  o = section.option(form.ListValue, "hysteria2_obfs_type", _("Obfuscation"));
  o.value("", _("None"));
  o.value("salamander", "salamander");
  o.default = "";
  o.modalonly = true;
  o.depends("protocol", "hysteria2");
  o.onchange = function (_ev, sectionId, value) {
    if (value === "salamander") {
      setDefault(sectionId, "hysteria2_obfs_password", generatePassword());
      const widget = getControlWidget(sectionId, "hysteria2_obfs_password");
      if (widget && !widget.value) {
        setWidgetValue(
          sectionId,
          "hysteria2_obfs_password",
          uci.get(UCI_PACKAGE, sectionId, "hysteria2_obfs_password"),
        );
      }
    }
  };

  o = section.option(
    form.Value,
    "hysteria2_obfs_password",
    _("Obfuscation password"),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "hysteria2_obfs_password");
    if (current) {
      return current;
    }
    const value = generatePassword();
    uci.set(UCI_PACKAGE, sectionId, "hysteria2_obfs_password", value);
    return value;
  };
  o.depends({ protocol: "hysteria2", hysteria2_obfs_type: "salamander" });

  o = section.option(form.Value, "mtproto_secret", _("Secret"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateMtprotoSecret;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "mtproto_secret");
    const baseSecret = normalizeMtprotoBaseSecret(current);
    const faketls = getMtprotoFaketlsFromSecret(current);
    if (baseSecret) {
      uci.set(UCI_PACKAGE, sectionId, "mtproto_secret", baseSecret);
      if (faketls && !uci.get(UCI_PACKAGE, sectionId, "mtproto_faketls")) {
        uci.set(UCI_PACKAGE, sectionId, "mtproto_faketls", faketls);
      }
      return baseSecret;
    }
    if (current) {
      return current;
    }
    const value = generateMtprotoSecret();
    uci.set(UCI_PACKAGE, sectionId, "mtproto_secret", value);
    return value;
  };
  addMtprotoDepends(o);

  o = section.option(form.Value, "mtproto_faketls", _("FakeTLS host"));
  o.default = "google.com";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHost;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "mtproto_faketls");
    if (current) {
      return current;
    }
    const faketls =
      getMtprotoFaketlsFromSecret(
        uci.get(UCI_PACKAGE, sectionId, "mtproto_secret"),
      ) || "google.com";
    uci.set(UCI_PACKAGE, sectionId, "mtproto_faketls", faketls);
    return faketls;
  };
  addMtprotoDepends(o);

  o = section.option(form.Flag, "mtproto_padding", _("Padding"));
  o.default = "1";
  o.modalonly = true;
  o.rmempty = false;
  addMtprotoDepends(o);

  o = section.option(form.Value, "mtproto_concurrency", _("Concurrency"));
  o.modalonly = true;
  o.rmempty = true;
  o.validate = validateOptionalNonNegativeInteger;
  addMtprotoDepends(o);

  o = section.option(
    form.Value,
    "mtproto_domain_fronting_port",
    _("Fronting port"),
  );
  o.default = "443";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validatePort;
  addMtprotoDepends(o);

  o = section.option(
    form.Value,
    "mtproto_domain_fronting_ip",
    _("Fronting IP"),
  );
  o.modalonly = true;
  o.rmempty = true;
  o.validate = validateOptionalIp;
  addMtprotoDepends(o);

  o = section.option(
    form.Flag,
    "mtproto_domain_fronting_proxy_protocol",
    _("Fronting proxy protocol"),
  );
  o.default = "0";
  o.modalonly = true;
  o.rmempty = true;
  addMtprotoDepends(o);

  o = section.option(form.ListValue, "mtproto_prefer_ip", _("Preferred IP"));
  o.value("prefer-ipv4", "prefer-ipv4");
  o.value("prefer-ipv6", "prefer-ipv6");
  o.value("only-ipv4", "only-ipv4");
  o.value("only-ipv6", "only-ipv6");
  o.default = "prefer-ipv4";
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateRequired;
  addMtprotoDepends(o);

  o = section.option(form.Flag, "mtproto_auto_update", _("Auto update"));
  o.default = "0";
  o.modalonly = true;
  o.rmempty = true;
  addMtprotoDepends(o);

  o = section.option(
    form.Flag,
    "mtproto_allow_fallback_on_unknown_dc",
    _("Fallback on unknown DC"),
  );
  o.default = "0";
  o.modalonly = true;
  o.rmempty = true;
  addMtprotoDepends(o);

  o = section.option(
    form.Value,
    "mtproto_tolerate_time_skewness",
    _("Time skew tolerance"),
  );
  o.default = "3s";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredDuration;
  addMtprotoDepends(o);

  o = section.option(form.Value, "mtproto_idle_timeout", _("Idle timeout"));
  o.default = "5m";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredDuration;
  addMtprotoDepends(o);

  o = section.option(
    form.Value,
    "mtproto_handshake_timeout",
    _("Handshake timeout"),
  );
  o.default = "10s";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredDuration;
  addMtprotoDepends(o);

  o = section.option(
    form.Value,
    "tailscale_auth_key",
    _("Tailscale auth key"),
    _(
      "Reusable or ephemeral pre-authentication key to join your Tailnet (e.g. tskey-auth-...).",
    ) +
      ' <a href="https://login.tailscale.com/admin/settings/keys" target="_blank" rel="noopener noreferrer">' +
      _("Generate in Tailscale Admin Console") +
      "</a>",
  );
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  addTailscaleDepends(o);

  o = section.option(
    form.Value,
    "tailscale_control_url",
    _("Tailscale control URL"),
  );
  o.default = "https://controlplane.tailscale.com";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateHttpUrl;
  addTailscaleDepends(o);

  o = section.option(form.Value, "tailscale_hostname", _("Tailscale hostname"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequiredText;
  o.load = function (sectionId) {
    const current = uci.get(UCI_PACKAGE, sectionId, "tailscale_hostname");
    if (current) {
      return current;
    }
    const value = defaultTailscaleHostname(sectionId);
    uci.set(UCI_PACKAGE, sectionId, "tailscale_hostname", value);
    return value;
  };
  addTailscaleDepends(o);

  o = section.option(
    form.Flag,
    "tailscale_advertise_exit_node",
    _("Advertise exit node"),
  );
  o.default = "1";
  o.modalonly = true;
  o.rmempty = false;
  addTailscaleDepends(o);

  o = section.option(
    form.DynamicList,
    "tailscale_advertise_routes",
    _("Advertise routes"),
  );
  o.modalonly = true;
  o.rmempty = true;
  o.validate = (_sectionId, value) => validateOptionalCidrOrIp(value);
  addTailscaleDepends(o);

  o = section.option(form.Flag, "tailscale_accept_routes", _("Accept routes"));
  o.default = "0";
  o.modalonly = true;
  o.rmempty = true;
  addTailscaleDepends(o);

  o = section.option(form.ListValue, "tailscale_mode", _("Tailscale mode"));
  o.value("singbox", _("sing-box endpoint (userspace, default)"));
  o.value(
    "native",
    _("Native tailscaled (tailnet reachable from LAN without client)"),
  );
  o.default = "singbox";
  o.modalonly = true;
  o.rmempty = false;
  addTailscaleDepends(o);

  o = section.option(
    form.Flag,
    "tailscale_auto_firewall",
    _("Auto-configure Tailscale firewall zone"),
    _(
      "Automatically create and maintain the 'tailscale' zone in /etc/config/firewall (device tailscale0, masquerading, MSS clamping, and lan/wan forwardings).",
    ),
  );
  o.default = "1";
  o.modalonly = true;
  o.rmempty = false;
  addTailscaleDepends(o);

  o = section.option(
    form.Flag,
    "tailscale_masquerade",
    _("Masquerade LAN traffic into tailnet"),
    _(
      "SNAT LAN sources when leaving through tailscale0 so peers can answer. Required unless every peer accepts routes.",
    ),
  );
  o.default = "1";
  o.modalonly = true;
  o.rmempty = false;
  o.depends({ protocol: "tailscale", tailscale_mode: "native" });

  o = section.option(
    form.Flag,
    "tailscale_use_exit_node",
    _("Use tailnet exit node for LAN"),
    _(
      "Route all non-local LAN traffic through the tailnet exit node instead of the proxy engines.",
    ),
  );
  o.default = "0";
  o.modalonly = true;
  o.rmempty = false;
  o.depends({ protocol: "tailscale", tailscale_mode: "native" });

  // AWG Server Options
  o = section.option(
    form.Value,
    "awg_local_address",
    _("Server Address"),
    _("Server VPN IP address and subnet (e.g. 10.0.0.1/24)"),
  );
  o.default = "10.0.0.1/24";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  o.depends("protocol", "awg");

  o = section.option(
    form.Value,
    "awg_client_address",
    _("Client Address"),
    _("Client VPN IP address (e.g. 10.0.0.2/32)"),
  );
  o.default = "10.0.0.2/32";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  o.depends("protocol", "awg");

  o = section.option(
    form.Value,
    "awg_dns",
    _("Client DNS"),
    _("DNS server pushed to the client configuration"),
  );
  o.default = "10.0.0.1";
  o.modalonly = true;
  o.rmempty = false;
  o.depends("protocol", "awg");

  o = section.option(form.Value, "awg_mtu", _("MTU"));
  o.default = "1280";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validatePositiveInteger;
  o.depends("protocol", "awg");

  o = section.option(form.Value, "awg_keepalive", _("Persistent Keepalive"));
  o.default = "25";
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validatePositiveInteger;
  o.depends("protocol", "awg");

  o = section.option(form.Value, "awg_private_key", _("Server Private Key"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  o.depends("protocol", "awg");

  o = section.option(
    form.Value,
    "awg_server_public_key",
    _("Server Public Key"),
  );
  o.modalonly = true;
  o.rmempty = true;
  o.depends("protocol", "awg");

  o = section.option(
    form.Value,
    "awg_client_private_key",
    _("Client Private Key"),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  o.depends("protocol", "awg");

  o = section.option(form.Value, "awg_peer_public_key", _("Client Public Key"));
  o.modalonly = true;
  o.rmempty = false;
  o.validate = validateRequired;
  o.depends("protocol", "awg");

  o = section.option(
    form.Value,
    "awg_preshared_key",
    _("Pre-shared Key (PSK)"),
  );
  o.modalonly = true;
  o.rmempty = true;
  o.depends("protocol", "awg");

  o = section.option(
    form.ListValue,
    "awg_version",
    _("AmneziaWG Version"),
    _(
      "Protocol version: 2.0 (standard integer headers) or 3.1 (header protection key, padding ranges, advanced timers)",
    ),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.default = "2.0";
  o.value("2.0", "AmneziaWG 2.0");
  o.value("3.0", "AmneziaWG 3.0");
  o.value("3.1", "AmneziaWG 3.1");
  o.depends("protocol", "awg");
  o.onchange = function (_ev, sectionId, value) {
    if (value === "3.0" || value === "3.1") {
      if (!getCurrentOptionValue(sectionId, "awg_header_protection_key", "")) {
        setWidgetValue(
          sectionId,
          "awg_header_protection_key",
          generateBase64Key(32),
        );
      }
      if (
        !getCurrentOptionValue(sectionId, "awg_content_padding_addition", "")
      ) {
        setWidgetValue(sectionId, "awg_content_padding_addition", "38-104");
      }
    }
    if (value === "3.1") {
      if (!getCurrentOptionValue(sectionId, "awg_rekey_after_time", "")) {
        setWidgetValue(sectionId, "awg_rekey_after_time", "120");
      }
      if (!getCurrentOptionValue(sectionId, "awg_rekey_timeout", "")) {
        setWidgetValue(sectionId, "awg_rekey_timeout", "5");
      }
      if (!getCurrentOptionValue(sectionId, "awg_reject_after_time", "")) {
        setWidgetValue(sectionId, "awg_reject_after_time", "180");
      }
      if (!getCurrentOptionValue(sectionId, "awg_keepalive_timeout", "")) {
        setWidgetValue(sectionId, "awg_keepalive_timeout", "10");
      }
      if (!getCurrentOptionValue(sectionId, "awg_max_handshake_attempts", "")) {
        setWidgetValue(sectionId, "awg_max_handshake_attempts", "10");
      }
    }
  };
  o.write = function (section_id, formvalue) {
    if (formvalue === "2.0") {
      uci.unset(UCI_PACKAGE, section_id, "awg_header_protection_key");
      uci.unset(UCI_PACKAGE, section_id, "awg_content_padding_addition");
      uci.unset(UCI_PACKAGE, section_id, "awg_rekey_after_time");
      uci.unset(UCI_PACKAGE, section_id, "awg_rekey_timeout");
      uci.unset(UCI_PACKAGE, section_id, "awg_reject_after_time");
      uci.unset(UCI_PACKAGE, section_id, "awg_keepalive_timeout");
      uci.unset(UCI_PACKAGE, section_id, "awg_max_handshake_attempts");
    } else if (formvalue === "3.0") {
      uci.unset(UCI_PACKAGE, section_id, "awg_rekey_after_time");
      uci.unset(UCI_PACKAGE, section_id, "awg_rekey_timeout");
      uci.unset(UCI_PACKAGE, section_id, "awg_reject_after_time");
      uci.unset(UCI_PACKAGE, section_id, "awg_keepalive_timeout");
      uci.unset(UCI_PACKAGE, section_id, "awg_max_handshake_attempts");
    }
    return uci.set(UCI_PACKAGE, section_id, "awg_version", formvalue);
  };

  const awgV3ParamNames = [
    "awg_header_protection_key",
    "awg_content_padding_addition",
  ];

  const awgV31TimerNames = [
    "awg_rekey_after_time",
    "awg_rekey_timeout",
    "awg_reject_after_time",
    "awg_keepalive_timeout",
    "awg_max_handshake_attempts",
  ];

  const awgParams = [
    {
      name: "awg_jc",
      title: _("Junk packet count (Jc)"),
      desc: _("Number of junk packets before handshake (1-10)"),
      default: "4",
    },
    {
      name: "awg_jmin",
      title: _("Junk packet min size (Jmin)"),
      desc: _("Minimum size of junk packets"),
      default: "40",
    },
    {
      name: "awg_jmax",
      title: _("Junk packet max size (Jmax)"),
      desc: _("Maximum size of junk packets"),
      default: "70",
    },
    {
      name: "awg_s1",
      title: _("Init packet junk size (S1)"),
      desc: _("Junk size for initiation packet"),
      default: "0",
    },
    {
      name: "awg_s2",
      title: _("Response packet junk size (S2)"),
      desc: _("Junk size for response packet"),
      default: "0",
    },
    {
      name: "awg_s3",
      title: _("Cookie packet junk size (S3)"),
      desc: _("Junk size for cookie packet"),
      default: "0",
    },
    {
      name: "awg_s4",
      title: _("Transport packet junk size (S4)"),
      desc: _("Junk size for transport packet"),
      default: "0",
    },
    {
      name: "awg_h1",
      title: _("Init packet header (H1)"),
      desc: _("Custom header for handshake initiation"),
      default: "1",
    },
    {
      name: "awg_h2",
      title: _("Response packet header (H2)"),
      desc: _("Custom header for handshake response"),
      default: "2",
    },
    {
      name: "awg_h3",
      title: _("Underload packet header (H3)"),
      desc: _("Custom header for cookie packet"),
      default: "3",
    },
    {
      name: "awg_h4",
      title: _("Transport packet header (H4)"),
      desc: _("Custom header for data packet"),
      default: "4",
    },
    {
      name: "awg_i1",
      title: _("Init payload (I1)"),
      desc: _("Hex or binary payload for init"),
      default: "",
    },
    {
      name: "awg_i2",
      title: _("Response payload (I2)"),
      desc: _("Hex or binary payload for response"),
      default: "",
    },
    {
      name: "awg_i3",
      title: _("Payload (I3)"),
      desc: _("Hex or binary payload"),
      default: "",
    },
    {
      name: "awg_i4",
      title: _("Payload (I4)"),
      desc: _("Hex or binary payload"),
      default: "",
    },
    {
      name: "awg_i5",
      title: _("Payload (I5)"),
      desc: _("Hex or binary payload"),
      default: "",
    },
    {
      name: "awg_j1",
      title: _("Junk payload (J1)"),
      desc: _("Hex or binary junk payload"),
      default: "",
    },
    {
      name: "awg_j2",
      title: _("Junk payload (J2)"),
      desc: _("Hex or binary junk payload"),
      default: "",
    },
    {
      name: "awg_j3",
      title: _("Junk payload (J3)"),
      desc: _("Hex or binary junk payload"),
      default: "",
    },
    {
      name: "awg_itime",
      title: _("Init timeout (Itime)"),
      desc: _("Init handshake timeout"),
      default: "",
    },
    {
      name: "awg_header_protection_key",
      title: _("Header Protection Key"),
      desc: _("AmneziaWG 3.1 header protection key"),
      default: "",
    },
    {
      name: "awg_content_padding_addition",
      title: _("Content Padding Addition"),
      desc: _("AmneziaWG 3.1 content padding range, e.g. 38-104"),
      default: "",
    },
    {
      name: "awg_rekey_after_time",
      title: _("Rekey After Time"),
      desc: _("AmneziaWG 3.1 rekey after time"),
      default: "",
    },
    {
      name: "awg_rekey_timeout",
      title: _("Rekey Timeout"),
      desc: _("AmneziaWG 3.1 rekey timeout"),
      default: "",
    },
    {
      name: "awg_reject_after_time",
      title: _("Reject After Time"),
      desc: _("AmneziaWG 3.1 reject after time"),
      default: "",
    },
    {
      name: "awg_keepalive_timeout",
      title: _("Keepalive Timeout"),
      desc: _("AmneziaWG 3.1 keepalive timeout"),
      default: "",
    },
    {
      name: "awg_max_handshake_attempts",
      title: _("Max Handshake Attempts"),
      desc: _("AmneziaWG 3.1 max handshake attempts"),
      default: "",
    },
  ];

  awgParams.forEach((param) => {
    let opt = section.option(form.Value, param.name, param.title, param.desc);
    opt.modalonly = true;
    opt.rmempty = true;
    if (param.default !== "") opt.default = param.default;
    if (awgV31TimerNames.includes(param.name)) {
      opt.depends({ protocol: "awg", awg_version: "3.1" });
    } else if (awgV3ParamNames.includes(param.name)) {
      opt.depends({ protocol: "awg", awg_version: "3.0" });
      opt.depends({ protocol: "awg", awg_version: "3.1" });
    } else {
      opt.depends("protocol", "awg");
    }
  });
}

function subscriptionServerProtocol(server) {
  if ((server.protocol || "vless") !== "json_inbound") {
    return server.protocol || "vless";
  }
  try {
    return JSON.parse(server.inbound_json || "{}").type === "mieru"
      ? "mieru"
      : "";
  } catch (_error) {
    return "";
  }
}

function subscriptionServerSupported(server) {
  return [
    "vless",
    "vmess",
    "trojan",
    "shadowsocks",
    "socks",
    "mixed",
    "http",
    "naive",
    "hysteria2",
    "tuic",
    "anytls",
    "shadowtls",
    "fptn",
    "mtproto",
    "mieru",
    "trusttunnel",
    "tewfai",
    "masque",
    "openconnect",
  ].includes(subscriptionServerProtocol(server));
}

function subscriptionUrl(options) {
  const host = normalizeHost(options.host);
  const port = Number(options.port);
  if (
    !isHost(host) ||
    !Number.isInteger(port) ||
    port < 1 ||
    port > 65535 ||
    !/^[0-9a-f]{64}$/.test(options.token) ||
    !["http", "https"].includes(options.scheme) ||
    !["plain", "base64"].includes(options.format)
  )
    return "";
  const defaultPort = options.scheme === "https" ? 443 : 80;
  return `${options.scheme}://${formatHostForUri(host)}${port === defaultPort ? "" : `:${port}`}/cgi-bin/tachyon-sub/${options.token}?format=${options.format}`;
}

function subscriptionToken() {
  // A subscription grants access to all selected credentials. Never fall back to Math.random().
  if (!window.crypto?.getRandomValues)
    throw new Error(_("Secure random generator is unavailable"));
  return Array.from(window.crypto.getRandomValues(new Uint8Array(32)))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function showSubscriptionModal(section) {
  const get = (key) =>
    uci.get(UCI_PACKAGE, "settings", `server_subscription_${key}`);
  const servers = uci.sections(UCI_PACKAGE, "server");
  let token;
  try {
    token = /^[0-9a-f]{64}$/.test(get("token") || "")
      ? get("token")
      : subscriptionToken();
  } catch (error) {
    ui.addNotification(null, E("p", {}, error.message), "error");
    return;
  }
  const enabled = E("input", {
    type: "checkbox",
  });
  enabled.checked = get("enabled") === "1";
  const host = E("input", {
    class: "cbi-input-text",
    type: "text",
    value:
      get("host") ||
      servers.find((s) => s.public_host)?.public_host ||
      window.location.hostname,
  });
  const scheme = E("select", { class: "cbi-input-select" }, [
    E("option", { value: "https" }, "HTTPS"),
    E("option", { value: "http" }, "HTTP"),
  ]);
  scheme.value = get("scheme") || "https";
  const port = E("input", {
    class: "cbi-input-text",
    type: "number",
    min: 1,
    max: 65535,
    value: get("port") || "443",
  });
  const format = E("select", { class: "cbi-input-select" }, [
    E("option", { value: "base64" }, "Base64"),
    E("option", { value: "plain" }, _("Connection URLs (text)")),
  ]);
  format.value = get("format") || "base64";
  const all = E("input", {
    type: "checkbox",
  });
  all.checked = get("mode") !== "selected";
  const selected = asList(get("servers"));
  const choices = servers.map((server) => {
    const supported = subscriptionServerSupported(server);
    const active = !["0", "false"].includes(`${server.enabled ?? "1"}`);
    const available = supported && active;
    const checkbox = E("input", {
      type: "checkbox",
    });
    checkbox.checked =
      available && (all.checked || selected.includes(server[".name"]));
    checkbox.disabled = !available || all.checked;
    const suffix = !supported
      ? _("No subscription URL")
      : !active
        ? _("Disabled")
        : subscriptionServerProtocol(server);
    return {
      id: server[".name"],
      available,
      checkbox,
      node: E(
        "label",
        { style: "display:flex;gap:.5em;align-items:center;margin:.45em 0" },
        [
          checkbox,
          E("span", {}, `${server.label || server[".name"]} — ${suffix}`),
        ],
      ),
    };
  });
  all.addEventListener("change", () =>
    choices.forEach((choice) => {
      choice.checkbox.disabled = !choice.available || all.checked;
      if (all.checked && choice.available) choice.checkbox.checked = true;
    }),
  );
  const url = E("input", {
    class: "cbi-input-text",
    type: "password",
    readonly: true,
    "aria-label": _("Subscription URL"),
    autocomplete: "off",
    style: "width:100%;box-sizing:border-box",
  });
  const qr = E("div", { style: "display:none;margin-top:1em" });
  const update = () => {
    url.value = subscriptionUrl({
      host: host.value,
      port: port.value,
      scheme: scheme.value,
      format: format.value,
      token,
    });
    if (qr.style.display !== "none")
      dom.content(
        qr,
        url.value
          ? E("img", {
              src: qrSvgDataUri(url.value),
              alt: _("Subscription QR code"),
              style: "max-width:100%;width:220px",
            })
          : [],
      );
  };
  [host, port, scheme, format].forEach((input) =>
    input.addEventListener("input", update),
  );
  const field = (title, input) =>
    E("label", { style: "display:block;margin:.8em 0" }, [
      E("span", { style: "display:block;margin-bottom:.3em" }, title),
      input,
    ]);
  const copy = E(
    "button",
    { type: "button", class: "cbi-button", click: () => copyText(url.value) },
    _("Copy"),
  );
  const qrButton = E(
    "button",
    {
      type: "button",
      class: "cbi-button",
      click: () => {
        qr.style.display = qr.style.display === "none" ? "block" : "none";
        update();
      },
    },
    _("QR code"),
  );
  const rotate = E(
    "button",
    {
      type: "button",
      class: "cbi-button",
      click: () => {
        token = subscriptionToken();
        update();
        notice.textContent = _(
          "The old URL will stop working after Save & Apply.",
        );
      },
    },
    _("Change subscription URL"),
  );
  const notice = E(
    "p",
    { role: "status" },
    _("Use Save & Apply on the main page to activate these settings."),
  );
  const save = E(
    "button",
    {
      type: "button",
      class: "cbi-button cbi-button-positive",
      click: async () => {
        update();
        if (
          enabled.checked &&
          (!url.value ||
            !choices.some(
              (choice) => choice.available && choice.checkbox.checked,
            ))
        ) {
          ui.addNotification(
            null,
            E(
              "p",
              {},
              _(
                "Enter a valid public host and port, and select at least one enabled server.",
              ),
            ),
            "error",
          );
          return;
        }
        save.disabled = true;
        try {
          const values = {
            enabled: enabled.checked ? "1" : "0",
            host: normalizeHost(host.value),
            port: `${Number(port.value)}`,
            scheme: scheme.value,
            format: format.value,
            mode: all.checked ? "all" : "selected",
            token,
          };
          Object.entries(values).forEach(([key, value]) =>
            uci.set(
              UCI_PACKAGE,
              "settings",
              `server_subscription_${key}`,
              value,
            ),
          );
          uci.set(
            UCI_PACKAGE,
            "settings",
            "server_subscription_servers",
            choices
              .filter((choice) => choice.available && choice.checkbox.checked)
              .map((choice) => choice.id),
          );
          // Stage UCI directly; parsing the whole page would also write unrelated defaults.
          await uci.save();
          await ui.changes.init();
          ui.hideModal();
          ui.addNotification(
            null,
            E(
              "p",
              {},
              _(
                "Subscription settings saved. Use Save & Apply to activate them.",
              ),
            ),
            "info",
          );
        } catch (error) {
          ui.addNotification(null, E("p", {}, error.message), "error");
        } finally {
          save.disabled = false;
        }
      },
    },
    _("Save"),
  );
  update();
  ui.showModal(
    _("Configure subscription"),
    [
      E(
        "p",
        {},
        _(
          "One URL imports the selected enabled servers and updates their connection settings in the client.",
        ),
      ),
      field(_("Enable subscription"), enabled),
      field(_("Public host"), host),
      E("div", { style: "display:flex;gap:1em;flex-wrap:wrap" }, [
        field(_("Protocol"), scheme),
        field(_("Port"), port),
        field(_("Format"), format),
      ]),
      E(
        "p",
        { class: "alert-message notice" },
        _(
          "The public address must reach this router's subscription endpoint. HTTPS needs a valid certificate. This setting does not open WAN ports or publish LuCI.",
        ),
      ),
      field(_("Include all enabled servers"), all),
      ...choices.map((choice) => choice.node),
      field(_("Subscription URL"), url),
      E("div", { style: "display:flex;gap:.5em;flex-wrap:wrap" }, [
        copy,
        qrButton,
        rotate,
      ]),
      qr,
      notice,
      E(
        "div",
        {
          class: "right",
          style:
            "margin-top:1em;display:flex;gap:.5em;justify-content:flex-end",
        },
        [
          E(
            "button",
            {
              type: "button",
              class: "cbi-button",
              click: () => ui.hideModal(),
            },
            _("Cancel"),
          ),
          save,
        ],
      ),
    ],
    "fkp-subscription-dialog",
  );
}

function configureServerSubscription(section) {
  const description = section.description;
  section.description = E("div", {}, [
    E("div", { style: "margin-bottom:1em" }, [
      E(
        "button",
        {
          type: "button",
          class: "cbi-button cbi-button-action",
          click: (event) => {
            event.preventDefault();
            showSubscriptionModal(section);
          },
        },
        _("Configure subscription"),
      ),
    ]),
    E("div", {}, description),
    E("div", { id: "tachyon-server-inbounds-overview" }),
  ]);
  if (
    typeof main !== "undefined" &&
    typeof main.renderServerTabInboundsOverview === "function"
  ) {
    setTimeout(() => main.renderServerTabInboundsOverview(), 0);
  }
}

return baseclass.extend({
  applyServerCapabilities,
  configureServerSection,
  configureServerSubscription,
  createServerContent,
  preloadServerModalData,
});
