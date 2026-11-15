export function getProxyUrlName(url: string) {
  try {
    const [link, hash] = url.split('#');

    if (hash) {
      return decodeURIComponent(hash);
    }

    const trimmed = link.trim();
    if (/^mierus?:\/\//i.test(trimmed)) {
      const qIdx = trimmed.indexOf('?');
      if (qIdx >= 0) {
        const profile = new URLSearchParams(trimmed.slice(qIdx + 1)).get(
          'profile',
        );
        if (profile && profile.trim()) {
          return profile.trim();
        }
      }
    }

    return '';
  } catch {
    return '';
  }
}
