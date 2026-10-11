import { ValidationResult } from './types';

export function validateFptnUrl(url: string): ValidationResult {
  const trimmed = url.trim();
  const prefixes = ['fptnb://', 'fptn://', 'fptnb:', 'fptn:'];
  const prefix = prefixes.find((p) => trimmed.startsWith(p));
  if (!prefix) {
    return {
      valid: false,
      message: _('Invalid FPTN URL: must start with fptn: or fptnb:'),
    };
  }

  const body = trimmed.slice(prefix.length).split('#')[0].trim();
  if (!body) {
    return {
      valid: false,
      message: _('Invalid FPTN URL: missing token body'),
    };
  }

  const cleaned = body.replace(/[\s=]/g, '');
  if (cleaned.length % 4 === 1 || !/^[A-Za-z0-9+/_-]+$/.test(cleaned)) {
    return {
      valid: false,
      message: _('Invalid FPTN URL: invalid base64 token payload'),
    };
  }

  return { valid: true, message: _('Valid') };
}
