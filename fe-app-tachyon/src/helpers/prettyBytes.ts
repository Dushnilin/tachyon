// steal from https://github.com/sindresorhus/pretty-bytes/blob/master/index.js
export function prettyBytes(n: number) {
  const UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];

  if (n < 1000) {
    return n + ' B';
  }
  const exponent = Math.min(Math.floor(Math.log10(n) / 3), UNITS.length - 1);
  n = Number((n / Math.pow(1000, exponent)).toPrecision(3));
  const unit = UNITS[exponent];
  return n + ' ' + unit;
}

export function formatSubscriptionBytes(bytes?: number) {
  const b = Number(bytes || 0);
  if (!Number.isFinite(b) || b <= 0) return '0 B';
  const gb = b / (1024 * 1024 * 1024);
  if (gb >= 1) return `${gb.toFixed(1)} GB`;
  const mb = b / (1024 * 1024);
  if (mb >= 1) return `${mb.toFixed(0)} MB`;
  const kb = b / 1024;
  if (kb >= 1) return `${kb.toFixed(0)} KB`;
  return `${Math.round(b)} B`;
}
