import type { Tachyon } from '../types';

const translate = (key: string) => (typeof _ === 'function' ? _(key) : key);

export interface OutboundCountryInfo {
  code: string;
  flag: string;
  name: string;
}

export type WorldRegion = 'all' | 'europe' | 'asia' | 'americas' | 'other';

export interface OutboundCountryGroup {
  countryCode: string;
  countryFlag: string;
  countryName: string;
  region: WorldRegion;
  outbounds: Tachyon.Outbound[];
  bestLatency: number;
  minLatency?: number;
  maxLatency?: number;
}

export const EUROPE_CODES = new Set([
  'RU',
  'DE',
  'NL',
  'GB',
  'UK',
  'FR',
  'FI',
  'SE',
  'PL',
  'CH',
  'AT',
  'ES',
  'IT',
  'UA',
  'NO',
  'CZ',
  'EE',
  'LV',
  'LT',
  'MD',
  'BY',
  'RS',
  'BG',
  'RO',
  'HU',
  'GR',
  'CY',
  'IS',
  'IE',
  'PT',
  'BE',
  'DK',
  'SK',
  'HR',
  'BA',
  'AL',
  'MK',
  'LI',
  'LU',
  'MC',
  'SM',
  'VA',
  'AD',
  'MT',
  'ME',
  'SI',
]);

export const ASIA_MIDEAST_CODES = new Set([
  'TR',
  'KZ',
  'SG',
  'JP',
  'HK',
  'AE',
  'GE',
  'AM',
  'UZ',
  'KG',
  'IL',
  'IN',
  'KR',
  'TW',
  'TH',
  'VN',
  'AZ',
  'ID',
  'MY',
  'PH',
  'PK',
  'BD',
  'QA',
  'BH',
  'IQ',
  'MN',
  'KH',
  'LK',
  'BN',
  'CN',
  'SA',
  'OM',
  'KW',
  'JO',
  'LB',
  'TJ',
  'TM',
  'NP',
  'MM',
  'LA',
]);

export const AMERICAS_CODES = new Set([
  'US',
  'CA',
  'BR',
  'AR',
  'MX',
  'CL',
  'CO',
  'PE',
  'VE',
  'EC',
  'UY',
  'PY',
  'BO',
  'CR',
  'PA',
]);

export function getCountryRegion(countryCode?: string): WorldRegion {
  const code = `${countryCode || ''}`.trim().toUpperCase();
  if (EUROPE_CODES.has(code)) return 'europe';
  if (ASIA_MIDEAST_CODES.has(code)) return 'asia';
  if (AMERICAS_CODES.has(code)) return 'americas';
  return 'other';
}

export interface RegionMetadata {
  id: WorldRegion;
  label: string;
  flag: string;
}

export function getRegionMetadata(
  region: WorldRegion,
  locale?: string,
): RegionMetadata {
  const isDocRu =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('ru');
  const isDocEn =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('en');
  const isRu = (locale ? locale.startsWith('ru') : !isDocEn) || isDocRu;

  switch (region) {
    case 'europe':
      return { id: 'europe', label: isRu ? 'Европа' : 'Europe', flag: '🇪🇺' };
    case 'asia':
      return {
        id: 'asia',
        label: isRu ? 'Азия и Восток' : 'Asia & Mideast',
        flag: '🌏',
      };
    case 'americas':
      return {
        id: 'americas',
        label: isRu ? 'Америка' : 'Americas',
        flag: '🌎',
      };
    case 'other':
      return { id: 'other', label: isRu ? 'Другие' : 'Other', flag: '🌍' };
    case 'all':
    default:
      return { id: 'all', label: isRu ? 'Все' : 'All', flag: '🌐' };
  }
}

