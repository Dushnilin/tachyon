import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  checkInbounds: vi.fn(),
  updateCheckStore: vi.fn(),
}));

vi.mock('../../../../methods', () => ({
  TachyonShellMethods: {
    checkInbounds: mocks.checkInbounds,
  },
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

import { runInboundsCheck } from '../runInboundsCheck';

describe('runInboundsCheck', () => {
  beforeEach(() => {
    mocks.checkInbounds.mockReset();
    mocks.updateCheckStore.mockReset();
  });

  it('marks check as success for Tailscale inbound behind private WAN IP', async () => {
    mocks.checkInbounds.mockResolvedValue({
      success: true,
      data: {
        enabled_count: 1,
        config_path: '/etc/sing-box/config.json',
        wan_ip: '192.168.1.60',
        wan_public: 0,
        requires_public_wan: 0,
        items: [
          {
            section: 'Head',
            label: 'Head',
            protocol: 'tailscale',
            routing_mode: 'rules',
            tag: 'server-Head-in',
            listen: '0.0.0.0',
            listen_port: 0,
            public_host: '',
            public_host_ips: '',
            expected_type: 'tailscale',
            required_proto: 'tcp',
            runtime_exists: 1,
            runtime_type: 'tailscale',
            runtime_listen: '',
            runtime_port: 0,
            runtime_ok: 1,
            listening: -1,
            firewall_required: 0,
            firewall_open: -1,
            port_conflict: 0,
            port_conflict_owners: '',
            routes_configured: 1,
            public_host_resolved: -1,
            public_host_public: -1,
            public_host_matches_wan: -1,
          },
        ],
      },
    });

    await runInboundsCheck();

    const calls = mocks.updateCheckStore.mock.calls;
    const lastCall = calls[calls.length - 1]?.[0];
    expect(lastCall).toBeDefined();
    expect(lastCall.state).toBe('success');
    expect(lastCall.items[0].state).toBe('success');
    expect(lastCall.items[0].value).toContain('192.168.1.60');
    expect(lastCall.items[0].value).toContain(
      'Tailscale does not require public WAN',
    );
  });

  it('marks check as warning when public inbound has private WAN IP', async () => {
    mocks.checkInbounds.mockResolvedValue({
      success: true,
      data: {
        enabled_count: 1,
        config_path: '/etc/sing-box/config.json',
        wan_ip: '192.168.1.60',
        wan_public: 0,
        requires_public_wan: 1,
        items: [
          {
            section: 'vless_srv',
            label: 'Vless',
            protocol: 'vless',
            routing_mode: 'rules',
            tag: 'server-vless-in',
            listen: '0.0.0.0',
            listen_port: 443,
            public_host: '',
            public_host_ips: '',
            expected_type: 'vless',
            required_proto: 'tcp',
            runtime_exists: 1,
            runtime_type: 'vless',
            runtime_listen: '0.0.0.0',
            runtime_port: 443,
            runtime_ok: 1,
            listening: 1,
            firewall_required: 1,
            firewall_open: 1,
            port_conflict: 0,
            port_conflict_owners: '',
            routes_configured: 1,
            public_host_resolved: -1,
            public_host_public: -1,
            public_host_matches_wan: -1,
          },
        ],
      },
    });

    await runInboundsCheck();

    const calls = mocks.updateCheckStore.mock.calls;
    const lastCall = calls[calls.length - 1]?.[0];
    expect(lastCall).toBeDefined();
    expect(lastCall.state).toBe('warning');
    expect(lastCall.items[0].state).toBe('warning');
    expect(lastCall.items[0].value).toBe('192.168.1.60');
  });

  it('skips check when no inbounds are enabled', async () => {
    mocks.checkInbounds.mockResolvedValue({
      success: true,
      data: {
        enabled_count: 0,
        config_path: '/etc/sing-box/config.json',
        wan_ip: '192.168.1.60',
        wan_public: 0,
        requires_public_wan: 0,
        items: [],
      },
    });

    await runInboundsCheck();

    const calls = mocks.updateCheckStore.mock.calls;
    const lastCall = calls[calls.length - 1]?.[0];
    expect(lastCall).toBeDefined();
    expect(lastCall.state).toBe('skipped');
  });
});
