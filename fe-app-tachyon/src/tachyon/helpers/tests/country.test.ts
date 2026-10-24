import { describe, expect, it } from 'vitest';
import type { Tachyon } from '../../types';
import {
  countryCodeToFlagEmoji,
  detectOutboundCountry,
  ensureOutboundDisplayFlag,
  flagEmojiToCountryCode,
  getCountryName,
  getCountryRegion,
  getRegionMetadata,
  groupOutboundsByCountry,
  organizeCountryGroups,
} from '../country';

describe('country helper', () => {
  it('extracts country code from flag emojis', () => {
    expect(flagEmojiToCountryCode('🇩🇪 Germany 01')).toBe('DE');
    expect(flagEmojiToCountryCode('🇳🇱 Netherlands')).toBe('NL');
    expect(flagEmojiToCountryCode('🇷🇺 Russia Fast')).toBe('RU');
    expect(flagEmojiToCountryCode('🇺🇸 US East')).toBe('US');
    expect(flagEmojiToCountryCode('No flag here')).toBeUndefined();
  });

  it('converts country code to flag emoji', () => {
    expect(countryCodeToFlagEmoji('DE')).toBe('🇩🇪');
    expect(countryCodeToFlagEmoji('NL')).toBe('🇳🇱');
    expect(countryCodeToFlagEmoji('RU')).toBe('🇷🇺');
    expect(countryCodeToFlagEmoji('US')).toBe('🇺🇸');
    expect(countryCodeToFlagEmoji('XYZ')).toBe('');
  });

  it('gets localized country name', () => {
    expect(getCountryName('DE')).toBe('Германия');
    expect(getCountryName('NL')).toBe('Нидерланды');
    expect(getCountryName('RU')).toBe('Россия');
    expect(getCountryName('US')).toBe('США');
  });

  it('detects outbound country via country property, flag, brackets or name', () => {
    expect(
      detectOutboundCountry({ country: 'DE', displayName: 'Server 1' }),
    ).toMatchObject({
      code: 'DE',
      flag: '🇩🇪',
    });

    expect(
      detectOutboundCountry({ displayName: '🇩🇪 Frankfurt-01' }),
    ).toMatchObject({
      code: 'DE',
      flag: '🇩🇪',
    });

    expect(
      detectOutboundCountry({ displayName: '[NL] Amsterdam VIP' }),
    ).toMatchObject({
      code: 'NL',
      flag: '🇳🇱',
    });

    expect(
      detectOutboundCountry({ displayName: 'Russian Federation - fast' }),
    ).toMatchObject({
      code: 'RU',
      flag: '🇷🇺',
    });

    expect(
      detectOutboundCountry({ displayName: 'Custom Relay without country' }),
    ).toMatchObject({
      code: 'OTHER',
      flag: '🌐',
    });

    // Fallback to country property if no flag/keyword
    expect(
      detectOutboundCountry({ displayName: 'Custom Node', country: 'NL' }),
    ).toMatchObject({
      code: 'NL',
      flag: '🇳🇱',
    });

    // Flag in displayName MUST override inaccurate GeoIP country metadata
    expect(
      detectOutboundCountry({ displayName: '🇮🇳 Индия', country: 'CY' }),
    ).toMatchObject({
      code: 'IN',
      flag: '🇮🇳',
    });
    expect(
      detectOutboundCountry({ displayName: ' 🇩🇪 ⚡ Германия', country: 'AE' }),
    ).toMatchObject({
      code: 'DE',
      flag: '🇩🇪',
    });
    expect(
      detectOutboundCountry({
        displayName: '🇵🇱 Hysteria 2 | Польша',
        country: 'US',
      }),
    ).toMatchObject({
      code: 'PL',
      flag: '🇵🇱',
    });

    // Title with country keyword without flag
    expect(
      detectOutboundCountry({ displayName: 'Индия Сервер 1' }),
    ).toMatchObject({
      code: 'IN',
      flag: '🇮🇳',
    });
    expect(
      detectOutboundCountry({ displayName: 'Кипр Быстрый' }),
    ).toMatchObject({
      code: 'CY',
      flag: '🇨🇾',
    });
  });

  it('groups outbounds by country and computes bestLatency', () => {
    const outbounds: Tachyon.Outbound[] = [
      {
        code: 'de-1',
        displayName: '🇩🇪 Germany 01',
        latency: 120,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'de-2',
        displayName: '🇩🇪 Germany 02',
        latency: 45,
        type: 'VLESS',
        selected: true,
      },
      {
        code: 'nl-1',
        displayName: '🇳🇱 Netherlands 01',
        latency: 80,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'custom-1',
        displayName: 'Custom Node',
        latency: 50,
        type: 'VLESS',
        selected: false,
      },
    ];

    const groups = groupOutboundsByCountry(outbounds);
    expect(groups.length).toBe(3);

    const deGroup = groups.find((g) => g.countryCode === 'DE');
    expect(deGroup).toBeDefined();
    expect(deGroup?.outbounds.length).toBe(2);
    expect(deGroup?.bestLatency).toBe(45);
    expect(deGroup?.region).toBe('europe');

    const nlGroup = groups.find((g) => g.countryCode === 'NL');
    expect(nlGroup).toBeDefined();
    expect(nlGroup?.outbounds.length).toBe(1);
    expect(nlGroup?.bestLatency).toBe(80);
    expect(nlGroup?.region).toBe('europe');

    const otherGroup = groups.find((g) => g.countryCode === 'OTHER');
    expect(otherGroup).toBeDefined();
    expect(otherGroup?.outbounds.length).toBe(1);
    expect(otherGroup?.region).toBe('other');
    // OTHER should be at the end
    expect(groups[groups.length - 1].countryCode).toBe('OTHER');
  });

  it('computes min and max latencies according to latencyMode', () => {
    const outbounds: Tachyon.Outbound[] = [
      {
        code: 'us-1',
        displayName: '🇺🇸 US Atlanta',
        latency: 147,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'us-2',
        displayName: '🇺🇸 US Miami',
        latency: 175,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'us-3',
        displayName: '🇺🇸 US Seattle',
        latency: 199,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'us-4',
        displayName: '🇺🇸 US Phoenix',
        latency: 471,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'us-5',
        displayName: '🇺🇸 US Washington',
        latency: -1,
        type: 'VLESS',
        selected: false,
      },
    ];

    const minGroups = groupOutboundsByCountry(outbounds, undefined, {
      latencyMode: 'min',
    });
    const usMin = minGroups.find((g) => g.countryCode === 'US');
    expect(usMin).toBeDefined();
    expect(usMin?.bestLatency).toBe(147);
    expect(usMin?.minLatency).toBe(147);
    expect(usMin?.maxLatency).toBe(471);

    const maxGroups = groupOutboundsByCountry(outbounds, undefined, {
      latencyMode: 'max',
    });
    const usMax = maxGroups.find((g) => g.countryCode === 'US');
    expect(usMax).toBeDefined();
    expect(usMax?.bestLatency).toBe(471);
    expect(usMax?.minLatency).toBe(147);
    expect(usMax?.maxLatency).toBe(471);
  });

  it('classifies country codes into world regions correctly', () => {
    expect(getCountryRegion('DE')).toBe('europe');
    expect(getCountryRegion('RU')).toBe('europe');
    expect(getCountryRegion('CY')).toBe('europe');
    expect(getCountryRegion('TR')).toBe('asia');
    expect(getCountryRegion('AE')).toBe('asia');
    expect(getCountryRegion('IN')).toBe('asia');
    expect(getCountryRegion('US')).toBe('americas');
    expect(getCountryRegion('BR')).toBe('americas');
    expect(getCountryRegion('AU')).toBe('other');
    expect(getCountryRegion('XYZ')).toBe('other');

    expect(getRegionMetadata('europe', 'ru').label).toBe('Европа');
    expect(getRegionMetadata('europe', 'en').label).toBe('Europe');
    expect(getRegionMetadata('asia', 'ru').label).toBe('Азия и Восток');
    expect(getRegionMetadata('americas', 'ru').label).toBe('Америка');
  });

  it('organizes country groups in regions mode', () => {
    const outbounds: Tachyon.Outbound[] = [
      {
        code: 'de-1',
        displayName: '🇩🇪 Germany',
        latency: 50,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'fr-1',
        displayName: '🇫🇷 France',
        latency: 40,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'us-1',
        displayName: '🇺🇸 US',
        latency: 150,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'ae-1',
        displayName: '🇦🇪 UAE',
        latency: 100,
        type: 'VLESS',
        selected: false,
      },
    ];
    const countryGroups = groupOutboundsByCountry(outbounds);

    // All regions
    const resAll = organizeCountryGroups(countryGroups, 'regions', {
      selectedRegion: 'all',
    });
    expect(resAll.availableRegions.length).toBe(4); // all, europe, asia, americas
    expect(resAll.availableRegions.find((r) => r.id === 'all')?.count).toBe(4);
    expect(resAll.availableRegions.find((r) => r.id === 'europe')?.count).toBe(
      2,
    );
    expect(resAll.groups.length).toBe(4);

    // Filter to Europe
    const resEurope = organizeCountryGroups(countryGroups, 'regions', {
      selectedRegion: 'europe',
    });
    expect(resEurope.groups.length).toBe(2);
    expect(resEurope.groups.map((g) => g.countryCode)).toEqual(['DE', 'FR']);
  });

  it('organizes country groups in smart_top mode with active and popular countries first', () => {
    const outbounds: Tachyon.Outbound[] = [
      {
        code: 'at-1',
        displayName: '🇦🇹 Austria',
        latency: 60,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'de-1',
        displayName: '🇩🇪 Germany 1',
        latency: 40,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'de-2',
        displayName: '🇩🇪 Germany 2',
        latency: 40,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'us-1',
        displayName: '🇺🇸 US 1',
        latency: 140,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'us-2',
        displayName: '🇺🇸 US 2',
        latency: 140,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'us-3',
        displayName: '🇺🇸 US 3',
        latency: 140,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'nl-1',
        displayName: '🇳🇱 Netherlands 1',
        latency: 50,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'nl-2',
        displayName: '🇳🇱 Netherlands 2',
        latency: 50,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'nl-3',
        displayName: '🇳🇱 Netherlands 3',
        latency: 50,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'nl-4',
        displayName: '🇳🇱 Netherlands 4',
        latency: 50,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'cy-1',
        displayName: '🇨🇾 Cyprus 1',
        latency: 80,
        type: 'VLESS',
        selected: true,
      },
    ];
    const countryGroups = groupOutboundsByCountry(outbounds);

    const res = organizeCountryGroups(countryGroups, 'smart_top', {
      activeCountryCode: 'CY',
    });
    // Active country CY first
    expect(res.groups[0].countryCode).toBe('CY');
    // Followed by top 3 by server count: NL (4), US (3), DE (2)
    expect(res.groups[1].countryCode).toBe('NL');
    expect(res.groups[2].countryCode).toBe('US');
    expect(res.groups[3].countryCode).toBe('DE');
    expect(res.topCount).toBe(4);
    // Followed by rest sorted alphabetically: AT (Австрия)
    expect(res.groups[4].countryCode).toBe('AT');
  });

  it('organizes country groups by latency', () => {
    const outbounds: Tachyon.Outbound[] = [
      {
        code: 'us-1',
        displayName: '🇺🇸 US',
        latency: 150,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'de-1',
        displayName: '🇩🇪 Germany',
        latency: 35,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'nl-1',
        displayName: '🇳🇱 Netherlands',
        latency: 60,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'untested-1',
        displayName: '🏳️ Untested',
        latency: 0,
        type: 'VLESS',
        selected: false,
      },
    ];
    const countryGroups = groupOutboundsByCountry(outbounds);

    const res = organizeCountryGroups(countryGroups, 'latency');
    expect(res.groups[0].countryCode).toBe('DE'); // 35ms
    expect(res.groups[1].countryCode).toBe('NL'); // 60ms
    expect(res.groups[2].countryCode).toBe('US'); // 150ms
    expect(res.groups[3].countryCode).toBe('OTHER'); // untest
  });

  it('filters country groups by search query', () => {
    const outbounds: Tachyon.Outbound[] = [
      {
        code: 'de-1',
        displayName: '🇩🇪 Frankfurt Fast',
        latency: 35,
        type: 'VLESS',
        selected: false,
      },
      {
        code: 'nl-1',
        displayName: '🇳🇱 Amsterdam Pro',
        latency: 60,
        type: 'VLESS',
        selected: false,
      },
    ];
    const countryGroups = groupOutboundsByCountry(outbounds);

    const resFrankfurt = organizeCountryGroups(countryGroups, 'alphabetical', {
      searchQuery: 'frank',
    });
    expect(resFrankfurt.groups.length).toBe(1);
    expect(resFrankfurt.groups[0].countryCode).toBe('DE');

    const resRu = organizeCountryGroups(countryGroups, 'alphabetical', {
      searchQuery: 'нидер',
    });
    expect(resRu.groups.length).toBe(1);
    expect(resRu.groups[0].countryCode).toBe('NL');
  });

  it('recognizes Czechia and prepends flag emojis via ensureOutboundDisplayFlag', () => {
    expect(
      detectOutboundCountry({ displayName: 'Czechia-Premium' }),
    ).toMatchObject({
      code: 'CZ',
      flag: '🇨🇿',
    });
    expect(ensureOutboundDisplayFlag({ displayName: 'Czechia-Premium' })).toBe(
      '🇨🇿 Czechia-Premium',
    );
    expect(ensureOutboundDisplayFlag({ displayName: 'Austria-Premium' })).toBe(
      '🇦🇹 Austria-Premium',
    );
    expect(
      ensureOutboundDisplayFlag({
        displayName: 'Russia-Premium-26(Netherlands)',
      }),
    ).toBe('🇷🇺 Russia-Premium-26(Netherlands)');
    expect(
      ensureOutboundDisplayFlag({ displayName: '🇩🇪 Germany-Premium' }),
    ).toBe('🇩🇪 Germany-Premium');
  });
});