const FALLBACK_NAMES_RU: Record<string, string> = {
  RU: 'Россия',
  DE: 'Германия',
  NL: 'Нидерланды',
  US: 'США',
  GB: 'Великобритания',
  UK: 'Великобритания',
  FR: 'Франция',
  FI: 'Финляндия',
  SE: 'Швеция',
  PL: 'Польша',
  TR: 'Турция',
  KZ: 'Казахстан',
  SG: 'Сингапур',
  JP: 'Япония',
  HK: 'Гонконг',
  CA: 'Канада',
  CH: 'Швейцария',
  AT: 'Австрия',
  ES: 'Испания',
  IT: 'Италия',
  UA: 'Украина',
  AE: 'ОАЭ',
  NO: 'Норвегия',
  CZ: 'Чехия',
  EE: 'Эстония',
  LV: 'Латвия',
  LT: 'Литва',
  MD: 'Молдова',
  BY: 'Беларусь',
  GE: 'Грузия',
  AM: 'Армения',
  UZ: 'Узбекистан',
  KG: 'Кыргызстан',
  RS: 'Сербия',
  BG: 'Болгария',
  RO: 'Румыния',
  HU: 'Венгрия',
  GR: 'Греция',
  CY: 'Кипр',
  IL: 'Израиль',
  IN: 'Индия',
  KR: 'Южная Корея',
  AU: 'Австралия',
  BR: 'Бразилия',
  AR: 'Аргентина',
  MX: 'Мексика',
  IS: 'Исландия',
  IE: 'Ирландия',
  PT: 'Португалия',
  BE: 'Бельгия',
  DK: 'Дания',
};

const COMMON_ISO_CODES = new Set([
  'RU',
  'DE',
  'NL',
  'US',
  'GB',
  'UK',
  'FR',
  'FI',
  'SE',
  'PL',
  'TR',
  'KZ',
  'SG',
  'JP',
  'HK',
  'CA',
  'CH',
  'AT',
  'ES',
  'IT',
  'UA',
  'AE',
  'NO',
  'CZ',
  'EE',
  'LV',
  'LT',
  'MD',
  'BY',
  'GE',
  'AM',
  'UZ',
  'KG',
  'RS',
  'BG',
  'RO',
  'HU',
  'GR',
  'CY',
  'IL',
  'IN',
  'KR',
  'AU',
  'BR',
  'AR',
  'MX',
  'IS',
  'IE',
  'PT',
  'BE',
  'DK',
]);

function buildCountryRegex(pattern: string): RegExp {
  return new RegExp(
    `(?:^|[^\\p{L}\\p{N}])(?:${pattern})(?:[^\\p{L}\\p{N}]|$)`,
    'iu',
  );
}

