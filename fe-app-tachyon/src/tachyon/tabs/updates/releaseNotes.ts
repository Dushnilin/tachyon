import { TachyonShellMethods } from '../../methods';
import type { Tachyon } from '../../types';

// Match the backend's 5-item picker pages so one 30-item REST response can
// populate and cache several UI pages at once.
const RELEASES_PER_PAGE = 5;
const MAX_RELEASE_PAGES = 20; // 100 entries; bounds repeated scans of raw API pages.

function normalizeTag(tag: string): string {
  return tag.trim().replace(/^v/i, '').toLowerCase();
}

function selectRelease(
  releases: Tachyon.ComponentRelease[],
  requestedTag: string,
): Tachyon.ComponentRelease | undefined {
  if (!requestedTag) return releases[0];

  // Prefer an exact tag before allowing the optional "v" prefix to differ.
  const exact = releases.find((release) => release.tag.trim() === requestedTag);
  if (exact) return exact;

  const normalized = normalizeTag(requestedTag);
  return releases.find((release) => normalizeTag(release.tag) === normalized);
}

function isLocalFallback(releases: Tachyon.ComponentRelease[]): boolean {
  return (
    releases.length === 1 &&
    !releases[0]!.published?.trim() &&
    /\/releases\/?$/i.test(releases[0]!.release_url || '')
  );
}

export async function getReleaseForNotes(
  component: Tachyon.ComponentName,
  version: string,
): Promise<Tachyon.ComponentRelease | undefined> {
  const requestedTag = version.trim();

  for (let page = 1; page <= MAX_RELEASE_PAGES; page += 1) {
    const response = await TachyonShellMethods.componentListReleases(
      component,
      RELEASES_PER_PAGE,
      page,
    );
    if (!response.success) throw new Error(response.error);

    const releases = response.data;
    const matched = selectRelease(releases, requestedTag);
    if (matched) return matched;

    // An empty page is the normal end of the release list. The backend also
    // returns one undated local-build entry when the remote list is unavailable.
    if (releases.length === 0 || isLocalFallback(releases)) return undefined;
    if (!requestedTag) return releases[0];
  }

  return undefined;
}
