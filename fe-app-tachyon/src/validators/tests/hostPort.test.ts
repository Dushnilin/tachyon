import { describe, it, expect } from 'vitest';
import {
  formatHostForUri,
  parseHostPort,
  splitHostPort,
  unbracketHost,
} from '../hostPort';
import { isIPv6WithZone, validateIPWithZone } from '../validateIp';

describe('hostPort IPv6 helpers', () => {
  it('wraps IPv6 literals in brackets without double-wrapping', () => {
    expect(formatHostForUri('2001:db8::1')).toBe('[2001:db8::1]');
    expect(formatHostForUri('[2001:db8::1]')).toBe('[2001:db8::1]');
    expect(formatHostForUri('  ::1  ')).toBe('[::1]');
    expect(formatHostForUri('192.0.2.1')).toBe('192.0.2.1');
    expect(formatHostForUri('vpn.example.com')).toBe('vpn.example.com');
  });

  it('splits optional and required host:port with IPv6 support', () => {
    expect(splitHostPort('[2001:db8::1]:51820')).toEqual({
      host: '2001:db8::1',
      port: '51820',
    });
    expect(splitHostPort('[2001:db8::1]')).toEqual({
      host: '2001:db8::1',
    });
    expect(splitHostPort('2001:db8::1')).toEqual({
      host: '2001:db8::1',
    });
    expect(splitHostPort('example.com:443')).toEqual({
      host: 'example.com',
      port: '443',
    });
    expect(splitHostPort('example.com')).toEqual({
      host: 'example.com',
    });
    expect(splitHostPort('[2001:db8::1]:')).toBeNull();
    expect(splitHostPort('[not-valid-ipv6]:51820')).toBeNull();
  });

  it('keeps strict host:port behavior in parseHostPort and unbracketHost', () => {
    expect(parseHostPort('[2001:db8::1]:443')).toEqual({
      host: '2001:db8::1',
      port: '443',
    });
    expect(parseHostPort('2001:db8::1:443')).toBeNull();
    expect(unbracketHost('[::1]')).toBe('::1');
  });
});

describe('validateIPWithZone', () => {
  it('accepts IPv6 link-local addresses with interface zones and rejects malformed ones', () => {
    expect(isIPv6WithZone('fe80::1%eth0')).toBe(true);
    expect(isIPv6WithZone('fe80::1%br-lan')).toBe(true);
    expect(isIPv6WithZone('2001:db8::1')).toBe(true);
    expect(validateIPWithZone('fe80::1%eth0').valid).toBe(true);
    expect(validateIPWithZone('192.0.2.1').valid).toBe(true);
    expect(isIPv6WithZone('fe80::1%')).toBe(false);
    expect(isIPv6WithZone('fe80::1%eth 0')).toBe(false);
    expect(validateIPWithZone('not-an-ip').valid).toBe(false);
  });
});
