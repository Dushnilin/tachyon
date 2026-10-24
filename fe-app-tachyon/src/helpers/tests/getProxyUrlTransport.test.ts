import { describe, expect, it } from 'vitest';
import { getProxyUrlTransport } from '../getProxyUrlTransport';

describe('getProxyUrlTransport', () => {
  it('extracts transport from vless query parameters', () => {
    expect(
      getProxyUrlTransport(
        'vless://uuid@example.com:443?security=reality&type=xhttp#Server',
      ),
    ).toBe('xhttp');
    expect(
      getProxyUrlTransport(
        'vless://uuid@example.com:443?security=tls&type=ws&path=/ws#Server',
      ),
    ).toBe('ws');
    expect(
      getProxyUrlTransport(
        'vless://uuid@example.com:443?security=tls&type=grpc#Server',
      ),
    ).toBe('grpc');
    expect(
      getProxyUrlTransport(
        'vless://uuid@example.com:443?security=none&type=tcp#Server',
      ),
    ).toBe('tcp');
  });

  it('extracts transport from vmess base64 net field', () => {
    // base64 of {"v":"2","ps":"test","add":"1.1.1.1","port":"443","id":"...","net":"ws"}
    const vmessWs =
      'vmess://' +
      btoa(
        JSON.stringify({
          v: '2',
          ps: 'test',
          add: '1.1.1.1',
          port: '443',
          id: 'uuid',
          net: 'ws',
        }),
      );
    expect(getProxyUrlTransport(vmessWs)).toBe('ws');

    const vmessTcp =
      'vmess://' +
      btoa(
        JSON.stringify({
          v: '2',
          ps: 'test',
          add: '1.1.1.1',
          port: '443',
          id: 'uuid',
          net: 'tcp',
        }),
      );
    expect(getProxyUrlTransport(vmessTcp)).toBe('tcp');
  });

  it('returns undefined for invalid or empty links', () => {
    expect(getProxyUrlTransport('')).toBeUndefined();
    expect(getProxyUrlTransport(undefined)).toBeUndefined();
    expect(getProxyUrlTransport('invalid-link')).toBeUndefined();
  });

  it('extracts first transport from tewfai transport query parameter', () => {
    expect(
      getProxyUrlTransport(
        'tewfai://uuid:pass@example.com:8443?transport=quic%2Ctcp#TewFai',
      ),
    ).toBe('quic');
  });
});