const COUNTRY_KEYWORD_PATTERNS: Array<{ code: string; regex: RegExp }> = [
  {
    code: 'RU',
    regex: buildCountryRegex(
      'russia|russian|россия|рф|москва|moscow|питер|spb',
    ),
  },
  {
    code: 'DE',
    regex: buildCountryRegex(
      'germany|german|германия|frankfurt|франкфурт|berlin|берлин',
    ),
  },
  {
    code: 'NL',
    regex: buildCountryRegex(
      'netherlands|holland|нидерланды|голландия|amsterdam|амстердам',
    ),
  },
  {
    code: 'US',
    regex: buildCountryRegex(
      'usa|united\\s*states|сша|america|америка|new\\s*york|los\\s*angeles|miami',
    ),
  },
  {
    code: 'GB',
    regex: buildCountryRegex(
      'uk|united\\s*kingdom|great\\s*britain|великобритания|англия|london|лондон',
    ),
  },
  {
    code: 'TR',
    regex: buildCountryRegex('turkey|turkish|турция|istanbul|стамбул'),
  },
  {
    code: 'FI',
    regex: buildCountryRegex('finland|финляндия|helsinki|хельсинки'),
  },
  { code: 'SE', regex: buildCountryRegex('sweden|швеция|stockholm|стокгольм') },
  { code: 'PL', regex: buildCountryRegex('poland|польша|warsaw|варшава') },
  {
    code: 'KZ',
    regex: buildCountryRegex(
      'kazakhstan|казахстан|almaty|алматы|astana|астана',
    ),
  },
  { code: 'FR', regex: buildCountryRegex('france|франция|paris|париж') },
  { code: 'SG', regex: buildCountryRegex('singapore|сингапур') },
  { code: 'JP', regex: buildCountryRegex('japan|япония|tokyo|токио') },
  { code: 'HK', regex: buildCountryRegex('hong\\s*kong|гонконг') },
  {
    code: 'CH',
    regex: buildCountryRegex(
      'switzerland|швейцария|zurich|цюрих|geneva|женева',
    ),
  },
  { code: 'AT', regex: buildCountryRegex('austria|австрия|vienna|вена') },
  {
    code: 'ES',
    regex: buildCountryRegex('spain|испания|madrid|мадрид|barcelona|барселона'),
  },
  { code: 'IT', regex: buildCountryRegex('italy|италия|rome|рим|milan|милан') },
  {
    code: 'CA',
    regex: buildCountryRegex(
      'canada|канада|toronto|торонто|vancouver|ванкувер',
    ),
  },
  { code: 'UA', regex: buildCountryRegex('ukraine|украина|kyiv|kiev|киев') },
  {
    code: 'AE',
    regex: buildCountryRegex('uae|emirates|оаэ|эмираты|dubai|дубай'),
  },
  { code: 'GE', regex: buildCountryRegex('georgia|грузия|tbilisi|тбилиси') },
  { code: 'AM', regex: buildCountryRegex('armenia|армения|yerevan|ереван') },
  { code: 'MD', regex: buildCountryRegex('moldova|молдова|chisinau|кишинев') },
  {
    code: 'BY',
    regex: buildCountryRegex('belarus|беларусь|белоруссия|minsk|минск'),
  },
  { code: 'RS', regex: buildCountryRegex('serbia|сербия|belgrade|белград') },
  {
    code: 'IL',
    regex: buildCountryRegex('israel|израиль|tel\\s*aviv|тель-авив'),
  },
  {
    code: 'IN',
    regex: buildCountryRegex('india|индия|mumbai|мумбаи|delhi|дели'),
  },
  {
    code: 'CY',
    regex: buildCountryRegex('cyprus|кипр|limassol|лимасол|nicosia|никосия'),
  },
  { code: 'TW', regex: buildCountryRegex('taiwan|тайвань|taipei|тайбэй') },
  { code: 'CZ', regex: buildCountryRegex('czechia|czech|чехия|prague|прага') },
  {
    code: 'SK',
    regex: buildCountryRegex('slovakia|словакия|bratislava|братислава'),
  },
  {
    code: 'RO',
    regex: buildCountryRegex('romania|румыния|bucharest|бухарест'),
  },
  { code: 'BG', regex: buildCountryRegex('bulgaria|болгария|sofia|софия') },
  { code: 'HU', regex: buildCountryRegex('hungary|венгрия|budapest|будапешт') },
  { code: 'LT', regex: buildCountryRegex('lithuania|литва|vilnius|вильнюс') },
  { code: 'LV', regex: buildCountryRegex('latvia|латвия|riga|рига') },
  { code: 'EE', regex: buildCountryRegex('estonia|эстония|tallinn|таллин') },
  {
    code: 'UZ',
    regex: buildCountryRegex('uzbekistan|узбекистан|tashkent|ташкент'),
  },
  {
    code: 'KG',
    regex: buildCountryRegex('kyrgyzstan|кыргызстан|киргизия|bishkek|бишкек'),
  },
  {
    code: 'TH',
    regex: buildCountryRegex('thailand|таиланд|тайланд|bangkok|бангкок'),
  },
  { code: 'VN', regex: buildCountryRegex('vietnam|вьетнам|hanoi|ханой') },
  { code: 'KR', regex: buildCountryRegex('korea|корея|seoul|сеул') },
  {
    code: 'AU',
    regex: buildCountryRegex(
      'australia|австралия|sydney|сидней|melbourne|мельбурн',
    ),
  },
  {
    code: 'BR',
    regex: buildCountryRegex('brazil|бразилия|sao\\s*paulo|сан-паулу'),
  },
  {
    code: 'AR',
    regex: buildCountryRegex(
      'argentina|аргентина|buenos\\s*aires|буэнос-айрес',
    ),
  },
  { code: 'CL', regex: buildCountryRegex('chile|чили|santiago|сантьяго') },
  { code: 'CO', regex: buildCountryRegex('colombia|колумбия|bogota|богота') },
  { code: 'MX', regex: buildCountryRegex('mexico|мексика') },
  { code: 'EG', regex: buildCountryRegex('egypt|египет|cairo|каир') },
  {
    code: 'IS',
    regex: buildCountryRegex('iceland|исландия|reykjavik|рейкьявик'),
  },
  { code: 'NO', regex: buildCountryRegex('norway|норвегия|oslo|осло') },
  {
    code: 'DK',
    regex: buildCountryRegex('denmark|дания|copenhagen|копенгаген'),
  },
  { code: 'IE', regex: buildCountryRegex('ireland|ирландия|dublin|дублин') },
  {
    code: 'PT',
    regex: buildCountryRegex('portugal|португалия|lisbon|лиссабон'),
  },
  { code: 'BE', regex: buildCountryRegex('belgium|бельгия|brussels|брюссель') },
  { code: 'LU', regex: buildCountryRegex('luxembourg|люксембург') },
  { code: 'GR', regex: buildCountryRegex('greece|греция|athens|афины') },
  { code: 'HR', regex: buildCountryRegex('croatia|хорватия|zagreb|загреб') },
  { code: 'BA', regex: buildCountryRegex('bosnia|босния|sarajevo|сараево') },
  { code: 'AL', regex: buildCountryRegex('albania|албания|tirana|тирана') },
  { code: 'MK', regex: buildCountryRegex('macedonia|македония|skopje|скопье') },
  { code: 'AZ', regex: buildCountryRegex('azerbaijan|азербайджан|baku|баку') },
  {
    code: 'ID',
    regex: buildCountryRegex('indonesia|индонезия|jakarta|джакарта'),
  },
  {
    code: 'MY',
    regex: buildCountryRegex('malaysia|малайзия|kuala\\s*lumpur|куала-лумпур'),
  },
  {
    code: 'PH',
    regex: buildCountryRegex('philippines|филиппины|manila|манила'),
  },
  { code: 'PK', regex: buildCountryRegex('pakistan|пакистан') },
  { code: 'BD', regex: buildCountryRegex('bangladesh|бангладеш|dhaka|дакка') },
  { code: 'QA', regex: buildCountryRegex('qatar|катар|doha|доха') },
  { code: 'BH', regex: buildCountryRegex('bahrain|бахрейн|manama|манама') },
  { code: 'IQ', regex: buildCountryRegex('iraq|ирак|baghdad|багдад') },
  {
    code: 'MN',
    regex: buildCountryRegex('mongolia|монголия|ulaanbaatar|улан-батор'),
  },
  {
    code: 'KH',
    regex: buildCountryRegex('cambodia|камбоджа|phnom\\s*penh|пномпень'),
  },
  {
    code: 'LK',
    regex: buildCountryRegex('sri\\s*lanka|шри-ланка|colombo|коломбо'),
  },
  { code: 'BN', regex: buildCountryRegex('brunei|бруней') },
  { code: 'LI', regex: buildCountryRegex('liechtenstein|лихтенштейн') },
  { code: 'SS', regex: buildCountryRegex('south\\s*sudan|южный\\s*судан') },
  { code: 'AQ', regex: buildCountryRegex('antarctica|антарктида') },
];

