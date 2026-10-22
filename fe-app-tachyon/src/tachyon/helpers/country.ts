import type { Tachyon } from '../types';

const translate = (key: string) => (typeof _ === 'function' ? _(key) : key);

export interface OutboundCountryInfo {
  code: string;
  flag: string;
  name: string;
}

export interface OutboundCountryGroup {
  countryCode: string;
  countryFlag: string;
  countryName: string;
  outbounds: Tachyon.Outbound[];
  bestLatency: number;
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
  'RU', 'DE', 'NL', 'US', 'GB', 'UK', 'FR', 'FI', 'SE', 'PL', 'TR', 'KZ',
  'SG', 'JP', 'HK', 'CA', 'CH', 'AT', 'ES', 'IT', 'UA', 'AE', 'NO', 'CZ',
  'EE', 'LV', 'LT', 'MD', 'BY', 'GE', 'AM', 'UZ', 'KG', 'RS', 'BG', 'RO',
  'HU', 'GR', 'CY', 'IL', 'IN', 'KR', 'AU', 'BR', 'AR', 'MX', 'IS', 'IE',
  'PT', 'BE', 'DK',
]);

function buildCountryRegex(pattern: string): RegExp {
  return new RegExp(`(?:^|[^\\p{L}\\p{N}])(?:${pattern})(?:[^\\p{L}\\p{N}]|$)`, 'iu');
}

