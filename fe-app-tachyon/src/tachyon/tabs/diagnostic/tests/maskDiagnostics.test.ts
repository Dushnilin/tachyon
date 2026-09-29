import { describe, expect, it } from 'vitest';
import {
  formatMaskedSingBoxConfig,
  maskGlobalCheckText,
  maskLogText,
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
    expect(masked).toContain("config interface 'lan'");
    expect(masked).toContain("config interface 'wan'");
    expect(masked).not.toContain('192.168.1.1');
    expect(masked).not.toContain('provider-password');
    expect(masked).toContain("option proxy_string '*******'");
    expect(masked).toContain("option ipaddr '*******'");
  });

  it('masks node and credential options the backend masker already covers', () => {
    const raw = [
      "config server 'node'",
      "\toption anytls_sni 'provider.example.com'",
      "\toption sni 'provider.example.com'",
      "\toption transport_path '/provider.example.com/path'",
      "\toption tls_certificate_path '/etc/tachyon/node.crt'",
      "\toption openvpn_ca '-----BEGIN CERTIFICATE-----'",
      "\toption openvpn_cert 'MIIBsecret'",
      "\toption openvpn_key 'MIIBkeysecret'",
      "\toption bot_token '123456:telegram-secret'",
      "\toption agent_api_token 'agent-secret'",
      "\toption warp_private_key 'warp-secret'",
      "\toption masque_access_token 'masque-secret'",
      '',
    ].join('\n');

    const masked = maskGlobalCheckText(raw);

    expect(masked).not.toContain('provider.example.com');
    expect(masked).not.toContain('MIIBsecret');
    expect(masked).not.toContain('telegram-secret');
    expect(masked).not.toContain('agent-secret');
    expect(masked).not.toContain('warp-secret');
    expect(masked).not.toContain('masque-secret');
  });

  it('redacts hosts and URLs from syslog lines while keeping paths and versions readable', () => {
    const raw = [
      'Mon Sep 28 23:47:07 2026 daemon.err sing-box[405]: [ERROR] dns: exchange failed for openwrt.org. IN A: use of closed network connection',
      'tachyon: [debug] Adding 78 elements to nft set tachyon_rule_MAIN_subnets',
      'outbound/vless[SP node] dial tcp l3.itxtech.surf:2083: i/o timeout',
      'subscription updated from https://s.fserv.digital/secret-token?hwid=abc',
      'tachyon: [info] sing-box 1.14.2-lx.8 started at 10:00:27',
      'reload /usr/lib/tachyon/service/watchdog.uc from /etc/sing-box/config.json',
      '',
    ].join('\n');

    const masked = maskLogText(raw);

    expect(masked).not.toContain('openwrt.org');
    expect(masked).not.toContain('l3.itxtech.surf');
    expect(masked).not.toContain('fserv.digital');
    expect(masked).not.toContain('secret-token');
    // The diagnostic value of the line must survive.
    expect(masked).toContain('dns: exchange failed for *******. IN A');
    expect(masked).toContain('dial tcp *******:2083: i/o timeout');
    expect(masked).toContain(
      'Adding 78 elements to nft set tachyon_rule_MAIN_subnets',
    );
    expect(masked).toContain('sing-box 1.14.2-lx.8 started at 10:00:27');
    expect(masked).toContain('daemon.err sing-box[405]');
    expect(masked).toContain('/usr/lib/tachyon/service/watchdog.uc');
    expect(masked).toContain('/etc/sing-box/config.json');
  });
});