/**
 * Extracts a 2-letter ISO country code from flag emoji in the string.
 * Regional Indicator characters in UTF-16: high surrogate 0xD83C, low surrogate 0xDDE6..0xDDFF.
 */
export function flagEmojiToCountryCode(str?: string): string | undefined {
  if (!str) return undefined;

  for (let i = 0; i + 3 < str.length; i++) {
    if (
      str.charCodeAt(i) === 0xd83c &&
      str.charCodeAt(i + 1) >= 0xdde6 &&
      str.charCodeAt(i + 1) <= 0xddff &&
      str.charCodeAt(i + 2) === 0xd83c &&
      str.charCodeAt(i + 3) >= 0xdde6 &&
      str.charCodeAt(i + 3) <= 0xddff
    ) {
      const char1 = String.fromCharCode(str.charCodeAt(i + 1) - 0xdde6 + 65);
      const char2 = String.fromCharCode(str.charCodeAt(i + 3) - 0xdde6 + 65);
      return `${char1}${char2}`.toUpperCase();
    }
  }

  return undefined;
}

/**
 * Converts a 2-letter ISO country code into a flag emoji.
 */
export function countryCodeToFlagEmoji(countryCode?: string): string {
  const code = `${countryCode || ''}`.trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(code)) {
    return '';
  }

  return String.fromCodePoint(
    ...code.split('').map((char) => 0x1f1e6 + char.charCodeAt(0) - 65),
  );
}

