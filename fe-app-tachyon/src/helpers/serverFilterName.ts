const TELEMETRY_BYTE_UNITS = new Set([
  'b',
  'kb',
  'kib',
  'mb',
  'mib',
  'gb',
  'gib',
  'tb',
  'tib',
  'pb',
  'pib',
  'б',
  'кб',
  'мб',
  'гб',
  'тб',
  'пб',
  'байт',
  'киб',
  'миб',
  'гиб',
  'тиб',
  'пиб',
]);

const TELEMETRY_DURATION_UNITS = new Set([
  'd',
  'day',
  'days',
  'h',
  'hr',
  'hrs',
  'hour',
  'hours',
  'm',
  'min',
  'mins',
  'minute',
  'minutes',
  'mo',
  'mon',
  'month',
  'months',
  'w',
  'wk',
  'wks',
  'week',
  'weeks',
  'y',
  'yr',
  'yrs',
  'year',
  'years',
  'д',
  'дн',
  'дня',
  'дней',
  'день',
  'ч',
  'час',
  'часа',
  'часов',
  'мин',
  'мес',
  'нед',
  'г',
  'год',
  'года',
  'лет',
]);

const TELEMETRY_WORDS = new Set([
  'traffic',
  'quota',
  'left',
  'remain',
  'remaining',
  'expire',
  'expires',
  'exp',
  'reset',
  'usage',
  'used',
  'limit',
  'total',
  'balance',
  'valid',
  'until',
  'renew',
  'due',
  'days',
  'leftover',
  'subscription',
  'sub',
  'bandwidth',
  'transfer',
  'трафик',
  'остаток',
  'осталось',
  'лимит',
  'срок',
  'истекает',
  'до',
  'сброс',
  'исчерпан',
  'доступно',
  'подписка',
  'годен',
  'обновление',
  'обновл',
]);

const TELEMETRY_DATE_PREFIXES = new Set([
  'exp',
  'expire',
  'expires',
  'until',
  'reset',
  'valid',
  'renew',
  'due',
  'до',
  'истекает',
  'сброс',
  'годен',
]);

const TELEMETRY_PROTECTED_SUBSTRINGS = [
  'bps',
  'bit',
  'бит',
  '/s',
  '/c',
  '/с',
  '/сек',
];

const TELEMETRY_PROTECTED_TOKENS = new Set([
  'vless',
  'vmess',
  'trojan',
  'hysteria',
  'hysteria2',
  'hy2',
  'tuic',
  'shadowsocks',
  'shadowtls',
  'anytls',
  'ss',
  'ssr',
  'wireguard',
  'wg',
  'amnezia',
  'awg',
  'mieru',
  'naive',
  'xray',
  'reality',
  'xtls',
  'grpc',
  'xhttp',
  'ws',
  'quic',
  'tcp',
  'udp',
  'tls',
  'lte',
  'wifi',
  '4g',
  '5g',
  'ipv4',
  'ipv6',
  'direct',
  'warp',
  'tor',
]);

function normalizeTelemetryText(raw: string): string {
  return String(raw || '')
    .replace(/[\u00a0\u202f]/g, ' ')
    .replace(/[\u200b-\u200d\ufeff]/g, '')
    .toLowerCase()
    .replace(/(\d),(\d)/g, '$1.$2');
}

function unwrapSegmentBrackets(raw: string): string {
  let s = String(raw || '').trim();
  while (s.length >= 2) {
    const first = s[0];
    const last = s[s.length - 1];
    if (
      (first === '[' && last === ']') ||
      (first === '(' && last === ')') ||
      (first === '{' && last === '}')
    ) {
      s = s.slice(1, -1).trim();
    } else {
      break;
    }
  }
  return s;
}

function isNumericToken(tok: string): boolean {
  return /^\d+(?:\.\d+)?$/.test(tok);
}

