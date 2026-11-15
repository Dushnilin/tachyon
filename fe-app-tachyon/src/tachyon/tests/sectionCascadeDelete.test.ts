/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable no-empty */
import { describe, it, expect, vi, beforeEach } from 'vitest';

describe('cascadeDeleteSection logic', () => {
  let uciState: Record<string, any[]>;
  let mockUci: any;
  let mockFs: any;
  let removedFiles: string[];

  beforeEach(() => {
    removedFiles = [];
    uciState = {
      section: [
        { '.name': 'sec1', '.type': 'section', label: 'Section 1' },
        {
          '.name': 'sec2',
          '.type': 'section',
          label: 'Section 2',
          outbound_detour_section: 'sec1',
          outbound_detour_enabled: '1',
          dns_detour_section: 'sec1',
          dns_detour_enabled: '1',
        },
      ],
      priority_group: [
        { '.name': 'pg1', '.type': 'priority_group', section: 'sec1' },
        { '.name': 'pg2', '.type': 'priority_group', section: 'sec2' },
      ],
      priority_level: [
        { '.name': 'pl1', '.type': 'priority_level', group: 'pg1' },
        { '.name': 'pl2', '.type': 'priority_level', section: 'sec1' },
        { '.name': 'pl3', '.type': 'priority_level', group: 'pg2' },
      ],
      subscription_url: [
        {
          '.name': 'sub1',
          '.type': 'subscription_url',
          section: 'sec1',
          url: 'https://example.com/1',
        },
        {
          '.name': 'sub2',
          '.type': 'subscription_url',
          section: 'sec2',
          url: 'https://example.com/2',
        },
      ],
      section_interface: [
        {
          '.name': 'if1',
          '.type': 'section_interface',
          section: 'sec1',
          interface: 'wg0',
        },
      ],
      urltest: [
        { '.name': 'ut1', '.type': 'urltest', section: 'sec1', interval: '3m' },
      ],
      settings: [
        {
          '.name': 'settings',
          '.type': 'settings',
          smart_detect_sections: ['sec1', 'sec2'],
          dns_detour_section: 'sec1',
          download_lists_via_proxy_section: 'sec1',
          download_components_via_proxy_section: 'sec1',
          warp_proxy_section: 'sec1',
        },
      ],
      server: [
        {
          '.name': 'srv1',
          '.type': 'server',
          routing_section: 'sec1',
          routing_mode: 'section',
        },
        {
          '.name': 'srv2',
          '.type': 'server',
          routing_section: 'sec2',
          routing_mode: 'section',
        },
      ],
    };

    mockUci = {
      sections: vi.fn((pkg: string, typeName: string) => {
        return uciState[typeName] || [];
      }),
      get: vi.fn((pkg: string, sid: string, opt?: string) => {
        for (const typeName in uciState) {
          const found = uciState[typeName].find((s) => s['.name'] === sid);
          if (found) {
            return opt ? found[opt] : found;
          }
        }
        return null;
      }),
      set: vi.fn((pkg: string, sid: string, opt: string, val: any) => {
        for (const typeName in uciState) {
          const found = uciState[typeName].find((s) => s['.name'] === sid);
          if (found) {
            found[opt] = val;
            return;
          }
        }
      }),
      remove: vi.fn((pkg: string, sid: string) => {
        for (const typeName in uciState) {
          uciState[typeName] = uciState[typeName].filter(
            (s) => s['.name'] !== sid,
          );
        }
      }),
    };

    mockFs = {
      remove: vi.fn(async (filePath: string) => {
        removedFiles.push(filePath);
      }),
      exec: vi.fn(async (_cmd: string, args: string[]) => {
        if (args && args.length > 1) {
          removedFiles.push(...args.slice(1));
        }
      }),
    };
  });

  function cascadeDelete(section_id: string, UCI_PACKAGE = 'tachyon') {
    if (!section_id) return;

    // 1. Remove child sections: priority_group, priority_level, subscription_url, section_interface, urltest
    try {
      const priorityGroups = (
        mockUci.sections(UCI_PACKAGE, 'priority_group') || []
      ).filter((item: any) => item.section === section_id);

      priorityGroups.forEach((group: any) => {
        const groupId = group['.name'];
        (mockUci.sections(UCI_PACKAGE, 'priority_level') || [])
          .filter(
            (level: any) =>
              level.group === groupId || level.section === section_id,
          )
          .forEach((level: any) => {
            mockUci.remove(UCI_PACKAGE, level['.name']);
          });
        mockUci.remove(UCI_PACKAGE, groupId);
      });

      (mockUci.sections(UCI_PACKAGE, 'priority_level') || [])
        .filter((level: any) => level.section === section_id)
        .forEach((level: any) => {
          mockUci.remove(UCI_PACKAGE, level['.name']);
        });

      ['subscription_url', 'section_interface', 'urltest'].forEach(
        (typeName) => {
          (mockUci.sections(UCI_PACKAGE, typeName) || [])
            .filter((item: any) => item.section === section_id)
            .forEach((item: any) => {
              mockUci.remove(UCI_PACKAGE, item['.name']);
            });
        },
      );
    } catch (_e) {}

    // 2. Clean references in settings
    try {
      const smartDetect = mockUci.get(
        UCI_PACKAGE,
        'settings',
        'smart_detect_sections',
      );
      if (Array.isArray(smartDetect)) {
        const filtered = smartDetect.filter((sec) => sec !== section_id);
        if (filtered.length !== smartDetect.length) {
          mockUci.set(
            UCI_PACKAGE,
            'settings',
            'smart_detect_sections',
            filtered,
          );
        }
      } else if (
        typeof smartDetect === 'string' &&
        smartDetect.trim() === section_id
      ) {
        mockUci.set(UCI_PACKAGE, 'settings', 'smart_detect_sections', []);
      }

      [
        'dns_detour_section',
        'download_lists_via_proxy_section',
        'download_components_via_proxy_section',
        'warp_proxy_section',
      ].forEach((opt) => {
        if (mockUci.get(UCI_PACKAGE, 'settings', opt) === section_id) {
          mockUci.set(UCI_PACKAGE, 'settings', opt, '');
        }
      });
    } catch (_e) {}

    // 3. Clean references in other sections
    try {
      (mockUci.sections(UCI_PACKAGE, 'section') || []).forEach((sec: any) => {
        const sName = sec['.name'];
        if (sName === section_id) return;
        if (sec.outbound_detour_section === section_id) {
          mockUci.set(UCI_PACKAGE, sName, 'outbound_detour_section', '');
          mockUci.set(UCI_PACKAGE, sName, 'outbound_detour_enabled', '0');
        }
        if (sec.dns_detour_section === section_id) {
          mockUci.set(UCI_PACKAGE, sName, 'dns_detour_section', '');
          mockUci.set(UCI_PACKAGE, sName, 'dns_detour_enabled', '0');
        }
      });
    } catch (_e) {}

    // 4. Clean references in servers
    try {
      (mockUci.sections(UCI_PACKAGE, 'server') || []).forEach((srv: any) => {
        const srvName = srv['.name'];
        if (srv.routing_section === section_id) {
          mockUci.set(UCI_PACKAGE, srvName, 'routing_section', '');
          if (srv.routing_mode === 'section') {
            mockUci.set(UCI_PACKAGE, srvName, 'routing_mode', 'rules');
          }
        }
      });
    } catch (_e) {}

    // 5. Clean disk caches
    try {
      if (typeof mockFs !== 'undefined') {
        if (typeof mockFs.remove === 'function') {
          mockFs.remove(`/var/run/tachyon/section-cache/${section_id}.json`);
          mockFs.remove(`/etc/tachyon/subscription-cache/${section_id}.json`);
          mockFs.remove(`/etc/tachyon/subscription-cache/${section_id}.yaml`);
          mockFs.remove(`/etc/tachyon/subscription-cache/${section_id}.txt`);
        }
      }
    } catch (_e) {}
  }

  it('cascades deletion of all child sections for a given section', () => {
    cascadeDelete('sec1');

    // pg1 should be removed, pg2 kept
    expect(
      uciState.priority_group.find((g) => g['.name'] === 'pg1'),
    ).toBeUndefined();
    expect(
      uciState.priority_group.find((g) => g['.name'] === 'pg2'),
    ).toBeDefined();

    // pl1 and pl2 should be removed, pl3 kept
    expect(
      uciState.priority_level.find((l) => l['.name'] === 'pl1'),
    ).toBeUndefined();
    expect(
      uciState.priority_level.find((l) => l['.name'] === 'pl2'),
    ).toBeUndefined();
    expect(
      uciState.priority_level.find((l) => l['.name'] === 'pl3'),
    ).toBeDefined();

    // sub1, if1, ut1 removed; sub2 kept
    expect(
      uciState.subscription_url.find((s) => s['.name'] === 'sub1'),
    ).toBeUndefined();
    expect(
      uciState.subscription_url.find((s) => s['.name'] === 'sub2'),
    ).toBeDefined();
    expect(
      uciState.section_interface.find((i) => i['.name'] === 'if1'),
    ).toBeUndefined();
    expect(uciState.urltest.find((u) => u['.name'] === 'ut1')).toBeUndefined();
  });

  it('cleans references in settings', () => {
    cascadeDelete('sec1');

    const settings = uciState.settings[0];
    expect(settings.smart_detect_sections).toEqual(['sec2']);
    expect(settings.dns_detour_section).toBe('');
    expect(settings.download_lists_via_proxy_section).toBe('');
    expect(settings.download_components_via_proxy_section).toBe('');
    expect(settings.warp_proxy_section).toBe('');
  });

  it('cleans detour references in other sections', () => {
    cascadeDelete('sec1');

    const sec2 = uciState.section.find((s) => s['.name'] === 'sec2');
    expect(sec2.outbound_detour_section).toBe('');
    expect(sec2.outbound_detour_enabled).toBe('0');
    expect(sec2.dns_detour_section).toBe('');
    expect(sec2.dns_detour_enabled).toBe('0');
  });

  it('cleans server routing references and resets routing_mode', () => {
    cascadeDelete('sec1');

    const srv1 = uciState.server.find((s) => s['.name'] === 'srv1');
    expect(srv1.routing_section).toBe('');
    expect(srv1.routing_mode).toBe('rules');

    const srv2 = uciState.server.find((s) => s['.name'] === 'srv2');
    expect(srv2.routing_section).toBe('sec2');
    expect(srv2.routing_mode).toBe('section');
  });

  it('removes disk cache files', () => {
    cascadeDelete('sec1');

    expect(removedFiles).toContain('/var/run/tachyon/section-cache/sec1.json');
    expect(removedFiles).toContain('/etc/tachyon/subscription-cache/sec1.json');
    expect(removedFiles).toContain('/etc/tachyon/subscription-cache/sec1.yaml');
    expect(removedFiles).toContain('/etc/tachyon/subscription-cache/sec1.txt');
  });

  it('re-creating a section with the same name starts clean', () => {
    // 1. Delete sec1
    cascadeDelete('sec1');
    mockUci.remove('tachyon', 'sec1');

    // 2. Add sec1 again with purge
    cascadeDelete('sec1');
    uciState.section.push({
      '.name': 'sec1',
      '.type': 'section',
      label: 'Fresh sec1',
    });

    // 3. Verify no leftover child sections exist for sec1
    const childSubs = (
      mockUci.sections('tachyon', 'subscription_url') || []
    ).filter((item: any) => item.section === 'sec1');
    const childGroups = (
      mockUci.sections('tachyon', 'priority_group') || []
    ).filter((item: any) => item.section === 'sec1');
    const childLevels = (
      mockUci.sections('tachyon', 'priority_level') || []
    ).filter((item: any) => item.section === 'sec1');
    const childIfs = (
      mockUci.sections('tachyon', 'section_interface') || []
    ).filter((item: any) => item.section === 'sec1');
    const childUt = (mockUci.sections('tachyon', 'urltest') || []).filter(
      (item: any) => item.section === 'sec1',
    );

    expect(childSubs).toHaveLength(0);
    expect(childGroups).toHaveLength(0);
    expect(childLevels).toHaveLength(0);
    expect(childIfs).toHaveLength(0);
    expect(childUt).toHaveLength(0);
  });
});