const COUNTRY_KEYWORD_PATTERNS: Array<{ code: string; regex: RegExp }> = [
  { code: 'RU', regex: buildCountryRegex('russia|russian|россия|рф|москва|moscow|питер|spb') },
  { code: 'DE', regex: buildCountryRegex('germany|german|германия|frankfurt|франкфурт|berlin|берлин') },
  { code: 'NL', regex: buildCountryRegex('netherlands|holland|нидерланды|голландия|amsterdam|амстердам') },
  { code: 'US', regex: buildCountryRegex('usa|united\\s*states|сша|america|америка|new\\s*york|los\\s*angeles|miami') },
  { code: 'GB', regex: buildCountryRegex('uk|united\\s*kingdom|great\\s*britain|великобритания|англия|london|лондон') },
  { code: 'TR', regex: buildCountryRegex('turkey|turkish|турция|istanbul|стамбул') },
  { code: 'FI', regex: buildCountryRegex('finland|финляндия|helsinki|хельсинки') },
  { code: 'SE', regex: buildCountryRegex('sweden|швеция|stockholm|стокгольм') },
  { code: 'PL', regex: buildCountryRegex('poland|польша|warsaw|варшава') },
  { code: 'KZ', regex: buildCountryRegex('kazakhstan|казахстан|almaty|алматы|astana|астана') },
  { code: 'FR', regex: buildCountryRegex('france|франция|paris|париж') },
  { code: 'SG', regex: buildCountryRegex('singapore|сингапур') },
  { code: 'JP', regex: buildCountryRegex('japan|япония|tokyo|токио') },
  { code: 'HK', regex: buildCountryRegex('hong\\s*kong|гонконг') },
  { code: 'CH', regex: buildCountryRegex('switzerland|швейцария|zurich|цюрих|geneva|женева') },
  { code: 'AT', regex: buildCountryRegex('austria|австрия|vienna|вена') },
  { code: 'ES', regex: buildCountryRegex('spain|испания|madrid|мадрид|barcelona|барселона') },
  { code: 'IT', regex: buildCountryRegex('italy|италия|rome|рим|milan|милан') },
  { code: 'CA', regex: buildCountryRegex('canada|канада|toronto|торонто|vancouver|ванкувер') },
  { code: 'UA', regex: buildCountryRegex('ukraine|украина|kyiv|kiev|киев') },
  { code: 'AE', regex: buildCountryRegex('uae|emirates|оаэ|эмираты|dubai|дубай') },
  { code: 'GE', regex: buildCountryRegex('georgia|грузия|tbilisi|тбилиси') },
  { code: 'AM', regex: buildCountryRegex('armenia|армения|yerevan|ереван') },
  { code: 'MD', regex: buildCountryRegex('moldova|молдова|chisinau|кишинев') },
  { code: 'BY', regex: buildCountryRegex('belarus|беларусь|белоруссия|minsk|минск') },
  { code: 'RS', regex: buildCountryRegex('serbia|сербия|belgrade|белград') },
  { code: 'IL', regex: buildCountryRegex('israel|израиль|tel\\s*aviv|тель-авив') },
  { code: 'IN', regex: buildCountryRegex('india|индия|mumbai|мумбаи|delhi|дели') },
  { code: 'CY', regex: buildCountryRegex('cyprus|кипр|limassol|лимасол|nicosia|никосия') },
  { code: 'TW', regex: buildCountryRegex('taiwan|тайвань|taipei|тайбэй') },
  { code: 'CZ', regex: buildCountryRegex('czech|чехия|prague|прага') },
  { code: 'SK', regex: buildCountryRegex('slovakia|словакия|bratislava|братислава') },
  { code: 'RO', regex: buildCountryRegex('romania|румыния|bucharest|бухарест') },
  { code: 'BG', regex: buildCountryRegex('bulgaria|болгария|sofia|софия') },
  { code: 'HU', regex: buildCountryRegex('hungary|венгрия|budapest|будапешт') },
  { code: 'LT', regex: buildCountryRegex('lithuania|литва|vilnius|вильнюс') },
  { code: 'LV', regex: buildCountryRegex('latvia|латвия|riga|рига') },
  { code: 'EE', regex: buildCountryRegex('estonia|эстония|tallinn|таллин') },
  { code: 'UZ', regex: buildCountryRegex('uzbekistan|узбекистан|tashkent|ташкент') },
  { code: 'KG', regex: buildCountryRegex('kyrgyzstan|кыргызстан|киргизия|bishkek|бишкек') },
  { code: 'TH', regex: buildCountryRegex('thailand|таиланд|тайланд|bangkok|бангкок') },
  { code: 'VN', regex: buildCountryRegex('vietnam|вьетнам|hanoi|ханой') },
  { code: 'KR', regex: buildCountryRegex('korea|корея|seoul|сеул') },
  { code: 'AU', regex: buildCountryRegex('australia|австралия|sydney|сидней|melbourne|мельбурн') },
  { code: 'BR', regex: buildCountryRegex('brazil|бразилия|sao\\s*paulo|сан-паулу') },
  { code: 'AR', regex: buildCountryRegex('argentina|аргентина|buenos\\s*aires|буэнос-айрес') },
  { code: 'CL', regex: buildCountryRegex('chile|чили|santiago|сантьяго') },
  { code: 'CO', regex: buildCountryRegex('colombia|колумбия|bogota|богота') },
  { code: 'MX', regex: buildCountryRegex('mexico|мексика') },
  { code: 'EG', regex: buildCountryRegex('egypt|египет|cairo|каир') },
  { code: 'IS', regex: buildCountryRegex('iceland|исландия|reykjavik|рейкьявик') },
  { code: 'NO', regex: buildCountryRegex('norway|норвегия|oslo|осло') },
  { code: 'DK', regex: buildCountryRegex('denmark|дания|copenhagen|копенгаген') },
  { code: 'IE', regex: buildCountryRegex('ireland|ирландия|dublin|дублин') },
  { code: 'PT', regex: buildCountryRegex('portugal|португалия|lisbon|лиссабон') },
  { code: 'BE', regex: buildCountryRegex('belgium|бельгия|brussels|брюссель') },
  { code: 'LU', regex: buildCountryRegex('luxembourg|люксембург') },
  { code: 'GR', regex: buildCountryRegex('greece|греция|athens|афины') },
  { code: 'HR', regex: buildCountryRegex('croatia|хорватия|zagreb|загреб') },
  { code: 'BA', regex: buildCountryRegex('bosnia|босния|sarajevo|сараево') },
  { code: 'AL', regex: buildCountryRegex('albania|албания|tirana|тирана') },
  { code: 'MK', regex: buildCountryRegex('macedonia|македония|skopje|скопье') },
  { code: 'AZ', regex: buildCountryRegex('azerbaijan|азербайджан|baku|баку') },
  { code: 'ID', regex: buildCountryRegex('indonesia|индонезия|jakarta|джакарта') },
  { code: 'MY', regex: buildCountryRegex('malaysia|малайзия|kuala\\s*lumpur|куала-лумпур') },
  { code: 'PH', regex: buildCountryRegex('philippines|филиппины|manila|манила') },
  { code: 'PK', regex: buildCountryRegex('pakistan|пакистан') },
  { code: 'BD', regex: buildCountryRegex('bangladesh|бангладеш|dhaka|дакка') },
  { code: 'QA', regex: buildCountryRegex('qatar|катар|doha|доха') },
  { code: 'BH', regex: buildCountryRegex('bahrain|бахрейн|manama|манама') },
  { code: 'IQ', regex: buildCountryRegex('iraq|ирак|baghdad|багдад') },
  { code: 'MN', regex: buildCountryRegex('mongolia|монголия|ulaanbaatar|улан-батор') },
  { code: 'KH', regex: buildCountryRegex('cambodia|камбоджа|phnom\\s*penh|пномпень') },
  { code: 'LK', regex: buildCountryRegex('sri\\s*lanka|шри-ланка|colombo|коломбо') },
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

  const isDocRu =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('ru');
  const isDocEn =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('en');

  const effectiveLocale = locale || (isDocEn ? 'en' : 'ru');
  const isRu = effectiveLocale.startsWith('ru');

  if (isRu && PREFERRED_NAMES_RU[code]) {
    return PREFERRED_NAMES_RU[code];
  }

  try {
    if (typeof Intl !== 'undefined' && typeof Intl.DisplayNames === 'function') {
      const displayNames = new Intl.DisplayNames([effectiveLocale, 'en'], { type: 'region' });
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
 * Groups an array of outbounds by country.
 */
export function groupOutboundsByCountry(
  outbounds: Tachyon.Outbound[],
  locale?: string,
): OutboundCountryGroup[] {
  const groupsMap = new Map<string, OutboundCountryGroup>();

  for (const outbound of outbounds) {
    const info = detectOutboundCountry(outbound, locale);
    let group = groupsMap.get(info.code);
    if (!group) {
      group = {
        countryCode: info.code,
        countryFlag: info.flag,
        countryName: info.name,
        outbounds: [],
        bestLatency: Number.POSITIVE_INFINITY,
      };
      groupsMap.set(info.code, group);
    }
    group.outbounds.push(outbound);

    if (
      Number.isFinite(outbound.latency) &&
      outbound.latency > 0 &&
      outbound.latency < group.bestLatency
    ) {
      group.bestLatency = outbound.latency;
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
