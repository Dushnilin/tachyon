export function getProxyUrlTransport(url?: string): string | undefined {
  if (!url || typeof url !== 'string') {
    return undefined;
  }

  try {
    const trimmed = url.trim();
    if (trimmed.startsWith('vmess://')) {
      const b64 = trimmed.slice(8).split('#')[0];
      if (typeof atob === 'function') {
        const jsonStr = atob(b64.replace(/[\r\n]/g, ''));
        const obj = JSON.parse(jsonStr);
        if (obj && typeof obj.net === 'string' && obj.net.trim()) {
          return obj.net.trim().toLowerCase();
        }
      }
    }

    const [base] = trimmed.split('#');
    const queryIdx = base.indexOf('?');
    if (queryIdx !== -1) {
      const query = base.slice(queryIdx + 1);
      const params = new URLSearchParams(query);
      const transport =
        params.get('type') || params.get('transport') || params.get('protocol');
      if (transport && transport.trim()) {
        return transport.split(',')[0].trim().toLowerCase();
      }
    }
  } catch {
    // Ignore URL parse errors
  }

  return undefined;
}
