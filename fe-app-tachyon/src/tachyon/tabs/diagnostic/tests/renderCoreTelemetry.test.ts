/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.hoisted(() => {
  function createEl(tag: string) {
    const el: any = {
      tagName: tag.toUpperCase(),
      children: [] as any[],
      style: {} as Record<string, string>,
      textContent: '',
      _innerHTML: '',
      class: '',
      get innerHTML() {
        return this._innerHTML;
      },
      set innerHTML(val: string) {
        this._innerHTML = String(val ?? '');
      },
      setAttribute() {},
      getAttribute() {
        return null;
      },
      addEventListener() {},
      replaceChildren(...nodes: any[]) {
        (this as any).children = nodes;
      },
      appendChild(node: any) {
        if (node && typeof node === 'object') {
          (this as any).children.push(node);
        } else if (node !== undefined && node !== null) {
          (this as any).textContent += String(node);
        }
      },
      append(...nodes: any[]) {
        nodes.forEach((n) => (this as any).appendChild(n));
      },
    };
    return el;
  }

  (globalThis as any).document = {
    documentElement: { lang: 'en' },
    createElement: (tag: string) => createEl(tag),
    createElementNS: (_ns: string, tag: string) => createEl(tag),
    querySelector: () => null,
  };

  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = (globalThis as any).document.createElement(tag);
    if (attrs) {
      Object.assign(el, attrs);
    }
    if (children !== undefined && children !== null) {
      if (Array.isArray(children)) {
        children.forEach((c) => {
          if (c != null) el.appendChild(c);
        });
      } else {
        el.appendChild(children);
      }
    }
    return el;
  };

  (globalThis as any)._ = (str: string) => str;
});

import {
  formatTelemetryTagDisplay,
  renderCoreTelemetry,
  type ICoreTelemetrySnapshot,
} from '../partials/renderCoreTelemetry';

function collectAllText(node: any): string {
  if (!node || typeof node !== 'object') return String(node ?? '');
  let text = `${node.textContent || ''} ${node._innerHTML || ''}`;
  for (const child of node.children || []) {
    text += ' ' + collectAllText(child);
  }
  return text;
}

const SAMPLE_SNAPSHOT: ICoreTelemetrySnapshot = {
  success: true,
  traffic: {
    upload_bps: 1024,
    download_bps: 4096,
    upload_total: 102400,
    download_total: 512000,
    proxied_upload: 80000,
    proxied_download: 400000,
    direct_upload: 22400,
    direct_download: 112000,
    total_devices: 5,
    active_connections: 12,
    history: [
      [500, 1200],
      [900, 3100],
    ],
  },
  memory: {
    rss_bytes: 24 * 1024 * 1024,
    vm_bytes: 48 * 1024 * 1024,
    system_available_bytes: 256 * 1024 * 1024,
    total_ram_mb: 512,
    pressure_level: 'normal',
    under_pressure: false,
    connections: { device_buckets: 4 },
    dns: { cache_entries: 42, reverse_entries: 18, fakeip_entries: 9 },
  },
  protocols: { tcp: 9, udp: 2, quic: 1 },
  outbounds: [
    {
      tag: 'sel-Main',
      active_connections: 5,
      upload: 2048,
      download: 8192,
      recent_hits: 7,
    },
  ],
  failover: {
    any_on_backup: true,
    groups: [
      {
        tag: 'bal-Main-auto',
        type: 'failover',
        primary: 'node-1',
        current: 'node-2',
        on_backup: true,
        primary_healthy: false,
        primary_rtt_ms: 85,
      },
    ],
  },
  leak: {
    ipv4: { outbound: 'sel-Main' },
    ipv6: { leak_risk: false },
    webrtc_stun: { leak_risk: false, is_direct: false, outbound: 'sel-Main' },
    dns: { engine_enabled: true },
  },
  flight: {
    count: 1,
    entries: [
      {
        network: 'tcp',
        host: 'example.com',
        outbound: 'sel-Main',
        upload: 100,
        download: 400,
        duration_ms: 12,
        status: 'ok',
      },
    ],
  },
};

