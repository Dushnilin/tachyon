/**
 * Decode subscription header values such as `profile-title` or `announce`
 * when encoded with the standard `base64:` UTF-8 prefix.
 * Returns the original value untouched if no prefix is present or decoding fails.
 */
export function decodeSubHeaderValue(raw?: string | null): string {
  const s = typeof raw === 'string' ? raw.trim() : '';
  if (!s) {
    return '';
  }

  const lower = s.toLowerCase();
  if (!lower.startsWith('base64:')) {
    return s;
  }

  const encoded = s.slice(7).trim();
  if (!encoded) {
    return s;
  }

  try {
    let b64 = encoded.replace(/-/g, '+').replace(/_/g, '/');
    const pad = b64.length % 4;
    if (pad === 2) {
      b64 += '==';
    } else if (pad === 3) {
      b64 += '=';
    } else if (pad === 1) {
      return s;
    }

    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i += 1) {
      bytes[i] = bin.charCodeAt(i);
    }

    if (typeof TextDecoder === 'function') {
      const decoded = new TextDecoder('utf-8', { fatal: true })
        .decode(bytes)
        .trim();
      return decoded || s;
    }

    const decoded = decodeURIComponent(escape(bin)).trim();
    return decoded || s;
  } catch {
    return s;
  }
}
