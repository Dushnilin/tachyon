import { describe, expect, it } from 'vitest';
import type { Tachyon } from '../../types';
import {
  countryCodeToFlagEmoji,
  detectOutboundCountry,
  flagEmojiToCountryCode,
  getCountryName,
  groupOutboundsByCountry,
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
    expect(detectOutboundCountry({ country: 'DE', displayName: 'Server 1' })).toMatchObject({
      code: 'DE',
      flag: '🇩🇪',
    });

    expect(detectOutboundCountry({ displayName: '🇩🇪 Frankfurt-01' })).toMatchObject({
      code: 'DE',
      flag: '🇩🇪',
    });

    expect(detectOutboundCountry({ displayName: '[NL] Amsterdam VIP' })).toMatchObject({
      code: 'NL',
      flag: '🇳🇱',
    });

    expect(detectOutboundCountry({ displayName: 'Russian Federation - fast' })).toMatchObject({
      code: 'RU',
      flag: '🇷🇺',
    });

    expect(detectOutboundCountry({ displayName: 'Custom Relay without country' })).toMatchObject({
      code: 'OTHER',
      flag: '🌐',
    });

    // Fallback to country property if no flag/keyword
    expect(detectOutboundCountry({ displayName: 'Custom Node', country: 'NL' })).toMatchObject({
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
      detectOutboundCountry({ displayName: '🇵🇱 Hysteria 2 | Польша', country: 'US' }),
    ).toMatchObject({
      code: 'PL',
      flag: '🇵🇱',
    });

    // Title with country keyword without flag
    expect(detectOutboundCountry({ displayName: 'Индия Сервер 1' })).toMatchObject({
      code: 'IN',
      flag: '🇮🇳',
    });
    expect(detectOutboundCountry({ displayName: 'Кипр Быстрый' })).toMatchObject({
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

    const nlGroup = groups.find((g) => g.countryCode === 'NL');
    expect(nlGroup).toBeDefined();
    expect(nlGroup?.outbounds.length).toBe(1);
    expect(nlGroup?.bestLatency).toBe(80);

    const otherGroup = groups.find((g) => g.countryCode === 'OTHER');
    expect(otherGroup).toBeDefined();
    expect(otherGroup?.outbounds.length).toBe(1);
    // OTHER should be at the end
    expect(groups[groups.length - 1].countryCode).toBe('OTHER');
  });
});
