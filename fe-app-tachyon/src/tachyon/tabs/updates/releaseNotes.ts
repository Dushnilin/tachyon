import { TachyonShellMethods } from '../../methods';
import type { Tachyon } from '../../types';

// Reuse the same cached RPC pages as the version picker.
const RELEASES_PER_PAGE = 5;
const MAX_RELEASE_PAGES = 20; // 100 entries; bounds repeated scans of raw API pages.

function normalizeTag(tag: string): string {
  return tag.trim().replace(/^v/i, '').toLowerCase();
}

function requestedReleaseTag(version: string, releaseUrl?: string): string {
  const requested = version.trim();
  if (!requested || !releaseUrl) return requested;

  // The updater can strip the v prefix from its display version.
  try {
    const path = new URL(releaseUrl).pathname;
    const tag = decodeURIComponent(
      path.match(/\/releases\/tag\/(.+)$/)?.[1] ?? '',
    );
    if (tag && normalizeTag(tag) === normalizeTag(requested)) return tag;
  } catch {
    // A malformed release URL leaves the display version as the lookup key.
  }
  return requested;
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
  releaseUrl?: string,
): Promise<Tachyon.ComponentRelease | undefined> {
  const requestedTag = requestedReleaseTag(version, releaseUrl);
  const normalizedTag = normalizeTag(requestedTag);
  let compatibleRelease: Tachyon.ComponentRelease | undefined;

  for (let page = 1; page <= MAX_RELEASE_PAGES; page += 1) {
    const response = await TachyonShellMethods.componentListReleases(
      component,
      RELEASES_PER_PAGE,
      page,
    );
    if (!response.success) {
      if (compatibleRelease) return compatibleRelease;
      throw new Error(response.error);
    }

    const releases = response.data;
    if (!requestedTag) return releases[0];

    // An empty page is the normal end of the release list. The backend also
    // returns one undated local-build entry when the remote list is unavailable.
    if (releases.length === 0 || isLocalFallback(releases)) break;

    const exact = releases.find(
      (release) => release.tag.trim() === requestedTag,
    );
    if (exact) return exact;
    compatibleRelease ??= releases.find(
      (release) => normalizeTag(release.tag) === normalizedTag,
    );
  }

  return compatibleRelease;
}
