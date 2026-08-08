import { ValidationResult } from './types';
import { parseQueryString } from '../helpers/parseQueryString';
import { isValidPort, parseHostPort } from './hostPort';

function isValidUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
    value,
  );
}

export function validateTuicUrl(url: string): ValidationResult {
  try {
    if (!url.startsWith('tuic://')) {
      return {
        valid: false,
        message: _('Invalid TUIC URL: must start with tuic://'),
      };
    }

    if (/\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid TUIC URL: must not contain spaces'),
      };
    }

    const body = url.slice('tuic://'.length);

    const [mainPart] = body.split('#');
    const [authHostPort, queryString] = mainPart.split('?');

    if (!authHostPort)
      return {
        valid: false,
        message: _('Invalid TUIC URL: missing credentials/server'),
      };

    const [uuidPasswordPart, hostPortPart] = authHostPort.split('@');

    if (!uuidPasswordPart)
      return {
        valid: false,
        message: _('Invalid TUIC URL: missing UUID'),
      };

    if (!hostPortPart)
      return {
        valid: false,
        message: _('Invalid TUIC URL: missing host & port'),
      };

    const [uuidPart, passwordPart] = uuidPasswordPart.split(':');
    const uuid = uuidPart || '';
    const _password = passwordPart || '';

    if (!uuid) {
      return { valid: false, message: _('Invalid TUIC URL: missing UUID') };
    }

    if (!isValidUuid(uuid)) {
      return {
        valid: false,
        message: _('Invalid TUIC URL: UUID must be a valid UUID v4 format'),
      };
    }

    const parsedHostPort = parseHostPort(hostPortPart);
    if (!parsedHostPort) {
      return {
        valid: false,
        message: _('Invalid TUIC URL: invalid host & port'),
      };
    }
    const { host, port } = parsedHostPort;

    if (!host) {
      return { valid: false, message: _('Invalid TUIC URL: missing host') };
    }

    if (!port) {
      return { valid: false, message: _('Invalid TUIC URL: missing port') };
    }

    const cleanedPort = port.replace('/', '');
    if (!isValidPort(cleanedPort)) {
      return {
        valid: false,
        message: _('Invalid TUIC URL: invalid port number'),
      };
    }

    if (queryString) {
      const params = parseQueryString(queryString);
      const paramsKeys = Object.keys(params);

      const validCc = ['bbr', 'cubic', 'new_reno'];
      if (
        paramsKeys.includes('congestion_control') &&
        !validCc.includes(params.congestion_control)
      ) {
        return {
          valid: false,
          message: _(
            'Invalid TUIC URL: congestion_control must be bbr, cubic, or new_reno',
          ),
        };
      }

      const validUdpMode = ['native', 'quic', 'qux'];
      if (
        paramsKeys.includes('udp_relay_mode') &&
        !validUdpMode.includes(params.udp_relay_mode)
      ) {
        return {
          valid: false,
          message: _(
            'Invalid TUIC URL: udp_relay_mode must be native, quic, or qux',
          ),
        };
      }

      if (
        paramsKeys.includes('insecure') &&
        !['0', '1'].includes(params.insecure)
      ) {
        return {
          valid: false,
          message: _('Invalid TUIC URL: insecure must be 0 or 1'),
        };
      }

      if (
        paramsKeys.includes('zero_rtt_handshake') &&
        !['0', '1', 'true', 'false'].includes(params.zero_rtt_handshake)
      ) {
        return {
          valid: false,
          message: _(
            'Invalid TUIC URL: zero_rtt_handshake must be 0, 1, true, or false',
          ),
        };
      }

      if (paramsKeys.includes('sni') && !params.sni) {
        return {
          valid: false,
          message: _('Invalid TUIC URL: sni cannot be empty'),
        };
      }
    }

    return { valid: true, message: _('Valid') };
  } catch (_e) {
    return { valid: false, message: _('Invalid TUIC URL: parsing failed') };
  }
}
