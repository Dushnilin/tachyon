export const DASHBOARD_EXPANDED_SECTIONS_KEY =
  'tachyon_dashboard_expanded_sections';

export function getExpandedSections(): Set<string> {
  if (typeof localStorage === 'undefined') {
    return new Set<string>();
  }

  try {
    const raw = localStorage.getItem(DASHBOARD_EXPANDED_SECTIONS_KEY);
    return new Set<string>(JSON.parse(raw || '[]'));
  } catch {
    return new Set<string>();
  }
}

export function saveExpandedSections(sections: Set<string>): void {
  if (typeof localStorage === 'undefined') {
    return;
  }

  try {
    localStorage.setItem(
      DASHBOARD_EXPANDED_SECTIONS_KEY,
      JSON.stringify(Array.from(sections)),
    );
  } catch {
    // Ignore storage quota or disabled localStorage errors
  }
}

export function toggleSectionExpansion(
  expandedSections: Set<string>,
  sectionCode: string,
): { expanded: boolean; nextSections: Set<string> } {
  const next = new Set<string>(expandedSections);
  const isCurrentlyExpanded = next.has(sectionCode);

  if (isCurrentlyExpanded) {
    next.delete(sectionCode);
  } else {
    next.add(sectionCode);
  }

  saveExpandedSections(next);

  return {
    expanded: !isCurrentlyExpanded,
    nextSections: next,
  };
}
