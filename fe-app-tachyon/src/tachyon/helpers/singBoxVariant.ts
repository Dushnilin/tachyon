type SingBoxVariantFields = {
  sing_box_version?: string;
  sing_box_extended?: number;
  sing_box_tiny?: number;
  sing_box_compressed?: number;
  sing_box_lx?: number;
  sing_box_tailscale?: number;
  sing_box_repo_url?: string;
};

function isExtendedSingBoxVersion(version?: string) {
  return (
    String(version || '').includes('extended') ||
    String(version || '').includes('-lx')
  );
}

function isVersionPlaceholder(version?: string) {
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

export function formatSingBoxVersion(value: SingBoxVariantFields) {
  const version = String(value.sing_box_version || '');

  if (!version || version === 'not installed') {
    return _('Not installed');
  }

  if (isVersionPlaceholder(version)) {
    return version;
  }

  const normalizedValue = normalizeSingBoxVariantFields(value);
  let variant = '';

  if (
    normalizedValue.sing_box_extended &&
    normalizedValue.sing_box_compressed
  ) {
    variant = _('compressed');
  } else if (normalizedValue.sing_box_extended && normalizedValue.sing_box_lx) {
    variant = _('lx');
  } else if (normalizedValue.sing_box_extended) {
    variant = _('extended');
  } else if (normalizedValue.sing_box_tiny) {
    variant = _('tiny');
  }

  return variant ? `${version} (${variant})` : version;
}

export function normalizeSingBoxVariantFields<T extends SingBoxVariantFields>(
  value: T,
): T {
  const version = String(value.sing_box_version || '');
  const versionExtended = isExtendedSingBoxVersion(version);
  const versionLx = version.includes('-lx');
  const singBoxExtended = Boolean(value.sing_box_extended) || versionExtended;
  const singBoxLx =
    singBoxExtended && (Boolean(value.sing_box_lx) || versionLx);

  return {
    ...value,
    sing_box_extended: singBoxExtended ? 1 : 0,
    sing_box_tiny: singBoxExtended ? 0 : value.sing_box_tiny ? 1 : 0,
    sing_box_compressed: singBoxExtended && value.sing_box_compressed ? 1 : 0,
    sing_box_lx: singBoxLx ? 1 : 0,
    sing_box_tailscale: singBoxExtended || value.sing_box_tailscale ? 1 : 0,
  } as T;
}

export function renderSingBoxVariantBadge(
  value: SingBoxVariantFields,
): HTMLSpanElement | null {
  const version = String(value.sing_box_version || '');
  if (!version || isVersionPlaceholder(version)) {
    return null;
  }

  const normalized = normalizeSingBoxVariantFields(value);
  const badge = document.createElement('span');
  badge.className = 'tachyon-badge';
  badge.style.display = 'inline-block';
  badge.style.marginLeft = '8px';
  badge.style.padding = '2px 8px';
  badge.style.borderRadius = '9999px';
  badge.style.fontSize = '11px';
  badge.style.fontWeight = '600';
  badge.style.lineHeight = '16px';
  badge.style.verticalAlign = 'middle';

  if (normalized.sing_box_lx) {
    badge.textContent = 'Leadaxe (lx)';
    badge.style.backgroundColor = 'rgba(16, 185, 129, 0.15)';
    badge.style.color = '#10b981';
    badge.style.border = '1px solid rgba(16, 185, 129, 0.35)';
  } else if (normalized.sing_box_compressed) {
    badge.textContent = 'Extended (compressed)';
    badge.style.backgroundColor = 'rgba(59, 130, 246, 0.15)';
    badge.style.color = '#3b82f6';
    badge.style.border = '1px solid rgba(59, 130, 246, 0.35)';
  } else if (normalized.sing_box_extended) {
    badge.textContent = 'Extended (shtorm-7)';
    badge.style.backgroundColor = 'rgba(59, 130, 246, 0.15)';
    badge.style.color = '#3b82f6';
    badge.style.border = '1px solid rgba(59, 130, 246, 0.35)';
  } else if (normalized.sing_box_tiny) {
    badge.textContent = 'Tiny';
    badge.style.backgroundColor = 'rgba(245, 158, 11, 0.15)';
    badge.style.color = '#f59e0b';
    badge.style.border = '1px solid rgba(245, 158, 11, 0.35)';
  } else {
    badge.textContent = 'Official';
    badge.style.backgroundColor = 'rgba(107, 114, 128, 0.15)';
    badge.style.color = '#6b7280';
    badge.style.border = '1px solid rgba(107, 114, 128, 0.35)';
  }

  return badge;
}
