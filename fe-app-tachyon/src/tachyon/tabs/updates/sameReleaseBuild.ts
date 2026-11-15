/**
 * A release tag can be rebuilt: the same version number then covers more than
 * one build. What the user needs to see is *which* build, and the answer comes
 * from whichever identity the release carries — a commit SHA when the build
 * stamps one, nothing at all for releases published before it did.
 */
export function describeSameReleaseBuild({
  currentSha,
  latestSha,
}: {
  currentSha?: string | null;
  latestSha?: string | null;
}) {
  const current = (currentSha || '').substring(0, 8);
  const latest = (latestSha || '').substring(0, 8);

  if (current && latest) {
    return { kind: 'sha' as const, text: `${current} → ${latest}` };
  }

  if (current || latest) {
    return { kind: 'sha' as const, text: current || latest };
  }

  // Without this the label claims an update is available and shows nothing to
  // back the claim up.
  return { kind: 'fallback' as const, text: '' };
}
