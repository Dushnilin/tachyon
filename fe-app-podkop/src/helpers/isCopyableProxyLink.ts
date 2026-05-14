const COPYABLE_PROXY_URI_RE =
  /^(vless|vmess|trojan|ss|ssr|hysteria2|hy2|tuic|socks4|socks4a|socks5):\/\//i;

const COPYABLE_PROXY_OUTBOUND_TYPES = new Set([
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'ss',
  'shadowsocksr',
  'ssr',
  'hysteria2',
  'hy2',
  'tuic',
  'socks',
  'socks4',
  'socks4a',
  'socks5',
]);

export function isCopyableProxyLink(link?: string) {
  return COPYABLE_PROXY_URI_RE.test((link || '').trim());
}

export function isCopyableProxyOutboundType(type?: string) {
  return COPYABLE_PROXY_OUTBOUND_TYPES.has((type || '').trim().toLowerCase());
}