const PREFERRED_NAMES_RU: Record<string, string> = {
  US: 'США',
  GB: 'Великобритания',
  UK: 'Великобритания',
  AE: 'ОАЭ',
  RU: 'Россия',
  DE: 'Германия',
  NL: 'Нидерланды',
  KR: 'Южная Корея',
  HK: 'Гонконг',
  MK: 'Македония',
  KG: 'Кыргызстан',
  CZ: 'Чехия',
  CY: 'Кипр',
  IN: 'Индия',
  SS: 'Южный Судан',
  AQ: 'Антарктида',
  BA: 'Босния и Герцеговина',
};

/**
 * Gets a human-readable localized country name.
 */
export function getCountryName(countryCode: string, locale?: string): string {
  const code = countryCode.toUpperCase();
  if (code === 'OTHER') {
    return translate('Other');
  }

  const isDocEn =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('en');

  const effectiveLocale = locale || (isDocEn ? 'en' : 'ru');
  const isRu = effectiveLocale.startsWith('ru');

  if (isRu && PREFERRED_NAMES_RU[code]) {
    return PREFERRED_NAMES_RU[code];
  }

  try {
    if (
      typeof Intl !== 'undefined' &&
      typeof Intl.DisplayNames === 'function'
    ) {
      const displayNames = new Intl.DisplayNames([effectiveLocale, 'en'], {
        type: 'region',
      });
      const name = displayNames.of(code === 'UK' ? 'GB' : code);
      if (name && name !== code) {
        return name;
      }
    }
  } catch {
    // ignore
  }

  if (isRu && FALLBACK_NAMES_RU[code]) {
    return FALLBACK_NAMES_RU[code];
  }

  return code;
}

/**
 * Detects country info (code, flag, name) from an outbound.
 * Priority:
 * 1. Flag emoji in displayName or prefix (canonical, user/provider specified)
 * 2. Country keywords in displayName or prefix (e.g. "Германия", "Индия", "Кипр")
 * 3. Isolated ISO code in brackets or prefixes: [DE], (NL), "DE - "
 * 4. outbound.country (GeoIP fallback only if name has no flag or country name)
 */
export function detectOutboundCountry(
  outbound: {
    displayName?: string;
    prefix?: string;
    country?: string;
  },
  locale?: string,
): OutboundCountryInfo {
  let code: string | undefined;

  // 1. Flag emoji in displayName or prefix
  code =
    flagEmojiToCountryCode(outbound.displayName) ||
    flagEmojiToCountryCode(outbound.prefix);

  // 2. Keyword patterns in displayName or prefix
  if (!code) {
    const text = `${outbound.prefix || ''} ${outbound.displayName || ''}`;
    for (const { code: c, regex } of COUNTRY_KEYWORD_PATTERNS) {
      if (regex.test(text)) {
        code = c;
        break;
      }
    }
  }

  // 3. Isolated ISO code in brackets or prefixes: [DE], (NL), "DE - "
  if (!code) {
    const text = `${outbound.prefix || ''} ${outbound.displayName || ''}`;
    const isoMatches = text.match(/(?:^|[\s[(_-])([A-Z]{2})(?:[\s\])_.-]|$)/g);
    if (isoMatches) {
      for (const m of isoMatches) {
        const candidate = m.replace(/[^A-Z]/g, '').toUpperCase();
        if (COMMON_ISO_CODES.has(candidate)) {
          code = candidate;
          break;
        }
      }
    }
  }

  // 4. Fallback to direct country property (GeoIP) ONLY if no flag or country keyword was found
  if (!code) {
    const direct = `${outbound.country || ''}`.trim().toUpperCase();
    if (/^[A-Z]{2}$/.test(direct)) {
      code = direct;
    }
  }

  if (code) {
    const flag = countryCodeToFlagEmoji(code);
    const name = getCountryName(code, locale);
    return { code, flag, name };
  }

  return {
    code: 'OTHER',
    flag: '🌐',
    name: translate('Other'),
  };
}

