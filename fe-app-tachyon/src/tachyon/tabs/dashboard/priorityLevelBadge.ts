const FLAG_PAIR_RE = /[\u{1F1E6}-\u{1F1FF}]{2}/gu;

export function normalizePriorityLabel(text: string): string {
  return String(text || '')
    .replace(FLAG_PAIR_RE, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
}

/**
 * Formats the level badge for a Priority member row.
 * When a level corresponds to a single server whose name equals the node title
 * (ignoring country flags and repeated whitespace), renders `[#N]` instead of
 * duplicating the node name before itself.
 */
export function resolvePriorityLevelBadge(
  member: {
    levelName?: string;
    levelIndex?: number;
    displayName?: string;
  },
  displayTitle?: string,
): string {
  const rawLevel = String(member.levelName || '').trim();
  if (!rawLevel) return '';

  const normLevel = normalizePriorityLabel(rawLevel);
  if (!normLevel) return '';

  const normNode = normalizePriorityLabel(member.displayName || '');
  const normTitle = normalizePriorityLabel(displayTitle || '');

  if (normLevel === normNode || (normTitle && normLevel === normTitle)) {
    const levelNumber =
      typeof member.levelIndex === 'number' &&
      Number.isFinite(member.levelIndex)
        ? Math.max(0, Math.floor(member.levelIndex)) + 1
        : 1;
    return `[#${levelNumber}]`;
  }

  return `[${rawLevel}]`;
}