describe('renderCoreTelemetry localization', () => {
  beforeEach(() => {
    (globalThis as any).document.documentElement.lang = 'en';
  });

  it('contains no Cyrillic text in English mode for populated and empty snapshots', () => {
    const populatedText = collectAllText(renderCoreTelemetry(SAMPLE_SNAPSHOT));
    expect(populatedText).toContain('Throughput & Traffic Split');
    expect(populatedText).toContain('Leak Guard & Flight Recorder');
    expect(populatedText).toContain('Scale peak:');
    expect(/[А-Яа-яЁё]/.test(populatedText)).toBe(false);

    const emptyText = collectAllText(renderCoreTelemetry({}));
    expect(emptyText).toContain('No outbound statistics collected yet');
    expect(emptyText).toContain('No balancer groups configured');
    expect(emptyText).toContain('Flight recorder log is empty');
    expect(/[А-Яа-яЁё]/.test(emptyText)).toBe(false);
  });

  it('renders Russian titles when html lang is ru', () => {
    (globalThis as any).document.documentElement.lang = 'ru';
    const ruText = collectAllText(renderCoreTelemetry(SAMPLE_SNAPSHOT));
    expect(ruText).toContain('Пропускная способность и баланс трафика');
    expect(ruText).toContain('Защита контура и Бортовой самописец');
  });

  it('displays human-readable route and balancer names while keeping raw tags in title', () => {
    const findByClass = (node: any, className: string): any => {
      if (!node || typeof node !== 'object') return undefined;
      if (node.class === className) return node;
      for (const child of node.children || []) {
        const hit = findByClass(child, className);
        if (hit) return hit;
      }
      return undefined;
    };

    const rendered = renderCoreTelemetry({
      outbounds: [
        {
          tag: 'iface-src_iface_awg_de',
          display_name: 'AWG Germany',
          active_connections: 3,
          upload: 100,
          download: 500,
        },
      ],
      failover: {
        groups: [
          {
            tag: 'bal-vpn-bal_vpn_Fast',
            display_name: 'Fast',
            current: '🇫🇮 RU | FL | Helsinki',
            current_display_name: '🇫🇮 RU | FL | Helsinki',
            on_backup: true,
            primary_healthy: true,
            primary_rtt_ms: 82,
          },
          {
            tag: 'sel-vpn',
            display_name: 'VPN',
            current: 'bal-vpn-bal_vpn_Fast',
            current_display_name: 'Fast',
          },
        ],
      },
      flight: {
        count: 1,
        entries: [
          {
            network: 'tcp',
            host: 'instagram.com',
            outbound: 'sel-meta',
            outbound_display_name: 'Meta',
            upload: 50,
            download: 200,
            duration_ms: 15,
            status: 'ok',
          },
        ],
      },
    });

    expect(
      findByClass(rendered, 'tachyon_diag-telemetry__outbound-tag'),
    ).toMatchObject({
      textContent: 'AWG Germany',
      title: 'iface-src_iface_awg_de',
    });
    expect(
      findByClass(rendered, 'tachyon_diag-telemetry__failover-tag'),
    ).toMatchObject({
      textContent: 'Fast',
      title: 'bal-vpn-bal_vpn_Fast',
    });
    expect(
      findByClass(rendered, 'tachyon_diag-telemetry__failover-node'),
    ).toMatchObject({
      textContent: '→ 🇫🇮 RU | FL | Helsinki',
      title: '🇫🇮 RU | FL | Helsinki',
    });
    expect(
      findByClass(rendered, 'tachyon_diag-telemetry__flight-out'),
    ).toMatchObject({
      textContent: 'Meta',
      title: 'sel-meta',
    });

    // Client-side fallback when backend display_name is absent
    expect(formatTelemetryTagDisplay('bal-vpn-bal_vpn_Fast')).toBe('Fast');
    expect(formatTelemetryTagDisplay('bal-my-vpn-bal_my-vpn_Reserve')).toBe(
      'Reserve',
    );
    expect(formatTelemetryTagDisplay('sel-Main')).toBe('Main');
    expect(formatTelemetryTagDisplay('desync-sec-youtube')).toBe('youtube');
    expect(formatTelemetryTagDisplay('tailscale-sec-home')).toBe('home');
  });
});