/**
 * Prepends a detected country flag emoji to an outbound's display name
 * if the name does not already contain a flag emoji and a known country
 * can be identified from the name/prefix/country metadata.
 */
export function ensureOutboundDisplayFlag(outbound: {
  displayName?: string;
  prefix?: string;
  country?: string;
}): string {
  const displayName = `${outbound.displayName || ''}`;
  if (!displayName) return '';
  if (
    flagEmojiToCountryCode(displayName) ||
    flagEmojiToCountryCode(outbound.prefix)
  ) {
    return displayName;
  }
  const info = detectOutboundCountry(outbound);
  if (info.code !== 'OTHER' && info.flag) {
    return `${info.flag} ${displayName}`;
  }
  return displayName;
}

export interface GroupOutboundsByCountryOptions {
  latencyMode?: 'min' | 'max';
}

/**
 * Groups an array of outbounds by country.
 */
export function groupOutboundsByCountry(
  outbounds: Tachyon.Outbound[],
  locale?: string,
  options?: GroupOutboundsByCountryOptions,
): OutboundCountryGroup[] {
  const latencyMode = options?.latencyMode || 'min';
  const groupsMap = new Map<
    string,
    OutboundCountryGroup & { _minLatency: number; _maxLatency: number }
  >();

  for (const outbound of outbounds) {
    const info = detectOutboundCountry(outbound, locale);
    let group = groupsMap.get(info.code);
    if (!group) {
      group = {
        countryCode: info.code,
        countryFlag: info.flag,
        countryName: info.name,
        region: getCountryRegion(info.code),
        outbounds: [],
        bestLatency: Number.POSITIVE_INFINITY,
        _minLatency: Number.POSITIVE_INFINITY,
        _maxLatency: Number.NEGATIVE_INFINITY,
      };
      groupsMap.set(info.code, group);
    }
    group.outbounds.push(outbound);

    if (Number.isFinite(outbound.latency) && outbound.latency > 0) {
      if (outbound.latency < group._minLatency) {
        group._minLatency = outbound.latency;
      }
      if (outbound.latency > group._maxLatency) {
        group._maxLatency = outbound.latency;
      }
    }
  }

  for (const group of groupsMap.values()) {
    if (Number.isFinite(group._minLatency)) {
      group.minLatency = group._minLatency;
    }
    if (Number.isFinite(group._maxLatency) && group._maxLatency > 0) {
      group.maxLatency = group._maxLatency;
    }
    if (latencyMode === 'max') {
      group.bestLatency = group.maxLatency ?? Number.POSITIVE_INFINITY;
    } else {
      group.bestLatency = group.minLatency ?? Number.POSITIVE_INFINITY;
    }
  }

  const isDocEn =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('en');
  const sortLocale = locale || (isDocEn ? 'en' : 'ru');

  return Array.from(groupsMap.values()).sort((a, b) => {
    if (a.countryCode === 'OTHER') return 1;
    if (b.countryCode === 'OTHER') return -1;
    return a.countryName.localeCompare(b.countryName, sortLocale);
  });
}

export interface OrganizedCountryGroups {
  groups: OutboundCountryGroup[];
  topCount?: number;
  availableRegions: Array<{
    id: WorldRegion;
    label: string;
    flag: string;
    count: number;
  }>;
}

