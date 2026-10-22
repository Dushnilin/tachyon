import { describe, it, expect } from 'vitest';
import {
  isServiceGroup,
  getGroupActiveRoute,
  getAllActiveRoutes,
  getActiveRoute,
} from '../activeRoute';
import { Tachyon } from '../../../types';

describe('activeRoute helpers', () => {
  it('correctly identifies service groups', () => {
    const serviceGroup = {
      action: 'zapret',
      outbounds: [],
    } as unknown as Tachyon.OutboundGroup;
    expect(isServiceGroup(serviceGroup)).toBe(true);

    const proxyGroup = {
      sectionName: 'main',
      outbounds: [
        {
          displayName: 'US Server',
          type: 'VLESS',
          selected: true,
          latency: 45,
        },
      ],
    } as unknown as Tachyon.OutboundGroup;
    expect(isServiceGroup(proxyGroup)).toBe(false);
  });

  it('extracts active route for manual selection', () => {
    const group = {
      sectionName: 'main',
      displayName: 'Main Routing',
      outbounds: [
        {
          displayName: 'Germany 1',
          type: 'Shadowsocks',
          selected: true,
          latency: 32,
        },
      ],
    } as unknown as Tachyon.OutboundGroup;
    const route = getGroupActiveRoute(group);
    expect(route).not.toBeNull();
    expect(route?.sectionName).toBe('main');
    expect(route?.name).toBe('Germany 1');
    expect(route?.type).toBe('Shadowsocks');
    expect(route?.latency).toBe(32);
    expect(route?.selector).toBe('Manual selection');
  });

  it('extracts active route for priority and urltest selectors', () => {
    const priorityGroup = {
      sectionName: 'streaming',
      displayName: 'Streaming',
      outbounds: [
        {
          displayName: 'Auto Priority',
          type: 'Selector',
          selected: true,
          priorityInfo: {
            selectedName: 'NL Server',
            outbounds: [
              {
                displayName: 'NL Server',
                type: 'VLESS',
                latency: 28,
                selected: true,
              },
            ],
          },
        },
      ],
    } as unknown as Tachyon.OutboundGroup;
    const prioRoute = getGroupActiveRoute(priorityGroup);
    expect(prioRoute?.name).toBe('NL Server');
    expect(prioRoute?.selector).toBe('Auto Priority (Priority)');
    expect(prioRoute?.latency).toBe(28);
    expect(prioRoute?.type).toBe('VLESS');

    const urlTestGroup = {
      sectionName: 'games',
      displayName: 'Games',
      outbounds: [
        {
          displayName: 'Fastest',
          type: 'Selector',
          selected: true,
          urlTestInfo: {
            selectedName: 'FI Server',
            outbounds: [
              {
                displayName: 'FI Server',
                type: 'Hysteria2',
                latency: 18,
                selected: true,
              },
            ],
          },
        },
      ],
    } as unknown as Tachyon.OutboundGroup;
    const urlTestRoute = getGroupActiveRoute(urlTestGroup);
    expect(urlTestRoute?.name).toBe('FI Server');
    expect(urlTestRoute?.selector).toBe('Fastest (URLTest)');
    expect(urlTestRoute?.latency).toBe(18);
    expect(urlTestRoute?.type).toBe('Hysteria2');
  });

  it('getAllActiveRoutes returns all non-service proxy section routes', () => {
    const groups = [
      {
        sectionName: 'main',
        outbounds: [
          {
            displayName: 'US Server',
            type: 'VLESS',
            selected: true,
            latency: 45,
          },
        ],
      },
      {
        action: 'zapret',
        outbounds: [],
      },
      {
        sectionName: 'streaming',
        displayName: 'Streaming Section',
        outbounds: [
          {
            displayName: 'UK Server',
            type: 'Trojan',
            selected: true,
            latency: 55,
          },
        ],
      },
    ] as unknown as Tachyon.OutboundGroup[];

    const all = getAllActiveRoutes(groups);
    expect(all).toHaveLength(2);
    expect(all[0].name).toBe('US Server');
    expect(all[1].name).toBe('UK Server');

    const main = getActiveRoute(groups);
    expect(main?.name).toBe('US Server');
  });
});
