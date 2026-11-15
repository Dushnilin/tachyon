/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import {
  formatOutboundType,
  parseNodeProtocolBreakdown,
  renderProtocolPopoverNodes,
} from '../formatOutboundType';

describe('formatOutboundType', () => {
  let originalE: any;

  beforeEach(() => {
    originalE = (globalThis as any).E;
    (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
      const classList = new Set<string>();
      if (attrs?.class) {
        attrs.class
          .split(' ')
          .filter(Boolean)
          .forEach((c: string) => classList.add(c));
      }
      return {
        tag,
        attrs,
        children,
        classList: {
          contains: (cls: string) => classList.has(cls),
        },
      };
    };
  });

  afterEach(() => {
    (globalThis as any).E = originalE;
  });
  it('formats protocol with transport in uppercase parentheses', () => {
    expect(formatOutboundType('VLESS', 'xhttp')).toBe('VLESS (XHTTP)');
    expect(formatOutboundType('vless', 'tcp')).toBe('vless (TCP)');
    expect(formatOutboundType('VMess', 'ws')).toBe('VMess (WS)');
    expect(formatOutboundType('Trojan', 'grpc')).toBe('Trojan (GRPC)');
  });

  it('leaves protocol untouched if transport is not provided', () => {
    expect(formatOutboundType('VLESS')).toBe('VLESS');
    expect(formatOutboundType('Direct')).toBe('Direct');
    expect(formatOutboundType(undefined)).toBe('');
  });

  it('handles group types without adding transport', () => {
    expect(formatOutboundType('Priority (Авто)', 'tcp')).toBe(
      'Priority (Авто) (TCP)',
    );
    expect(formatOutboundType('URLTest (Авто)')).toBe('URLTest (Авто)');
  });

  it('infers implicit UDP/QUIC transport for Hysteria2 and Tuic in parseNodeProtocolBreakdown', () => {
    const { rows: h2Rows } = parseNodeProtocolBreakdown('hysteria2');
    expect(h2Rows).toEqual([
      { label: 'Protocol', value: 'HYSTERIA2' },
      { label: 'Transport', value: 'UDP / QUIC' },
    ]);

    const { rows: tuicRows } = parseNodeProtocolBreakdown('tuic');
    expect(tuicRows).toEqual([
      { label: 'Protocol', value: 'TUIC' },
      { label: 'Transport', value: 'UDP / QUIC' },
    ]);

    const { rows: awgRows } = parseNodeProtocolBreakdown('awg');
    expect(awgRows).toEqual([
      { label: 'Protocol', value: 'AWG' },
      { label: 'Transport', value: 'UDP' },
    ]);
  });

  it('renders popover element for Hysteria2 instead of returning null', () => {
    const popover = renderProtocolPopoverNodes('hysteria2');
    expect(popover).not.toBeNull();
    expect(popover?.classList.contains('tachyon_proto-popover')).toBe(true);

    const empty = renderProtocolPopoverNodes(undefined, undefined, undefined);
    expect(empty).toBeNull();
  });

  it('parses plus-separated details including security, sni, utls, and cert_sha256 pinning', () => {
    const { rows } = parseNodeProtocolBreakdown(
      'VLESS',
      'tcp',
      'reality+xtls-rprx-vision+sni:www.microsoft.com+utls:chrome+cert_sha256',
    );
    expect(rows).toEqual([
      { label: 'Protocol', value: 'VLESS' },
      { label: 'Security', value: 'REALITY' },
      { label: 'Flow', value: 'xtls-rprx-vision' },
      { label: 'SNI / Host', value: 'www.microsoft.com' },
      { label: 'uTLS Fingerprint', value: 'chrome' },
      { label: 'Pinning', value: 'SHA-256' },
      { label: 'Transport', value: 'TCP' },
    ]);
  });
});