export function organizeCountryGroups(
  countryGroups: OutboundCountryGroup[],
  mode: 'regions' | 'smart_top' | 'latency' | 'alphabetical' = 'regions',
  options?: {
    activeCountryCode?: string;
    selectedRegion?: WorldRegion;
    locale?: string;
    searchQuery?: string;
  },
): OrganizedCountryGroups {
  const isDocEn =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('en');
  const sortLocale = options?.locale || (isDocEn ? 'en' : 'ru');

  // Compute available regions across the full group set
  const regionCounts: Record<WorldRegion, number> = {
    all: 0,
    europe: 0,
    asia: 0,
    americas: 0,
    other: 0,
  };

  for (const group of countryGroups) {
    const reg = group.region in regionCounts ? group.region : 'other';
    const serverCount = group.outbounds.length;
    regionCounts.all += serverCount;
    regionCounts[reg] += serverCount;
  }

  const regionOrder: WorldRegion[] = [
    'all',
    'europe',
    'asia',
    'americas',
    'other',
  ];
  const availableRegions = regionOrder
    .filter((r) => r === 'all' || regionCounts[r] > 0)
    .map((r) => {
      const meta = getRegionMetadata(r, sortLocale);
      return {
        ...meta,
        count: regionCounts[r],
      };
    });

  let workingGroups = [...countryGroups];

  // Optional search query filter
  if (options?.searchQuery) {
    const q = options.searchQuery.trim().toLowerCase();
    if (q) {
      workingGroups = workingGroups.filter((g) => {
        if (g.countryName.toLowerCase().includes(q)) return true;
        if (g.countryCode.toLowerCase().includes(q)) return true;
        return g.outbounds.some(
          (ob) =>
            (ob.displayName && ob.displayName.toLowerCase().includes(q)) ||
            (ob.prefix && ob.prefix.toLowerCase().includes(q)),
        );
      });
    }
  }

  // 1. By regions
  if (mode === 'regions') {
    const targetRegion = options?.selectedRegion || 'all';
    if (targetRegion !== 'all') {
      workingGroups = workingGroups.filter((g) => g.region === targetRegion);
    }
    workingGroups.sort((a, b) => {
      if (a.countryCode === 'OTHER') return 1;
      if (b.countryCode === 'OTHER') return -1;
      return a.countryName.localeCompare(b.countryName, sortLocale);
    });
    return {
      groups: workingGroups,
      availableRegions,
    };
  }

  // 2. Smart top
  if (mode === 'smart_top') {
    const topGroups: OutboundCountryGroup[] = [];
    const activeCode = options?.activeCountryCode;
    const remaining = [...workingGroups];

    if (activeCode) {
      const activeIdx = remaining.findIndex(
        (g) => g.countryCode === activeCode,
      );
      if (activeIdx !== -1) {
        topGroups.push(remaining[activeIdx]);
        remaining.splice(activeIdx, 1);
      }
    }

    // Top 3 remaining by outbounds count desc
    remaining.sort((a, b) => b.outbounds.length - a.outbounds.length);
    const topPopular = remaining.slice(0, 3);
    topGroups.push(...topPopular);

    const otherGroups = remaining.slice(3).sort((a, b) => {
      if (a.countryCode === 'OTHER') return 1;
      if (b.countryCode === 'OTHER') return -1;
      return a.countryName.localeCompare(b.countryName, sortLocale);
    });

    return {
      groups: [...topGroups, ...otherGroups],
      topCount: topGroups.length,
      availableRegions,
    };
  }

  // 3. By latency
  if (mode === 'latency') {
    workingGroups.sort((a, b) => {
      const aLat =
        a.bestLatency > 0 && Number.isFinite(a.bestLatency)
          ? a.bestLatency
          : 999999;
      const bLat =
        b.bestLatency > 0 && Number.isFinite(b.bestLatency)
          ? b.bestLatency
          : 999999;
      if (aLat !== bLat) return aLat - bLat;
      if (a.countryCode === 'OTHER') return 1;
      if (b.countryCode === 'OTHER') return -1;
      return a.countryName.localeCompare(b.countryName, sortLocale);
    });
    return {
      groups: workingGroups,
      availableRegions,
    };
  }

  // 4. Alphabetical
  workingGroups.sort((a, b) => {
    if (a.countryCode === 'OTHER') return 1;
    if (b.countryCode === 'OTHER') return -1;
    return a.countryName.localeCompare(b.countryName, sortLocale);
  });

  return {
    groups: workingGroups,
    availableRegions,
  };
}