export function isDynamicTelemetrySegment(rawSegment: string): boolean {
  const unwrapped = unwrapSegmentBrackets(rawSegment);
  const norm = normalizeTelemetryText(unwrapped).trim();
  if (!norm) return false;
  if (norm.indexOf('#') >= 0 || norm.indexOf('№') >= 0) return false;

  for (let i = 0; i < TELEMETRY_PROTECTED_SUBSTRINGS.length; i += 1) {
    if (norm.indexOf(TELEMETRY_PROTECTED_SUBSTRINGS[i]) >= 0) {
      return false;
    }
  }

  // Never treat standalone 2d / 3d tags like [2D] or (3D) as 2-day / 3-day expiry.
  if (norm === '2d' || norm === '3d') {
    return false;
  }

  let work = norm;
  let hasDate = false;
  let hasTelemetryWord = false;

  // Replace prefixed short or full dates (e.g. "exp: 12/31", "до 15.12").
  const datePrefixRegex =
    /(?:^|[\s|,;/])(exp|expire|expires|until|reset|valid|renew|due|до|истекает|сброс|годен)[\s:=-]*(\d{1,4}[./-]\d{1,2}(?:[./-]\d{1,4})?)(?=$|[\s|,;])/g;
  work = work.replace(datePrefixRegex, () => {
    hasDate = true;
    hasTelemetryWord = true;
    return ' ';
  });

  // Replace standalone explicit calendar dates with a 4-digit year.
  work = work.replace(
    /(?:^|[\s|,;:/-])(?:(?:19|20)\d{2}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[./-]\d{1,2}[./-](?:19|20)\d{2})(?=$|[\s|,;])/g,
    () => {
      hasDate = true;
      return ' ';
    },
  );

  // Replace standalone time stamps like 14:30 or 23:59:59 when accompanied by telemetry.
  let hasTime = false;
  work = work.replace(
    /(?:^|[\s|,;])(?:\d{1,2}:\d{2}(?::\d{2})?)(?=$|[\s|,;])/g,
    () => {
      hasTime = true;
      return ' ';
    },
  );

  // Split common separators into spaces while keeping decimals intact.
  const rawTokens = work
    .replace(/[/|:;+,•·—–=~↑↓()[\]{}]+/g, ' ')
    .replace(/(?:^|\s)-+(?=\s|$)/g, ' ')
    .trim()
    .split(/\s+/)
    .filter(Boolean);

  if (rawTokens.length === 0 && !hasDate && !hasTelemetryWord && !hasTime) {
    return false;
  }

  const tokens: string[] = [];
  for (let i = 0; i < rawTokens.length; i += 1) {
    const cleaned = rawTokens[i].replace(/^[-:]+|[-:]+$/g, '');
    if (!cleaned) continue;
    const glued = cleaned.match(/^(\d+(?:\.\d+)?)([a-zа-яё%]+)$/i);
    if (glued) {
      tokens.push(glued[1], glued[2]);
    } else {
      tokens.push(cleaned);
    }
  }

  let hasByte = false;
  let hasDuration = false;
  let hasPercent = false;
  let prevWasNumber = false;
  let numericCount = 0;

  for (let i = 0; i < tokens.length; i += 1) {
    const tok = tokens[i];
    if (TELEMETRY_PROTECTED_TOKENS.has(tok)) {
      return false;
    }
    if (isNumericToken(tok)) {
      prevWasNumber = true;
      numericCount += 1;
      continue;
    }
    if (tok === '%' && prevWasNumber) {
      hasPercent = true;
      prevWasNumber = false;
      continue;
    }
    if (TELEMETRY_BYTE_UNITS.has(tok) && prevWasNumber) {
      hasByte = true;
      prevWasNumber = false;
      continue;
    }
    if (TELEMETRY_DURATION_UNITS.has(tok) && prevWasNumber) {
      hasDuration = true;
      prevWasNumber = false;
      continue;
    }
    if (TELEMETRY_WORDS.has(tok) || TELEMETRY_DATE_PREFIXES.has(tok)) {
      hasTelemetryWord = true;
      prevWasNumber = false;
      continue;
    }
    // Any unrecognized word means this segment likely carries node identity text.
    return false;
  }

  if (hasByte || hasDuration || hasDate) {
    return true;
  }
  if (hasTelemetryWord && (hasPercent || numericCount > 0 || hasTime)) {
    return true;
  }
  return false;
}

export function stripDynamicServerTelemetry(value: unknown): string {
  const raw = String(value || '').trim();
  if (!raw) return '';

  let result = raw;
  let prev = '';
  while (result !== prev) {
    prev = result;

    // 1. Strip bracketed / parenthesized telemetry blocks anywhere in the string.
    result = result.replace(/(\[[^[\]]*\]|\([^()]*\)|\{[^{}]*\})/g, (m) =>
      isDynamicTelemetrySegment(m) ? ' ' : m,
    );

    // 2. Strip trailing delimiter-separated telemetry tails (|, •, ·, ;, —, –, or " - ").
    let tailChanged = true;
    while (tailChanged) {
      tailChanged = false;
      const pipeMatch = result.match(
        /^(.+?)\s*(?:\||•|·|;|—|–| - )\s*([^|•·;—–]+)$/,
      );
      if (pipeMatch) {
        const head = pipeMatch[1].trim();
        const tail = pipeMatch[2].trim();
        if (head && tail && isDynamicTelemetrySegment(tail)) {
          result = head;
          tailChanged = true;
        }
      }
    }

    // 3. Clean dangling edge or repeated separators left behind by stripped blocks.
    result = result
      .replace(/\s*(?:\||•|·|;|—|–|-)\s*(?:\||•|·|;|—|–)\s*/g, ' | ')
      .replace(/^(?:\||•|·|;|—|–|-)+\s+/, '')
      .replace(/\s+(?:\||•|·|;|—|–|-)+$/, '')
      .replace(/[ \t]{2,}/g, ' ')
      .trim();
  }

  return result || raw;
}

export function serverFilterNameMatches(
  filterEntry: unknown,
  candidateNames: readonly unknown[],
): boolean {
  const rawFilter = String(filterEntry || '').trim();
  if (!rawFilter) return false;
  const canonFilter = stripDynamicServerTelemetry(rawFilter);

  for (let i = 0; i < candidateNames.length; i += 1) {
    const rawCandidate = String(candidateNames[i] || '').trim();
    if (!rawCandidate) continue;
    if (rawFilter === rawCandidate) {
      return true;
    }
    if (
      canonFilter &&
      canonFilter === stripDynamicServerTelemetry(rawCandidate)
    ) {
      return true;
    }
  }

  return false;
}
