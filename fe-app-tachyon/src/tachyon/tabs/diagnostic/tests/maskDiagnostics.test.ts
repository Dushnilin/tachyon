import { describe, expect, it } from 'vitest';
import {
  formatMaskedSingBoxConfig,
  maskGlobalCheckText,
  maskSingBoxConfigValue,
} from '../helpers/maskDiagnostics';

describe('diagnostic masking', () => {
  it('masks sensitive sing-box keys without mutating the original config', () => {
    const config = {
      outbounds: [
        {
          type: 'vless',
          tag: 'proxy',
          server: '1.2.3.4',
          server_port: 443,
          uuid: '12345678-1234-1234-1234-123456789012',
          tls: {
            enabled: true,
            server_name: 'test.com',
          },
        },
      ],
      route: {
        rules: [
          {
            domain_suffix: ['test.com'],
            outbound: 'proxy',
          },
        ],
      },
    };

    expect(maskSingBoxConfigValue(config)).toEqual({
      outbounds: [
        {
          type: 'vless',
          tag: 'proxy',
          server: '*******',
          server_port: '*******',
          uuid: '*******',
          tls: {
            enabled: true,
            server_name: '*******',
          },
        },
      ],
      route: {
        rules: [
          {
            domain_suffix: '*******',
            outbound: 'proxy',
          },
        ],
      },
    });
    expect(config.outbounds[0].server).toBe('1.2.3.4');
  });

  it('formats masked sing-box config from a raw JSON string', () => {
    const masked = formatMaskedSingBoxConfig(
      `{
        "inbounds": [
          {
            "listen": "127.0.0.1",
            "listen_port": 2080
          }
        ]
      }`,
    );

    expect(masked).toContain('"listen": "*******"');
    expect(masked).toContain('"listen_port": "*******"');
  });

  it('masks sensitive global check UCI values while keeping visible structure stable', () => {
    const raw = [
      "config section 'main'",
      "\toption proxy_string 'vless://secret@example.com:443'",
      "\toption hwid 'device-secret'",
      "\tlist domain 'example.com'",
      "\toption outbound_json '{",
      '  "server": "example.com",',
      "}'",
      "config interface 'lan'",
      "\toption ipaddr '192.168.1.1'",
      "\toption netmask '255.255.255.0'",
      "config interface 'wan'",
      "\toption username 'provider-user'",
      "\toption password 'provider-password'",
      '',
    ].join('\n');

    const masked = maskGlobalCheckText(raw);

    expect(masked.split('\n')).toHaveLength(raw.split('\n').length);
    expect(masked).not.toContain('vless://secret');
    expect(masked).toContain('config interface \'lan\'');
    expect(masked).toContain('config interface \'wan\'');
    expect(masked).not.toContain('192.168.1.1');
    expect(masked).not.toContain('provider-password');
    expect(masked).toContain("option proxy_string '*******'");
    expect(masked).toContain("option ipaddr '*******'");
  });
});
