function isVersionPlaceholder(version?: string): boolean {
  const normalized = String(version || '')
    .trim()
    .toLowerCase();

  if (
    !normalized ||
    normalized === 'loading' ||
    normalized === 'unknown' ||
    normalized === 'not installed'
  ) {
    return true;
  }

  return (
    (typeof _ === 'function' && normalized === _('unknown').toLowerCase()) ||
    (typeof _ === 'function' && normalized === _('Not installed').toLowerCase())
  );
}

export function isNotInstalled(version?: string): boolean {
  const normalized = String(version || '')
    .trim()
    .toLowerCase();
  return (
    !normalized ||
    normalized === 'not installed' ||
    (typeof _ === 'function' && normalized === _('Not installed').toLowerCase())
  );
}

export function formatCoreVersion(version?: string): string {
  const raw = String(version || '').trim();

  if (!raw || isNotInstalled(raw)) {
    return _('Not installed');
  }

  if (isVersionPlaceholder(raw)) {
    return raw;
  }

  return raw;
}
