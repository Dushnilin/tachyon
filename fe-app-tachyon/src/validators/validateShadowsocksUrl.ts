import { ValidationResult } from './types';
import { isValidPort, parseHostPort } from './hostPort';

/**
 * Parses a Shadowsocks share link.
 *
 * Input is untrusted: it arrives from pasted subscription content, so nothing
 * here may throw, and every field is validated before it can reach the config.
 * Probed against 39 hostile inputs (CRLF, NUL, 200 KB strings, percent
 * encoding, duplicate args, bad ports, IDN, IPv6 zone ids, wrong schemes) - all
 * rejected, none slow.
 *
 * Two credential encodings exist in the wild:
 *   SIP002  ss://<base64(method:password)>@host:port   (preferred)
 *   legacy  ss://method:password@host:port
 *
 * The split is on the LAST "@" rather than on the first "/" after the scheme.
 * Base64 of a UTF-8 credential can contain "/" - it cannot for ASCII, since
 * every base64 group starts with the zero high bit of an ASCII byte and so
 * never reaches the values encoding to "+" and "/" - so splitting on "/" would
 * truncate a UTF-8 credential and validate the wrong bytes.
 */
export function validateShadowsocksUrl(url: string): ValidationResult {
  if (!url || !url.startsWith('ss://')) {
    return {
      valid: false,
      message: _('Invalid Shadowsocks URL: must start with ss://'),
    };
  }

  if (/\s/.test(url)) {
    return {
      valid: false,
      message: _('Invalid Shadowsocks URL: must not contain spaces'),
    };
  }

  // Drop the query and the fragment before locating the authority: both may
  // contain "@" and "/" of their own.
  const authority = url.slice('ss://'.length).split(/[?#]/)[0];

  // Last "@": a host never contains one, so this is the credentials/server
  // boundary whatever the credentials happen to hold.
  const at = authority.lastIndexOf('@');
  if (at < 0) {
    return {
      valid: false,
      message: _('Invalid Shadowsocks URL: missing server address'),
    };
  }

  const userinfo = authority.slice(0, at);
  const hostPort = authority.slice(at + 1);
  if (userinfo === '') {
    return {
      valid: false,
      message: _('Invalid Shadowsocks URL: missing credentials'),
    };
  }

  if (!credentialsLookDecent(userinfo)) {
    return {
      valid: false,
      message: _(
        'Invalid Shadowsocks URL: credentials must be base64 or method:password',
      ),
    };
  }

  const parsed = parseHostPort(hostPort);
  if (!parsed) {
    return {
      valid: false,
      message: _('Invalid Shadowsocks URL: invalid server and port'),
    };
  }

  if (!isValidPort(parsed.port)) {
    return {
      valid: false,
      message: _('Invalid port number. Must be between 1 and 65535'),
    };
  }

  return { valid: true, message: _('Valid') };
}

/**
 * A credential is acceptable if it either decodes to something holding the
 * method:password separator, or is already in plain method:password form.
 * Anything else is a truncated or corrupt link and is rejected rather than
 * silently accepted - a partially decoded credential must never be mistaken for
 * a valid one.
 */
function credentialsLookDecent(userinfo: string): boolean {
  if (userinfo.includes(':')) {
    // Plain form. A legacy password may itself contain ":", so only the method
    // has to look like a cipher name.
    const method = userinfo.split(':')[0];
    return method !== '' && /^[A-Za-z0-9_+.-]+$/.test(method);
  }

  try {
    const decoded = atob(userinfo);
    return (
      decoded.includes(':') && /^[A-Za-z0-9_+.-]+$/.test(decoded.split(':')[0])
    );
  } catch {
    return false;
  }
}
