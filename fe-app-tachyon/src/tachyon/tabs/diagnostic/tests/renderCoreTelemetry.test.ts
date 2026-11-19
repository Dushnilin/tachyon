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
  renderCoreTelemetry,
  type ICoreTelemetrySnapshot,
} from '../partials/renderCoreTelemetry';
import { buildCoreTelemetryRouteLabels } from '../helpers/coreTelemetryRouteLabels';

function collectAllText(node: any): string {
  if (!node || typeof node !== 'object') return String(node ?? '');
  let text = `${node.textContent || ''} ${node._innerHTML || ''}`;
  for (const child of node.children || []) {
    text += ' ' + collectAllText(child);
  }
  return text;
}

function findByClass(node: any, className: string): any {
  if (node.class === className) return node;
  for (const child of node.children || []) {
    const match = findByClass(child, className);
    if (match) return match;
  }
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
});

it('uses configured labels and retains tags in tooltips across telemetry', () => {
  const labels = buildCoreTelemetryRouteLabels([
    {
      '.name': 'main',
      '.type': 'section',
      label: 'Main VPN',
      balancer_refs: ['bal_main_auto'],
    },
    { '.name': 'bal_main_auto', '.type': 'balancer', name: 'Auto' },
    {
      '.name': 'video',
      '.type': 'section',
      label: 'Video',
      outbound_source_refs: ['src_dpi'],
    },
    { '.name': 'src_dpi', '.type': 'outbound_source', source_type: 'desync' },
    {
      '.name': 'src_router',
      '.type': 'outbound_source',
      source_type: 'custom_json',
      name: 'Remote Router',
      custom_json: '{"type":"wireguard","tag":"custom-wg-leaf"}',
    },
  ]);
  const rendered = renderCoreTelemetry(
    {
      outbounds: [{ tag: 'custom-wg-leaf' }],
      failover: {
        groups: [{ tag: 'sel-main', current: 'bal-main-bal_main_auto' }],
      },
      flight: { entries: [{ outbound: 'desync-src_dpi' }] },
    },
    {},
    labels,
  );
  for (const [suffix, textContent, title] of [
    ['outbound-tag', 'Remote Router', 'custom-wg-leaf'],
    ['failover-tag', 'Main VPN', 'sel-main'],
    ['failover-node', '→ Auto', 'bal-main-bal_main_auto'],
    ['flight-out', 'Video', 'desync-src_dpi'],
  ]) {
    expect(
      findByClass(rendered, `tachyon_diag-telemetry__${suffix}`),
    ).toMatchObject({
      textContent,
      title,
    });
  }
  expect(
    findByClass(
      renderCoreTelemetry(SAMPLE_SNAPSHOT),
      'tachyon_diag-telemetry__flight-out',
    ),
  ).toMatchObject({ textContent: 'sel-Main', title: 'sel-Main' });
});
