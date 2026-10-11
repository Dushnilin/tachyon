const COPYABLE_PROXY_URI_RE =
  /^(vless|vmess|trojan|ss|ssr|hysteria2|hy2|tuic|anytls|shadowtls|naive|socks4|socks4a|socks5|http|https|vpn):\/\/|^fptn[b]?(:|\/\/)/i;

export function isCopyableProxyLink(link?: string) {
  return COPYABLE_PROXY_URI_RE.test((link || '').trim());
}
