import { describe, it, expect } from 'vitest';
import { cidrsOverlap, validateCidr, validateSubnet } from '../validateSubnet';

export const validSubnets = [
  ['Simple IP', '192.168.1.1'],
  ['With CIDR /24', '192.168.1.1/24'],
  ['CIDR /0', '10.0.0.1/0'],
  ['Zero network with CIDR', '0.0.0.0/3'],
  ['CIDR /32', '172.16.0.1/32'],
  ['Loopback', '127.0.0.1'],
  ['Broadcast with mask', '255.255.255.255/32'],
  ['IPv6 address', '2001:db8::1'],
  ['IPv6 CIDR /64', '2001:db8::/64'],
  ['IPv6 default route', '::/0'],
  ['IPv6 host /128', 'fc00::1/128'],
  ['MAC address colon', 'a8:8c:3e:c9:25:05'],
  ['MAC address hyphen', 'A8-8C-3E-C9-25-05'],
];

export const invalidSubnets = [
  ['Empty string', ''],
  ['Bad format letters', 'abc.def.ghi.jkl'],
  ['Octet too large', '300.1.1.1'],
  ['Negative octet', '-1.2.3.4'],
  ['Too many octets', '1.2.3.4.5'],
  ['Not enough octets', '192.168.1'],
  ['Leading zero octet', '01.2.3.4'],
  ['Invalid CIDR (too high)', '192.168.1.1/33'],
  ['Invalid CIDR (negative)', '192.168.1.1/-1'],
  ['CIDR not number', '192.168.1.1/abc'],
  ['Forbidden 0.0.0.0', '0.0.0.0'],
  ['Forbidden ::', '::'],
  ['Invalid IPv6 CIDR', '2001:db8::1/129'],
  ['Invalid IPv6 address', '2001:db8::zzzz/64'],
  ['Trailing slash IPv4', '192.168.1.0/'],
  ['Trailing slash IPv6', '2001:db8::/'],
];

describe('validateSubnet', () => {
  describe.each(validSubnets)('Valid subnet: %s', (_desc, subnet) => {
    it(`returns {valid:true} for "${subnet}"`, () => {
      const res = validateSubnet(subnet);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidSubnets)('Invalid subnet: %s', (_desc, subnet) => {
    it(`returns {valid:false} for "${subnet}"`, () => {
      const res = validateSubnet(subnet);
      expect(res.valid).toBe(false);
    });
  });

  it('validates strict CIDR families and rejects trailing slashes or bare IPs', () => {
    expect(validateCidr('198.18.0.0/15', 4).valid).toBe(true);
    expect(validateCidr('198.18.0.0', 4).valid).toBe(false);
    expect(validateCidr('fc00::/18', 4).valid).toBe(false);
    expect(validateCidr('fc00::/18', 6).valid).toBe(true);
    expect(validateCidr('fdfe:dcba:9876::1/126', 6).valid).toBe(true);
    expect(validateCidr('fc00::1', 6).valid).toBe(false);
    expect(validateCidr('fc00::/', 6).valid).toBe(false);
    expect(validateCidr('198.18.0.0/15', 6).valid).toBe(false);
  });

  it('detects overlapping IPv4 and IPv6 CIDR ranges accurately', () => {
    expect(cidrsOverlap('fc00::/18', 'fc00:1000::1/126')).toBe(true);
    expect(cidrsOverlap('fc00::/18', 'fdfe:dcba:9876::1/126')).toBe(false);
    expect(cidrsOverlap('198.18.0.0/15', '198.19.255.0/24')).toBe(true);
    expect(cidrsOverlap('198.18.0.0/15', '172.19.0.1/30')).toBe(false);
    expect(cidrsOverlap('198.18.0.0/15', 'fc00::/18')).toBe(false);
  });
});
