import { ValidationResult } from './types';
import { isValidHost, parseHostPort } from './hostPort';

export function validateHttpProxyUrl(url: string): ValidationResult {
  try {
    if (!/^https?:\/\//.test(url)) {
      return {
        valid: false,
        message: _(
          'Invalid HTTP proxy URL: must start with http:// or https://',
        ),
      };
    }

    if (!url || /\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid HTTP proxy URL: must not contain spaces'),
      };
    }

    const body = url.replace(/^https?:\/\//, '');
    if (/[/?#]/.test(body)) {
      return {
        valid: false,
        message: _(
          'Invalid HTTP proxy URL: path, query, and fragment are not supported',
        ),
      };
    }

    const atIndex = body.lastIndexOf('@');
    const credentials = atIndex >= 0 ? body.slice(0, atIndex) : '';
    const hostPortPart = atIndex >= 0 ? body.slice(atIndex + 1) : body;

    if (credentials) {
      const [username] = credentials.split(':');
      if (!username) {
        return {
          valid: false,
          message: _('Invalid HTTP proxy URL: missing username'),
        };
      }
    }

    if (!hostPortPart) {
      return {
        valid: false,
        message: _('Invalid HTTP proxy URL: missing host and port'),
      };
    }

    const parsedHostPort = parseHostPort(hostPortPart);
    if (!parsedHostPort) {
      return {
        valid: false,
        message: _('Invalid HTTP proxy URL: invalid host and port'),
      };
    }
    const { host, port } = parsedHostPort;

    if (!host) {
      return {
        valid: false,
        message: _('Invalid HTTP proxy URL: missing hostname or IP'),
      };
    }

    if (!port) {
      return {
        valid: false,
        message: _('Invalid HTTP proxy URL: missing port'),
      };
    }

    const portNum = Number(port);
    if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
      return {
        valid: false,
        message: _('Invalid HTTP proxy URL: invalid port number'),
      };
    }

    if (!isValidHost(host)) {
      return {
        valid: false,
        message: _('Invalid HTTP proxy URL: invalid host format'),
      };
    }
  } catch (_e) {
    return {
      valid: false,
      message: _('Invalid HTTP proxy URL: parsing failed'),
    };
  }

  return { valid: true, message: _('Valid') };
}
