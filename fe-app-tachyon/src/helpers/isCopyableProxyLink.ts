const COPYABLE_PROXY_URI_RE =
  /^(vless|vmess|trojan|ss|ssr|hysteria2|hy2|tuic|anytls|shadowtls|naive|naive\+https|naive\+quic|snell|mieru|mierus|tg|mtproto|tewfai|trusttunnel|masque|openconnect|anyconnect|socks4|socks4a|socks5|http|https|vpn):\/\/|^fptn[b]?(:|\/\/)/i;

export function isCopyableProxyLink(link?: string) {
  return COPYABLE_PROXY_URI_RE.test((link || '').trim());
}
